import Foundation
import Observation

/// Whether speech is writing the input now. A request made meanwhile waits a moment (`Navigator.refresh`),
/// so a process does not run for every revision of a transcript. The navigator stops it, synchronously,
/// before what it runs or writes into the input itself (a Return replayed, a prefill), which a later
/// transcript would otherwise overwrite.
@MainActor protocol Speech: AnyObject {
  var speaking: Bool { get }
  var status: String? { get }
  func stop(_ reason: VoiceStop)
}

/// What the panel types and says into the screens: edits of the input and its slots, and dictation. It
/// owns the panel's voice, made on first use, and stops it before anything else the user does: a key, an
/// edit, hiding, or a screen that no longer takes speech (a turn running or a permission waiting).
/// Transcripts go to the navigator as the whole input.
@MainActor @Observable
final class PanelInput: Speech {
  private let navigator: Navigator
  private let agent: AgentSession
  private let store: ConfigurationStore
  private(set) var voice: VoiceInput?
  @ObservationIgnored private let makeTranscriber: () -> any Transcriber
  @ObservationIgnored private let timingURL: URL
  @ObservationIgnored private let runtime: RuntimeRecorder?
  /// The panel takes the keys back when the microphone's consent dialog is done.
  @ObservationIgnored private let permissionFinished: () -> Void

  init(
    navigator: Navigator, agent: AgentSession, store: ConfigurationStore, folder: URL,
    transcriber: @escaping () -> any Transcriber, runtime: RuntimeRecorder? = nil,
    permissionFinished: @escaping () -> Void
  ) {
    self.navigator = navigator
    self.agent = agent
    self.store = store
    self.runtime = runtime
    makeTranscriber = transcriber
    timingURL = folder.appending(path: "voice-timing.txt")
    self.permissionFinished = permissionFinished
    navigator.speech = self
  }

  var offersVoice: Bool { agent.takesSpeech }
  var bluetoothHint: String? {
    offersVoice && voice?.bluetoothOnly == true ? VoiceError.bluetoothOnly.description : nil
  }
  var speaking: Bool { voice?.active == true }
  /// What voice says in the panel, including after a failure.
  var status: String? {
    if voice?.state == .starting { return "Starting voice…" }
    if voice?.state == .listening { return "Listening…" }
    return voice?.problem
  }
  func stop(_ reason: VoiceStop) { voice?.stop(reason) }
  func arm() {
    guard store.configuration.voice.listenOnOpen else { return }
    prepare()?.arm()
  }
  func toggle() { prepare()?.toggle() }
  private func prepare() -> VoiceInput? {
    guard offersVoice else { return nil }
    if voice == nil {
      voice = VoiceInput(
        transcriber: makeTranscriber, timingURL: timingURL, runtime: runtime,
        write: { [weak self] text in
          guard let self, agent.takesSpeech else {
            self?.stop(.busy)
            return
          }
          navigator.dictate(text)
        })
      voice?.onPermissionFinished = permissionFinished
    }
    return voice
  }
  /// A key stops dictation before it does anything else; Escape does nothing else (true).
  func keyPressed(_ action: PaletteKeyAction) -> Bool {
    voice?.keyPressed(isEscape: action == .dismiss) ?? false
  }
  /// The input's native field changed, by typing, paste or an input method's commit.
  func edit(_ edit: InputEdit) {
    stop(.edit)
    navigator.editInput(edit)
  }
  func edit(_ text: String) { edit(InputEdit(text, from: navigator.input)) }
  /// A field slot's native field changed.
  func edit(field name: String, to value: String) {
    navigator.setField(name, to: value)
  }
  /// The panel drew a screen that no longer takes speech.
  func screensChanged() {
    if speaking && !offersVoice { stop(.busy) }
  }
  /// Quitting: give capture the same bounded wait to close as a reopen.
  func finish() async {
    stop(.quit)
    await voice?.shutdown?.value
  }
}

extension String {
  var singleLineInput: String {
    guard rangeOfCharacter(from: .newlines) != nil else { return self }
    return replacingOccurrences(of: #"\R+"#, with: " ", options: .regularExpression)
  }
}

/// An edit of a native field: the text it holds now (`text`), the text it was made on (`base`), and what
/// it inserted there, found by the UTF-16 range around the insertion. Typing during a screen switch
/// carries only what it inserted into the screen arriving (`Navigator.editInput`), wherever the caret was.
struct InputEdit: Equatable {
  let text: String
  let base: String
  let inserted: String
  init(text: String, base: String, inserted: String) {
    self.text = text
    self.base = base
    self.inserted = inserted
  }
  /// The edit that turned `base` into `text`, its insertion ending at UTF-16 offset `end` of `text` (the
  /// caret after it, or the end), which places it among repeated characters, and starting no later than
  /// `limit` when the field knows where it changed. What `text` keeps of `base`'s start and end is not
  /// inserted; text that cannot be such an edit was inserted as a whole.
  init(_ text: String, from base: String, startingBy limit: Int? = nil, endingAt end: Int? = nil) {
    let new = Array(text.utf16)
    let old = Array(base.utf16)
    let end = min(max(end ?? new.count, 0), new.count)
    let kept = new.count - end
    guard kept <= old.count, old.suffix(kept) == new.suffix(kept) else {
      self.init(text: text, base: base, inserted: text)
      return
    }
    var start = 0
    while start < min(end, old.count - kept, limit ?? .max), old[start] == new[start] { start += 1 }
    // Never inside a surrogate pair.
    if start > 0, start < end, UTF16.isTrailSurrogate(new[start]) { start -= 1 }
    self.init(text: text, base: base, inserted: String(decoding: new[start..<end], as: UTF16.self))
  }
}
