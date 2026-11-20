import Foundation
import Observation

/// Whether speech is writing the input now. A request made meanwhile waits a moment (`Navigator.refresh`),
/// so a process does not run for every revision of a transcript.
@MainActor protocol Speech: AnyObject {
  var speaking: Bool { get }
}

/// What the panel types and says into the screens: edits of the input and its slots, and dictation. It
/// owns the panel's voice, made on first use, and stops it before anything else the user does: a key, an
/// edit, hiding, or a screen that no longer takes speech (a turn running, a permission waiting, voice
/// switched off). Transcripts go to the navigator as the whole input.
@MainActor @Observable
final class PanelInput: Speech {
  private let navigator: Navigator
  private let agent: AgentSession
  private let store: ConfigurationStore
  private(set) var voice: VoiceInput?
  @ObservationIgnored private let makeTranscriber: () -> any Transcriber
  @ObservationIgnored private let timingURL: URL
  /// The panel takes the keys back when the microphone's consent dialog is done.
  @ObservationIgnored private let permissionFinished: () -> Void

  init(
    navigator: Navigator, agent: AgentSession, store: ConfigurationStore, folder: URL,
    transcriber: @escaping () -> any Transcriber, permissionFinished: @escaping () -> Void
  ) {
    self.navigator = navigator
    self.agent = agent
    self.store = store
    makeTranscriber = transcriber
    timingURL = folder.appending(path: "voice-timing.txt")
    self.permissionFinished = permissionFinished
    navigator.speech = self
  }

  /// Whether the mic button shows: voice is on and the screen takes speech.
  var offersVoice: Bool { store.configuration.voice.enabled && agent.takesSpeech }
  var speaking: Bool { voice?.active == true }
  func stop(_ reason: VoiceStop) { voice?.stop(reason) }
  func arm() { prepare()?.arm() }
  func toggle() { prepare()?.toggle() }
  private func prepare() -> VoiceInput? {
    guard offersVoice else { return nil }
    if voice == nil {
      voice = VoiceInput(
        transcriber: makeTranscriber, timingURL: timingURL,
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
  func edit(_ text: String) {
    stop(.edit)
    navigator.editInput(text)
  }
  /// An argument slot's native field changed.
  func edit(argument name: String, to value: String) {
    navigator.setArgument(name, to: value)
  }
  /// The panel drew the screens: one that no longer takes speech, or voice switched off, ends dictation.
  func screensChanged() {
    guard speaking else { return }
    if !store.configuration.voice.enabled {
      stop(.disabled)
    } else if !agent.takesSpeech {
      stop(.busy)
    }
  }
  /// Quitting: capture stops, and this returns once the microphone is closed.
  func finish() async {
    stop(.quit)
    await voice?.shutdown?.value
  }
}
