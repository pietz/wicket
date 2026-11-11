import AppKit
import Testing

@testable import WicketApp

@MainActor @Test func streamedTextKeepsTheNativeEditorAndCaretInSync() {
  _ = NSApplication.shared
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 400, height: 100), styleMask: [.borderless], backing: .buffered,
    defer: false)
  let field = NSTextField(string: "")
  field.frame = NSRect(x: 0, y: 0, width: 400, height: 30)
  window.contentView!.addSubview(field)
  #expect(window.makeFirstResponder(field))
  let editor = field.currentEditor() as! NSTextView
  for text in ["Safari", "Safari tomorrow 😀"] {
    SearchField.updateText(text, in: field)
    #expect(editor.string == text && field.stringValue == text)
    #expect(editor.selectedRange() == NSRange(location: text.utf16.count, length: 0))
  }
  editor.insertText(" more", replacementRange: editor.selectedRange())
  #expect(editor.string == "Safari tomorrow 😀 more")
  #expect(!window.isVisible)
  window.orderOut(nil)
}

@MainActor final class FakeTranscriber: Transcriber {
  var feeds: [AsyncThrowingStream<VoiceUpdate, any Error>.Continuation] = []
  var stops = 0
  var shutdown: Task<Void, Never>?
  func start() -> AsyncThrowingStream<VoiceUpdate, any Error> {
    let (stream, feed) = AsyncThrowingStream.makeStream(of: VoiceUpdate.self)
    feeds.append(feed)
    return stream
  }
  func stop() {
    stops += 1
    feeds.last?.finish()
  }
}

@MainActor @Test func voiceStreamsRevisionsAndFinalSegmentsWithoutSubmitting() async {
  let fake = FakeTranscriber()
  var input = "existing input"
  let voice = VoiceInput(transcriber: { fake }, write: { input = $0 })
  voice.toggle()
  #expect(voice.state == .starting && fake.feeds.count == 1)
  fake.feeds[0].yield(.ready)
  #expect(await eventually { voice.state == .listening })
  var transcript = Transcript()
  transcript.apply("Open Cal", isFinal: false)
  fake.feeds[0].yield(.transcript(transcript.text))
  #expect(await eventually { input == "Open Cal" })
  transcript.apply("Open Calendar.", isFinal: true)
  fake.feeds[0].yield(.transcript(transcript.text))
  #expect(await eventually { input == "Open Calendar" })
  transcript.apply("Tomorrow?", isFinal: false)
  fake.feeds[0].yield(.transcript(transcript.text))
  #expect(await eventually { input == "Open Calendar. Tomorrow?" })
  #expect(voice.state == .listening)  // Final segments are not end-of-dictation.
  fake.feeds[0].finish()
  #expect(await eventually { voice.state == .idle })
  #expect(input == "Open Calendar. Tomorrow?" && fake.stops == 1)
}

@MainActor @Test func stopAndRestartRejectOldTranscriptsAndFailures() async {
  let fake = FakeTranscriber()
  var input = ""
  let voice = VoiceInput(transcriber: { fake }, write: { input = $0 })
  voice.toggle()
  voice.toggle()
  #expect(voice.state == .idle && fake.stops == 1)
  voice.toggle()
  if case .terminated = fake.feeds[0].yield(.transcript("stale")) {
  } else {
    Issue.record("Old stream accepted a late transcript")
  }
  fake.feeds[0].finish(throwing: VoiceError.microphoneDenied)
  fake.feeds[1].yield(.ready)
  fake.feeds[1].yield(.transcript("current"))
  #expect(await eventually { input == "current" })
  #expect(voice.problem == nil && voice.state == .listening)
  voice.stop()
}

@MainActor
@Test(arguments: [
  VoiceError.microphoneDenied, .noMicrophone, .noLanguage, .modelMissing,
  .usageMissing, .conversionFailed, .inputChanged,
])
func voiceFailuresStopCaptureAndExplainTheProblem(_ error: VoiceError) async {
  let fake = FakeTranscriber()
  let voice = VoiceInput(transcriber: { fake }, write: { _ in Issue.record("Failure wrote input") })
  voice.toggle()
  fake.feeds[0].finish(throwing: error)
  #expect(await eventually { voice.problem != nil })
  #expect(voice.state == .idle && fake.stops == 1)
  #expect(voice.problem == error.description)
}

@MainActor @Test func unexpectedVoiceErrorsAreReadableAndRetryable() async {
  let fake = FakeTranscriber()
  let voice = VoiceInput(transcriber: { fake }, write: { _ in })
  voice.toggle()
  fake.feeds[0].finish(throwing: NSError(domain: "internal", code: 42))
  #expect(await eventually { voice.problem == "Couldn't listen. Try again." })
  voice.toggle()
  #expect(voice.problem == nil && voice.state == .starting && fake.feeds.count == 2)
  voice.stop()
}

@MainActor @Test func voiceSilenceAndStartupAreBounded() async {
  let fake = FakeTranscriber()
  let voice = VoiceInput(transcriber: { fake }, write: { _ in })
  // Startup that never becomes ready fails after the deadline. Nothing else races it.
  voice.silenceDuration = .milliseconds(15)
  voice.toggle()
  #expect(await eventually { voice.problem != nil })
  #expect(!voice.active && fake.stops == 1)
  // The silence deadline starts only once listening is observed, so a slow test machine
  // cannot expire it before the test has seen the state.
  voice.silenceDuration = .seconds(30)
  voice.toggle()
  fake.feeds[1].yield(.ready)
  #expect(await eventually { voice.state == .listening })
  voice.silenceDuration = .milliseconds(15)
  fake.feeds[1].yield(.transcript("hello"))
  #expect(await eventually { voice.state == .idle })
  #expect(voice.problem == nil && fake.stops == 2)
}

@MainActor @Test func continuousVoiceHasAHardLimit() async {
  let fake = FakeTranscriber()
  let voice = VoiceInput(transcriber: { fake }, write: { _ in })
  voice.silenceDuration = .seconds(30)
  voice.maximumDuration = .milliseconds(15)
  voice.toggle()
  fake.feeds[0].yield(.ready)
  #expect(await eventually { voice.state == .idle })
  #expect(fake.stops == 1)
}

@MainActor @Test func launcherVoiceIsLazyAndLiveConfigCanDisableIt() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeTranscriber()
  var constructions = 0
  let model = LauncherModel(
    providers: [MathProvider()], history: UsageHistory(url: folder.appending(path: "usage.json")),
    folder: folder,
    transcriber: {
      constructions += 1
      return fake
    })
  #expect(model.voice == nil)
  model.store.update { $0.voice.enabled = false }
  model.armVoice()
  #expect(constructions == 0 && model.voice == nil)
  model.store.update { $0.voice.enabled = true }
  #expect(constructions == 0)  // Enabling does not request permissions or capture.
  model.armVoice()
  fake.feeds[0].yield(.ready)
  fake.feeds[0].yield(.transcript("2+2."))
  #expect(await eventually { model.input == "2+2" })
  await model.settled()
  #expect(model.results.first?.row.title == "4")
  model.store.update { $0.voice.enabled = false }
  #expect(model.voice?.state == .idle && fake.stops == 1 && model.input == "2+2")
  fake.feeds[0].yield(.transcript("late"))
  await Task.yield()
  #expect(model.input == "2+2")
  await model.finish()
}

@MainActor @Test(arguments: [PaletteKeyAction.passThrough, .edit(.paste), .dismiss, .run, .send])
func voiceKeysStopBeforeNormalInputAndSubmission(_ action: PaletteKeyAction) async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
    transcriber: { fake })
  model.store.update { $0.voice.enabled = true }
  model.toggleVoice()
  fake.feeds[0].yield(.ready)
  fake.feeds[0].yield(.transcript("spoken"))
  #expect(await eventually { model.input == "spoken" })
  let panel = RoutingPanel()
  panel.beforeAction = { model.keyPressed($0) }
  var routed: PaletteKeyAction?
  panel.onAction = { routed = $0 }
  let (code, text, flags): (UInt16, String, NSEvent.ModifierFlags) =
    switch action {
    case .passThrough: (0, "a", [])
    case .edit: (9, "v", .command)
    case .dismiss: (53, "\u{1b}", [])
    case .run: (36, "\r", [])
    default: (36, "\r", .command)
    }
  _ = panel.route(voiceKey(code, text, flags))
  #expect(routed == (action == .run || action == .send ? action : nil))
  #expect(model.voice?.state == .idle && fake.stops == 1 && model.input == "spoken")
  _ = panel.route(voiceKey(53, "\u{1b}"))
  #expect(routed == .dismiss)  // Second Escape reaches ordinary navigation.
  #expect(!panel.isVisible)
  model.editInput("typed")
  fake.feeds[0].yield(.transcript("late"))
  await Task.yield()
  #expect(model.input == "typed")
  await model.finish()
}

@MainActor @Test func fieldEditsPanelHideAndShutdownStopVoice() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
    transcriber: { fake })
  model.store.update { $0.voice.enabled = true }
  model.toggleVoice()
  model.editInput("typed directly")
  #expect(model.voice?.state == .idle && fake.stops == 1)
  model.toggleVoice()
  model.dismiss()
  #expect(model.voice?.state == .idle && fake.stops == 2 && model.input.isEmpty)
  model.toggleVoice()
  await model.finish()
  #expect(model.voice?.state == .idle && fake.stops == 3)
}

@MainActor @Test func spokenConversationFollowUpUsesExistingInput() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
    transcriber: { fake })
  try await finishTurn(model.agent, "First", "Answer")
  let client = FakeAgent()
  model.agent.connect = { _, _, _ in client }
  model.store.update { $0.voice.enabled = true }
  model.toggleVoice()
  fake.feeds[0].yield(.ready)
  fake.feeds[0].yield(.transcript("Why?"))
  #expect(await eventually { model.input == "Why?" })
  #expect(model.agent.question == "First" && !model.agent.busy)
  model.send()
  #expect(await eventually { client.running })
  #expect(model.agent.question == "Why?" && model.input.isEmpty && fake.stops == 1)
  client.end()
  await model.finish()
}

@Test func voiceConfigurationAndLanguageChoice() throws {
  for json in ["{}", #"{"voice":{}}"#, #"{"voice":{"enabled":true}}"#] {
    #expect(try JSONDecoder().decode(Configuration.self, from: Data(json.utf8)).voice.enabled)
  }
  #expect(
    try !JSONDecoder().decode(Configuration.self, from: Data(#"{"voice":{"enabled":false}}"#.utf8)).voice
      .enabled)
  let data = Data(#"{"voice":{"enabled":true}}"#.utf8)
  let config = try JSONDecoder().decode(Configuration.self, from: data)
  #expect(config.voice.enabled)
  #expect(
    try JSONDecoder().decode(Configuration.self, from: JSONEncoder().encode(config)) == config)
  #expect(throws: (any Error).self) {
    try JSONDecoder().decode(Configuration.self, from: Data(#"{"voice":{"enabled":"yes"}}"#.utf8))
  }
  let supported = ["en-SG", "en-US", "de-DE", "en-GB"].map(Locale.init(identifier:))
  #expect(VoiceLanguage.choose(preferred: ["en-DE"], supported: supported)?.identifier == "en-US")
  #expect(
    VoiceLanguage.choose(preferred: ["de-AT", "en-US"], supported: supported)?.identifier == "de-DE"
  )
  #expect(VoiceLanguage.choose(preferred: ["en-GB"], supported: supported)?.identifier == "en-GB")
  #expect(VoiceLanguage.choose(preferred: ["xx"], supported: supported) == nil)
  #expect(Transcript.searchText("  Safari。... ") == "Safari")
}

@Test func commandLHasNoVoiceShortcut() {
  #expect(
    PaletteKeyAction.decide(keyCode: 37, characters: "l", modifiers: .command, hasMarkedText: false)
      == .consume)
  #expect(
    PaletteKeyAction.decide(keyCode: 37, characters: "l", modifiers: .command, hasMarkedText: true)
      == .passThrough)
}

@MainActor @Test func atomicVoiceConfigReloadKeepsInvalidEditsAndStopsOnDisable() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
    transcriber: { fake })
  let url = folder.appending(path: "config.json")
  model.store.start()
  var enabled = Configuration()
  enabled.voice.enabled = true
  try enabled.save(at: url)
  #expect(await eventually { model.configuration.voice.enabled })
  #expect(fake.feeds.isEmpty)
  model.toggleVoice()
  fake.feeds[0].yield(.ready)
  #expect(await eventually { model.voice?.state == .listening })
  try Data(#"{"voice":{"enabled":"yes"}}"#.utf8).write(to: url, options: .atomic)
  #expect(await eventually { model.store.problem != nil })
  #expect(model.configuration.voice.enabled && model.voice?.active == true && fake.stops == 0)
  var disabled = Configuration()
  disabled.voice.enabled = false
  try disabled.save(at: url)
  #expect(await eventually { model.voice?.state == .idle && !model.configuration.voice.enabled })
  #expect(fake.stops == 1)
  await model.finish()
}

@MainActor @Test func dictationFlowsThroughRealExtensionPatternsAndCommandInput() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  _ = try extensionFolder(
    folder, script: answering("spoken result"), fields: ["match": "^voice .+$"])
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
    transcriber: { fake })
  model.store.update { $0.providers = [.init("extension:test")] }
  await model.extensions.reload()
  model.store.update { $0.voice.enabled = true }
  model.toggleVoice()
  fake.feeds[0].yield(.ready)
  fake.feeds[0].yield(.transcript("voice search"))
  #expect(await eventually { model.input == "voice search" })
  await model.settled()
  #expect(model.results.first?.row.title == "spoken result")
  #expect(model.agent.question.isEmpty && !model.agent.active)
  model.input = "test"
  await model.settled()
  model.select(model.results.first { $0.provider == "extension:test" }?.id)
  let panel = RoutingPanel()
  panel.beforeAction = { model.keyPressed($0) }
  panel.onAction = { if $0 == .run { #expect(model.activateReturn()) } }
  #expect(panel.route(voiceKey(36, "\r")))
  #expect(model.voice?.state == .idle)
  model.toggleVoice()
  fake.feeds[1].yield(.ready)
  fake.feeds[1].yield(.transcript("command words"))
  #expect(await eventually { model.input == "command words" })
  await model.settled()
  #expect(
    model.command?.id == "extension:test" && model.results.first?.row.title == "spoken result")
  await model.finish()
}

@MainActor @Test func listeningUsesTheRealStateMachineWithoutHardware() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
    transcriber: { fake })
  model.armVoice()
  fake.feeds[0].yield(.ready)
  fake.feeds[0].yield(.transcript("How do rainbows form?"))
  #expect(await eventually { model.voice?.state == .listening && model.input.contains("rainbows") })
  model.dismiss()
  #expect(model.voice?.state == .idle)
  await model.finish()
}

@MainActor final class RoutingPanel: PalettePanel {
  var routedKey = true
  override var isKeyWindow: Bool { routedKey }  // Route only; never become key or order front.
}
@MainActor func voiceKey(
  _ code: UInt16, _ text: String, _ flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false
) -> NSEvent {
  _ = NSApplication.shared
  return NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
    characters: text, charactersIgnoringModifiers: text, isARepeat: repeatKey, keyCode: code)!
}

@MainActor @Test func losingSpeechAvailabilityStopsBeforeAnotherTranscript() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeTranscriber()
  let client = FakeAgent()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
    transcriber: { fake })
  model.agent.connect = { _, _, _ in client }
  model.store.update { $0.voice.enabled = true }
  model.toggleVoice()
  fake.feeds[0].yield(.ready)
  #expect(await eventually { model.voice?.state == .listening })
  model.agent.ask("Busy now", settings: .init())
  #expect(!model.takesSpeech && model.voice?.state == .idle && fake.stops == 1)
  await model.finish()
}

@Test func analyzerNeedsOnlyMicrophoneUsageDescription() throws {
  try AppleTranscriber.validateUsage(["NSMicrophoneUsageDescription": "Speak into Wicket"])
  for info: [String: Any] in [[:], ["NSMicrophoneUsageDescription": ""]] {
    #expect(throws: VoiceError.self) { try AppleTranscriber.validateUsage(info) }
  }
}

@Test(arguments: ["zh-CN", "zh-TW", "ja-JP"])
func eastAsianSegmentsKeepNativeWordBoundaries(_ language: String) {
  var transcript = Transcript(locale: Locale(identifier: language))
  transcript.apply("今天", isFinal: true)
  transcript.apply(" 天气", isFinal: false)
  #expect(transcript.text == "今天天气")
  transcript.apply(" 很好", isFinal: true)
  transcript.apply("。", isFinal: false)
  #expect(transcript.text == "今天很好。")
  var english = Transcript(locale: Locale(identifier: "en-US"))
  english.apply("Hello", isFinal: true)
  english.apply("world", isFinal: false)
  #expect(english.text == "Hello world")
}

@MainActor @Test func ordinaryFakeStopsTerminateTheirStream() {
  let fake = FakeTranscriber()
  let voice = VoiceInput(transcriber: { fake }, write: { _ in })
  voice.toggle()
  voice.stop()
  if case .terminated = fake.feeds[0].yield(.ready) {
  } else {
    Issue.record("Stopped fake left its stream open")
  }
}

@MainActor @Test func openTypingHideAndReopenOwnTheMicrophone() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
    transcriber: { fake })
  // Controller stays hidden; these checks never post keys or order a window.
  let controller = PaletteController(model: model, panel: RoutingPanel())
  controller.show(orderFront: false)
  #expect(model.voice?.state == .starting && fake.feeds.count == 1)
  // Queue both updates before the first key. The consumer has not run yet.
  fake.feeds[0].yield(.ready)
  fake.feeds[0].yield(.transcript("late speech"))
  #expect(controller.panel.route(voiceKey(125, "")))  // Arrow does not edit the field.
  #expect(model.voice?.state == .idle && fake.stops == 1)
  let field = try #require(controller.panel.input)
  #expect(!controller.panel.route(voiceKey(0, "a")))
  let editor = try #require(field.currentEditor() as? NSTextView)
  editor.insertText("a", replacementRange: editor.selectedRange())
  await Task.yield()
  #expect(model.input == "a" && model.voice?.state == .idle && fake.stops == 1)
  controller.hide()
  controller.show(orderFront: false)
  #expect(model.voice?.state == .starting && fake.feeds.count == 2)
  fake.feeds[1].yield(.ready)
  fake.feeds[1].yield(.transcript("Open Safari."))
  #expect(await eventually { model.input == "Open Safari" })
  #expect(!model.agent.active)
  controller.hide()
  #expect(model.voice?.state == .idle && fake.stops == 2 && model.input.isEmpty)
  model.store.update { $0.voice.enabled = false }
  controller.show(orderFront: false)
  #expect(model.voice?.state == .idle && fake.feeds.count == 2)
  await model.finish()
}

@MainActor @Test func permissionDenialIsQuietAcrossOpensAndTypingStillWorks() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
    transcriber: { fake })
  var restored = 0
  model.onVoicePermissionFinished = { restored += 1 }
  model.armVoice()
  fake.feeds[0].yield(.permission(true))
  #expect(await eventually { model.voice?.requestingPermission == true })
  fake.feeds[0].yield(.permission(false))
  fake.feeds[0].finish(throwing: VoiceError.microphoneDenied)
  #expect(await eventually { model.voice?.problem == VoiceError.microphoneDenied.description })
  #expect(restored == 1 && model.voice?.requestingPermission == false)
  model.dismiss()
  model.armVoice()
  model.editInput("typed normally")
  #expect(fake.feeds.count == 1 && model.input == "typed normally")
  #expect(model.voice?.problem == VoiceError.microphoneDenied.description)
  // An intentional mic click retries after the user changes System Settings.
  model.toggleVoice()
  fake.feeds[1].yield(.ready)
  #expect(await eventually { model.voice?.state == .listening })
  model.dismiss()
  model.armVoice()
  #expect(fake.feeds.count == 3)
  await model.finish()
}

@MainActor @Test func armedNoiseKeepsTextAndEscapeClosesNormally() async {
  let fake = FakeTranscriber()
  var input = "existing input"
  let voice = VoiceInput(transcriber: { fake }, write: { input = $0 })
  voice.arm()
  fake.feeds[0].yield(.ready)
  for noise in ["", "  ", "…", "-", "。..."] { fake.feeds[0].yield(.transcript(noise)) }
  #expect(await eventually { voice.state == .listening })
  #expect(input == "existing input")
  #expect(voice.keyPressed(isEscape: true))
  #expect(voice.state == .idle && fake.stops == 1)
}

@MainActor @Test(arguments: [false, true])
func onlyThePermissionDialogBorrowsFocusDuringStartup(_ permission: Bool) async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: folder.appending(path: "usage.json")), folder: folder,
    transcriber: { fake })
  let controller = PaletteController(model: model, panel: RoutingPanel())
  model.armVoice()
  if permission {
    fake.feeds[0].yield(.permission(true))
    #expect(await eventually { model.voice?.requestingPermission == true })
  }
  model.input = "kept through consent"
  controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
  #expect(model.voice?.active == permission)
  if permission {
    fake.feeds[0].yield(.permission(false))
    fake.feeds[0].yield(.ready)
    #expect(await eventually { model.voice?.state == .listening })
    #expect(model.input == "kept through consent")
  } else {
    #expect(model.input.isEmpty)
  }
  await model.finish()
}

@MainActor @Test func transcriptActivityCannotExtendTheHardLimit() async throws {
  let fake = FakeTranscriber()
  let voice = VoiceInput(transcriber: { fake }, write: { _ in })
  voice.silenceDuration = .seconds(2)
  voice.maximumDuration = .milliseconds(500)
  let started = ContinuousClock.now
  voice.toggle()
  fake.feeds[0].yield(.ready)
  while voice.active, ContinuousClock.now - started < .milliseconds(5000) {
    fake.feeds[0].yield(.transcript("words at \(ContinuousClock.now)"))
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(voice.state == .idle && fake.stops == 1 && voice.problem == nil)
  voice.stop()
}

// Disabled: under parallel load the 250 ms startup timer can fire before the session reads the
// fake's first update, so the test fails about one run in three. Not a product bug (the real
// deadline is 60 s); the fix is an injectable clock in VoiceInput, see ISSUES.md.
@MainActor @Test(.disabled("Timing race under parallel load; needs an injectable clock"))
func permissionWaitDoesNotUseStartupOrCaptureDeadlines() async throws {
  let fake = FakeTranscriber()
  let voice = VoiceInput(transcriber: { fake }, write: { _ in })
  voice.silenceDuration = .milliseconds(250)
  voice.maximumDuration = .milliseconds(400)
  var restored = 0
  voice.onPermissionFinished = { restored += 1 }
  voice.arm()
  fake.feeds[0].yield(.permission(true))
  #expect(await eventually { voice.requestingPermission })
  try await Task.sleep(for: .milliseconds(550))
  #expect(voice.state == .starting && voice.requestingPermission && fake.stops == 0)
  fake.feeds[0].yield(.permission(false))
  fake.feeds[0].yield(.ready)
  #expect(await eventually { voice.state == .listening })
  #expect(restored == 1 && !voice.requestingPermission)
  #expect(await eventually { voice.state == .idle })
}

@MainActor @Test func launchPresentationNeverArmsAndLoginNeverPresents() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    transcriber: { fake })
  let controller = PaletteController(model: model, panel: RoutingPanel())
  let event = NSAppleEventDescriptor(
    eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
  event.setParam(NSAppleEventDescriptor(enumCode: keyAELaunchedAsLogInItem), forKeyword: keyAEPropData)
  controller.showOnLaunch(event, orderFront: false)
  #expect(controller.panel.frame == .zero && model.voice == nil && fake.feeds.isEmpty)
  controller.showOnLaunch(nil, orderFront: false)
  #expect(controller.panel.frame != .zero && model.voice == nil && fake.feeds.isEmpty)
  controller.hide()
  controller.show(orderFront: false)
  #expect(model.voice?.active == true && fake.feeds.count == 1)
  controller.hide()
  await model.finish()
}

@MainActor @Test func partialSpeechUpdatesBuiltinsButExtensionsWaitForSettledInput() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let log = root.appending(path: "requests.txt")
  let encoder = JSONEncoder()
  encoder.outputFormatting = .withoutEscapingSlashes
  let path = String(data: try encoder.encode(log.path), encoding: .utf8)!
  _ = try extensionFolder(
    root,
    script:
      "import json,sys\nr=json.load(sys.stdin)\nopen(\(path),'a').write(r['input']+'\\n')\nprint(json.dumps({'items':[]}))",
    fields: ["match": ".+", "command": ["/usr/bin/python3", "main.sh"]])
  let fake = FakeTranscriber()
  let model = LauncherModel(
    providers: [MathProvider()], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    transcriber: { fake })
  model.store.update { $0.providers = [.init("math"), .init("extension:test")] }
  await model.extensions.reload()
  await model.settled()
  model.armVoice()
  fake.feeds[0].yield(.ready)
  for number in 1...4 {
    fake.feeds[0].yield(.transcript("2+\(number)"))
    #expect(await eventually { model.results.first?.row.title == String(2 + number) })
    try await Task.sleep(for: .milliseconds(80))
    #expect(!FileManager.default.fileExists(atPath: log.path))
  }
  await model.settled()
  #expect(try String(contentsOf: log, encoding: .utf8) == "2+4\n")
  await model.finish()
}

@MainActor @Test func lastVoiceTimingContainsOnlyLatencyAndIsOverwritten() async throws {
  let folder = try scratch()
  defer { try? FileManager.default.removeItem(at: folder) }
  let url = folder.appending(path: "voice-timing.txt")
  let fake = FakeTranscriber()
  let voice = VoiceInput(transcriber: { fake }, timingURL: url, write: { _ in })
  voice.arm()
  fake.feeds[0].yield(.audio(.now))
  fake.feeds[0].yield(.transcript("private words"))
  #expect(
    await eventually {
      (try? String(contentsOf: url, encoding: .utf8).contains("first transcript: none")) == false
    })
  let text = try String(contentsOf: url, encoding: .utf8)
  #expect(text.contains("first audio:") && text.contains(" ms") && !text.contains("private words"))
  voice.stop()
  voice.arm()
  #expect(try String(contentsOf: url, encoding: .utf8) == text)  // Opening does no disk write.
  voice.stop()
  #expect(
    await eventually { (try? String(contentsOf: url, encoding: .utf8).contains("first audio: none")) == true }
  )
}

@MainActor @Test func hideIsImmediateEvenWhenVoiceShutdownHangs() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let fake = FakeTranscriber()
  let (closing, finish) = AsyncStream.makeStream(of: Void.self)
  var closed = false
  fake.shutdown = Task {
    for await _ in closing {}
    closed = true
  }
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    transcriber: { fake })
  let panel = HideOrderPanel()
  let controller = PaletteController(model: model, panel: panel)
  panel.onHide = { #expect(!closed && fake.stops >= 1) }
  model.armVoice()
  controller.hide()
  #expect(fake.stops == 1 && panel.hides == 1)
  model.stopVoice()
  controller.hide()
  #expect(panel.hides == 2)
  // The main actor still runs while shutdown is suspended. No window is ordered front.
  finish.finish()
  #expect(await eventually { closed })
  await model.finish()
}

@MainActor private final class HideOrderPanel: PalettePanel {
  var hides = 0
  var onHide: () -> Void = {}
  override func orderOut(_ sender: Any?) {
    onHide()
    hides += 1
  }
}

@MainActor @Test func disablingAndRearmingVoiceWaitsForPreviousCaptureShutdown() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let fake = FakeTranscriber()
  let (closing, finish) = AsyncStream.makeStream(of: Void.self)
  fake.shutdown = Task { for await _ in closing {} }
  let model = LauncherModel(
    providers: [], history: UsageHistory(url: root.appending(path: "usage.json")), folder: root,
    transcriber: { fake })
  model.armVoice()
  let voice = model.voice
  model.store.update { $0.voice.enabled = false }
  #expect(model.voice === voice && voice?.state == .idle)
  model.store.update { $0.voice.enabled = true }
  model.armVoice()
  #expect(model.voice === voice)
  await Task.yield()
  #expect(fake.feeds.count == 1)
  finish.finish()
  #expect(await eventually { fake.feeds.count == 2 })
  await model.finish()
}
