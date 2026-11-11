import Foundation
import Observation

enum VoiceUpdate: Sendable {
  case permission(Bool)
  case audio(ContinuousClock.Instant)
  case ready
  case transcript(String)
}

/// The only hardware boundary. Construction is lazy; stop must release capture immediately.
@MainActor protocol Transcriber {
  func start() -> AsyncThrowingStream<VoiceUpdate, any Error>
  func stop()
  var shutdown: Task<Void, Never>? { get }
}
extension Transcriber { var shutdown: Task<Void, Never>? { nil } }

@MainActor @Observable
final class VoiceInput {
  enum State { case idle, starting, listening }
  private(set) var state = State.idle
  private(set) var requestingPermission = false
  @ObservationIgnored var onPermissionFinished: () -> Void = {}
  @ObservationIgnored private var permissionDenied = false
  private(set) var problem: String?
  @ObservationIgnored private let makeTranscriber: () -> any Transcriber
  @ObservationIgnored private let write: (String) -> Void
  @ObservationIgnored private var transcriber: (any Transcriber)?
  @ObservationIgnored private var session: Task<Void, Never>?
  @ObservationIgnored private var timer: Task<Void, Never>?
  @ObservationIgnored private var started = ContinuousClock.now
  @ObservationIgnored private var permissionStarted: ContinuousClock.Instant?
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private let timingURL: URL?
  @ObservationIgnored private(set) var shutdown: Task<Void, Never>?
  @ObservationIgnored private let timingWriter: LatestWriter<String>
  @ObservationIgnored private var timingSaved = false
  @ObservationIgnored private var firstAudio: Duration?
  @ObservationIgnored private var firstTranscript: Duration?
  @ObservationIgnored private var opened = ContinuousClock.now
  var silenceDuration: Duration = .seconds(60)
  var maximumDuration: Duration = .seconds(300)

  init(transcriber: @escaping () -> any Transcriber, timingURL: URL? = nil, write: @escaping (String) -> Void)
  {
    self.timingURL = timingURL
    timingWriter = LatestWriter { text in
      guard let timingURL else { return }
      try? text.write(to: timingURL, atomically: true, encoding: .utf8)
    }
    makeTranscriber = transcriber
    self.write = write
  }
  var active: Bool { state != .idle }
  func toggle() { if active { stop() } else { start() } }
  func arm() { if !permissionDenied, !active { start() } }
  private func start() {
    problem = nil
    state = .starting
    generation += 1
    let current = generation
    started = .now
    opened = started
    firstAudio = nil
    firstTranscript = nil
    timingSaved = false
    let source = makeTranscriber()
    transcriber = source
    let stream: AsyncThrowingStream<VoiceUpdate, any Error>
    if let shutdown {
      stream = AsyncThrowingStream { feed in
        let pending = Task {
          await shutdown.value
          guard !Task.isCancelled else {
            feed.finish()
            return
          }
          do {
            for try await update in source.start() { feed.yield(update) }
            feed.finish()
          } catch { feed.finish(throwing: error) }
        }
        feed.onTermination = { _ in pending.cancel() }
      }
    } else {
      stream = source.start()
    }
    // Bounds startup as well as capture, even if the system service never replies.
    stopAfterSilence()
    session = Task { [weak self] in
      do {
        for try await update in stream {
          guard let self, !Task.isCancelled, generation == current else { return }
          switch update {
          case .permission(let pending):
            requestingPermission = pending
            if pending {
              permissionStarted = .now
              timer?.cancel()
            } else {
              if let permissionStarted { started += .now - permissionStarted }
              permissionStarted = nil
              stopAfterSilence()
              onPermissionFinished()
            }
          case .audio(let time):
            firstAudio = time - opened
          case .ready:
            permissionDenied = false
            state = .listening
            guard generation == current else { return }
            stopAfterSilence()
          case .transcript(let text):
            let text = Transcript.searchText(text)
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if firstTranscript == nil {
              firstTranscript = .now - opened
              saveTiming()
            }
            write(text)
            stopAfterSilence()
          }
        }
        guard let self, generation == current else { return }
        stop()
      } catch {
        guard let self, generation == current else { return }
        permissionDenied = error as? VoiceError == .microphoneDenied
        stop()
        problem = (error as? VoiceError)?.description ?? "Couldn't listen. Try again."
      }
    }
  }
  private func saveTiming() {
    guard timingURL != nil, !timingSaved else { return }
    timingSaved = true
    func milliseconds(_ value: Duration?) -> String {
      value.map {
        "\(Int(Double($0.components.seconds) * 1000 + Double($0.components.attoseconds) / 1e15)) ms"
      } ?? "none"
    }
    timingWriter.submit(
      "Last voice session: \(Date())\nOpen to first audio: \(milliseconds(firstAudio))\nOpen to first transcript: \(milliseconds(firstTranscript))\n"
    )
  }
  func stop() {
    guard active else { return }
    generation += 1
    transcriber?.stop()
    shutdown = transcriber?.shutdown ?? shutdown
    transcriber = nil
    saveTiming()
    session?.cancel()
    session = nil
    timer?.cancel()
    timer = nil
    requestingPermission = false
    permissionStarted = nil
    state = .idle
  }
  /// Any key hands input to typing. Escape stops capture before navigating.
  func keyPressed(isEscape: Bool) -> Bool {
    guard active else { return false }
    let consumed = isEscape
    stop()
    return consumed
  }
  private func stopAfterSilence() {
    guard active, !requestingPermission else { return }
    timer?.cancel()
    let current = generation
    let deadline = min(started + maximumDuration, .now + silenceDuration)
    timer = Task { [weak self] in
      try? await Task.sleep(until: deadline, clock: .continuous)
      guard !Task.isCancelled, let self, generation == current else { return }
      let starting = state == .starting
      stop()
      if starting { problem = "Voice didn't start. Check permissions and try again." }
    }
  }
}

enum VoiceError: Error, Equatable, CustomStringConvertible {
  case microphoneDenied, noMicrophone, noLanguage, modelMissing, usageMissing, conversionFailed, inputChanged
  var description: String {
    switch self {
    case .microphoneDenied: "Microphone denied. Allow Wicket in System Settings."
    case .noMicrophone: "No microphone. Check Sound → Input in System Settings."
    case .noLanguage: "No on-device speech for your preferred languages."
    case .modelMissing: "Speech model missing. Check macOS Dictation settings."
    case .inputChanged: "Microphone changed. Open Wicket again to retry."
    case .conversionFailed: "Couldn't convert microphone audio. Check Sound → Input."
    case .usageMissing: "Open the Wicket app bundle to use voice."
    }
  }
}
