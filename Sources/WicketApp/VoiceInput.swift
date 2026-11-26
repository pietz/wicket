import Foundation
import Observation
import os

/// Voice diagnostics for `log show --predicate 'subsystem == "app.wicket" AND category == "voice"'`:
/// why capture stopped, error domains and codes, and timings. Never device names, transcripts or locales.
enum VoiceLog {
  static let logger = Logger(subsystem: "app.wicket", category: "voice")
  static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    Int((ContinuousClock.now - start) / .milliseconds(1))
  }
  /// Report only stable error identifiers from the voice pipeline and system APIs.
  static func describe(_ error: any Error) -> String {
    if let system = error as? VoiceSystemError {
      return "\(system.category.rawValue) (\(system.domain) \(system.code))"
    }
    if let error = error as? VoiceError { return error.rawValue }
    let error = error as NSError
    return "\(error.domain) \(error.code)"
  }
}

/// Why capture stopped: the one thing the log needs to tell a key or edit from a failure.
enum VoiceStop: String, Sendable {
  case toggle, key, escape, edit, hidden, run, busy, quit, ended, failed, startTimeout, noSpeech,
    silence, limit, bluetoothOnly
}

enum VoiceUpdate: Sendable {
  case permission(Bool)
  case openingMicrophone(ContinuousClock.Instant)
  case audio(ContinuousClock.Instant)
  case ready
  case transcript(String)
}

/// The only hardware boundary. Construction is lazy and stop must return immediately.
@MainActor protocol Transcriber {
  func start(allowBluetooth: Bool) -> AsyncThrowingStream<VoiceUpdate, any Error>
  func stop()
  var shutdown: AsyncStream<Never>? { get }
}
extension Transcriber { var shutdown: AsyncStream<Never>? { nil } }

@MainActor @Observable
final class VoiceInput {
  enum State { case idle, starting, listening }
  private(set) var state = State.idle
  private(set) var requestingPermission = false
  @ObservationIgnored var onPermissionFinished: () -> Void = {}
  @ObservationIgnored private var permissionDenied = false
  private(set) var problem: String?
  private(set) var bluetoothOnly = false
  @ObservationIgnored private let makeTranscriber: () -> any Transcriber
  @ObservationIgnored private let write: (String) -> Void
  @ObservationIgnored private var transcriber: (any Transcriber)?
  @ObservationIgnored private var session: Task<Void, Never>?
  @ObservationIgnored private var timer: Task<Void, Never>?
  @ObservationIgnored private var listeningStarted = ContinuousClock.now
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private let timingURL: URL?
  @ObservationIgnored private let runtime: RuntimeRecorder?
  @ObservationIgnored private(set) var shutdown: Task<Void, Never>?
  @ObservationIgnored private let timingWriter: LatestWriter<String>
  @ObservationIgnored private var timingSaved = false
  @ObservationIgnored private var firstAudio: Duration?
  @ObservationIgnored private var firstTranscript: Duration?
  @ObservationIgnored private var opened = ContinuousClock.now
  var startupDuration: Duration = .seconds(8)
  var shutdownDuration: Duration = .milliseconds(500)
  var silenceDuration: Duration = .seconds(60)
  /// Listening ends this soon after capture is ready when nothing has been said yet, so the microphone
  /// goes off quickly whenever Wicket is opened only to type.
  var noSpeechDuration: Duration = .seconds(3)
  var maximumDuration: Duration = .seconds(300)

  init(
    transcriber: @escaping () -> any Transcriber, timingURL: URL? = nil, runtime: RuntimeRecorder? = nil,
    write: @escaping (String) -> Void
  ) {
    self.timingURL = timingURL
    self.runtime = runtime
    timingWriter = LatestWriter { text in
      guard let timingURL else { return }
      try? text.write(to: timingURL, atomically: true, encoding: .utf8)
    }
    makeTranscriber = transcriber
    self.write = write
  }
  var active: Bool { state != .idle }
  func toggle() { if active { stop(.toggle) } else { start(allowBluetooth: true) } }
  func arm() { if !permissionDenied, !active { start(allowBluetooth: false) } }
  private func start(allowBluetooth: Bool) {
    problem = nil
    bluetoothOnly = false
    state = .starting
    generation += 1
    let current = generation
    opened = .now
    firstAudio = nil
    firstTranscript = nil
    timingSaved = false
    let source = makeTranscriber()
    transcriber = source
    let previous = shutdown
    let stream = previous == nil ? source.start(allowBluetooth: allowBluetooth) : nil
    session = Task { [weak self] in
      await previous?.value
      guard !Task.isCancelled else { return }
      do {
        for try await update in stream ?? source.start(allowBluetooth: allowBluetooth) {
          guard let self, !Task.isCancelled, generation == current else { return }
          switch update {
          case .permission(let pending):
            requestingPermission = pending
            if !pending { onPermissionFinished() }
          case .openingMicrophone(let time):
            scheduleStop(at: time + startupDuration, reason: .startTimeout)
          case .audio(let time): firstAudio = time - opened
          case .ready:
            permissionDenied = false
            listeningStarted = .now
            state = .listening
            guard generation == current else { return }
            scheduleStop()
          case .transcript(let text):
            let text = Transcript.searchText(text)
            guard text.contains(where: { $0.isLetter || $0.isNumber }) else { continue }
            if firstTranscript == nil {
              firstTranscript = .now - opened
              saveTiming()
            }
            write(text)
            scheduleStop()
          }
        }
        guard let self, generation == current else { return }
        stop(.ended)
      } catch VoiceError.bluetoothOnly {
        guard let self, generation == current else { return }
        stop(.bluetoothOnly)
        bluetoothOnly = true
      } catch {
        guard let self, generation == current else { return }
        let silent = error as? SilentMicrophone
        let diagnostic: any Error = silent == nil ? error : VoiceError.silentMicrophone
        VoiceLog.logger.error("voice failed: \(VoiceLog.describe(diagnostic), privacy: .public)")
        let category = (diagnostic as? VoiceSystemError)?.category ?? diagnostic as? VoiceError
        permissionDenied = category == .microphoneDenied
        runtime?.voiceFailed(diagnostic, reason: .failed)
        stop(.failed)
        problem = silent?.message ?? category?.description ?? "Couldn't listen. Try again."
      }
    }
  }
  private func saveTiming() {
    guard timingURL != nil, !timingSaved else { return }
    timingSaved = true
    func milliseconds(_ value: Duration?) -> String {
      value.map { "\(Int($0 / .milliseconds(1))) ms" } ?? "none"
    }
    timingWriter.submit(
      "Last voice session: \(Date())\nOpen to first audio: \(milliseconds(firstAudio))\nOpen to first transcript: \(milliseconds(firstTranscript))\n"
    )
  }
  func stop(_ reason: VoiceStop) {
    // Dismissal ends the session the hint was for, even while voice is idle.
    if reason == .hidden { bluetoothOnly = false }
    guard active else { return }
    VoiceLog.logger.log(
      "voice stop: \(reason.rawValue, privacy: .public) while \(self.state == .listening ? "listening" : "starting", privacy: .public), \(VoiceLog.milliseconds(since: self.opened), privacy: .public) ms after start"
    )
    generation += 1
    transcriber?.stop()
    if let closing = transcriber?.shutdown {
      let deadline = ContinuousClock.now + shutdownDuration
      // A driver can stall its capture queue. Cancel the stream wait so the next session can open.
      shutdown = Task {
        await withTaskGroup(of: Void.self) { group in
          group.addTask { for await _ in closing {} }
          group.addTask { try? await Task.sleep(until: deadline, clock: .continuous) }
          await group.next()
          group.cancelAll()
        }
      }
    }
    transcriber = nil
    saveTiming()
    session?.cancel()
    session = nil
    timer?.cancel()
    timer = nil
    requestingPermission = false
    state = .idle
  }
  /// Any key hands input to typing. Escape stops capture before navigating.
  func keyPressed(isEscape: Bool) -> Bool {
    guard active else { return false }
    stop(isEscape ? .escape : .key)
    return isEscape
  }
  private func scheduleStop() {
    guard state == .listening else { return }
    let limit = listeningStarted + maximumDuration
    // Past the hard limit a transcript stops capture itself: continuous speech (or a TV) would
    // otherwise keep replacing the timer before it gets to run.
    guard ContinuousClock.now < limit else { return stop(.limit) }
    let waiting = firstTranscript == nil
    let deadline = min(limit, .now + (waiting ? noSpeechDuration : silenceDuration))
    scheduleStop(at: deadline, reason: deadline == limit ? .limit : waiting ? .noSpeech : .silence)
  }
  private func scheduleStop(at deadline: ContinuousClock.Instant, reason: VoiceStop) {
    timer?.cancel()
    let current = generation
    timer = Task { [weak self] in
      try? await Task.sleep(until: deadline, clock: .continuous)
      guard !Task.isCancelled, let self, generation == current else { return }
      stop(reason)
      if reason == .startTimeout {
        runtime?.voiceFailed(VoiceError.microphoneStartFailed, reason: reason)
        problem = VoiceError.microphoneStartFailed.description
      }
    }
  }
}

struct VoiceSystemError: Error {
  let category: VoiceError
  let domain: String
  let code: Int
}

struct SilentMicrophone: Error {
  let deviceName: String
  var message: String { "No sound from \(deviceName). Check Sound → Input." }
}

/// The raw value is the case alone, for the log.
enum VoiceError: String, Error, Equatable, CustomStringConvertible {
  case microphoneDenied, noMicrophone, microphoneStartFailed, noLanguage, modelMissing, usageMissing,
    conversionFailed, inputChanged, bluetoothOnly, lidClosed, silentMicrophone
  var description: String {
    switch self {
    case .microphoneDenied: "Microphone denied. Allow Wicket in System Settings."
    case .noMicrophone: "No microphone. Check Sound → Input in System Settings."
    case .bluetoothOnly: "Voice off: Bluetooth mic only. Click the mic to use it."
    case .lidClosed: "Built-in mic is muted with the lid closed. Connect a mic or open the lid."
    case .silentMicrophone: "No sound from the microphone. Check Sound → Input."
    case .microphoneStartFailed: "Microphone didn't start. Try again."
    case .noLanguage: "No on-device speech for your preferred languages."
    case .modelMissing: "Speech model missing. Check macOS Dictation settings."
    case .inputChanged: "Microphone changed. Open Wicket again to retry."
    case .conversionFailed: "Couldn't convert microphone audio. Check Sound → Input."
    case .usageMissing: "Open the Wicket app bundle to use voice."
    }
  }
}
