import Foundation
import Observation
import WicketCore

/// When Wicket listens. Off until the user turns it on in Settings ▸ Voice.
enum VoiceMode: String, Codable, CaseIterable, Sendable {
    case off
    /// Only when the user asks: the mic button or ⌘L.
    case onCommand
    /// Armed quietly every time the palette opens, as well as when the user asks.
    case onOpen
}

/// Whether, and when, Wicket may listen: consent, so it is kept out of settings.json (principle 6:
/// an agent editing the file must not be able to switch the microphone on). A file in Application
/// Support written only by Settings ▸ Voice, like the approvals store. It fails closed: a missing or
/// unreadable file means off.
@MainActor
@Observable
final class VoiceConsent {
    private(set) var mode: VoiceMode
    @ObservationIgnored let url: URL

    /// Application Support/Wicket/voice.json.
    nonisolated static var defaultURL: URL {
        Edition.current.supportDirectory.appending(path: "voice.json")
    }

    init(url: URL = defaultURL) {
        self.url = url
        mode =
            (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)))
            .flatMap { $0.version == 1 ? $0.listen : nil } ?? .off
    }

    /// For Settings ▸ Voice only, after the user turned voice on there and the microphone is allowed.
    /// Memory changes only once the file is written.
    func set(_ mode: VoiceMode) throws {
        guard mode != self.mode else { return }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(File(version: 1, listen: mode)).write(to: url, options: .atomic)
        self.mode = mode
    }

    private struct File: Codable {
        var version: Int
        var listen: VoiceMode
    }
}

/// Live speech to text from the microphone: `AppleTranscriber`, a fake in tests.
protocol Transcriber: Sendable {
    /// Starts listening and yields the whole transcript each time it changes, until the stream's
    /// consumer stops iterating (which stops the microphone) or listening fails.
    func transcribe() -> AsyncThrowingStream<String, any Error>
}

/// The palette's voice input: listens, writes what is said into the search field as it comes, and
/// keeps listening through pauses until a key (Return included), Escape, ⌘L or the palette hiding
/// stops it; a minute without a new word turns the microphone off. Nothing runs by itself: the text is in the field and Return runs the top row, as
/// if it had been typed.
@MainActor
@Observable
final class VoiceInput {
    enum State {
        case idle
        /// The microphone is on, quietly, since the palette opened: nothing shows but a mic glyph,
        /// the first key ends it, and the first words (`isSpeech`) turn it into `listening`.
        case armed
        /// Listening in the open: a moving waveform takes the search glyph's place and the words go
        /// into the field.
        case listening
    }

    private(set) var state = State.idle
    var isListening: Bool { state == .listening }
    /// Puts a transcript into the search field; false when the field no longer takes it (a frame
    /// opened above the root), which stops listening.
    @ObservationIgnored var write: (String) -> Bool = { _ in false }
    /// Reports why listening failed or couldn't start.
    @ObservationIgnored var fail: (String) -> Void = { _ in }
    @ObservationIgnored let consent: VoiceConsent
    @ObservationIgnored private let transcriber: () -> any Transcriber
    @ObservationIgnored private let timing: Timing
    /// Bumped by every start and stop, so a late transcript from a stopped session is dropped.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var session: Task<Void, Never>?
    /// Ends listening after a long silence (or no speech at all), re-armed by every transcript.
    @ObservationIgnored private var silence: Task<Void, Never>?
    @ObservationIgnored private var limit: Task<Void, Never>?

    struct Timing {
        /// How long without a new word turns the microphone off once something was said: long, since
        /// dictation continues through pauses until the user presses a key (owner, 2026-11-08).
        var silence: Duration = .seconds(60)
        /// How long to wait for a first word before giving up.
        var noSpeech: Duration = .seconds(6)
        /// The longest one dictation may run, so background noise can't keep the microphone open.
        var limit: Duration = .seconds(300)
    }

    init(consent: VoiceConsent, timing: Timing = Timing(), transcriber: @escaping () -> any Transcriber) {
        self.consent = consent
        self.timing = timing
        self.transcriber = transcriber
    }

    var isEnabled: Bool { consent.mode != .off }
    var listensOnOpen: Bool { consent.mode == .onOpen }

    /// Turns the microphone on quietly (on open): see `State.armed`.
    func arm() {
        start(.armed)
    }

    /// Starts listening, if voice is on: in the open at once when armed, else a new session.
    func listen() {
        if state == .armed { state = .listening } else { start(.listening) }
    }

    private func start(_ state: State) {
        guard isEnabled, self.state == .idle else { return }
        generation += 1
        let current = generation
        self.state = state
        let start = ContinuousClock.now
        let stream = transcriber().transcribe()
        stop(after: timing.noSpeech)
        limit = Task { [weak self, timing] in
            try? await Task.sleep(for: timing.limit)
            guard !Task.isCancelled, let self, generation == current else { return }
            stop()
        }
        session = Task { [weak self] in
            var updates = 0
            do {
                for try await text in stream {
                    guard let self else { return }
                    // `stop` cancelled this task, so asking the stream for more ends it, and ending
                    // it stops the microphone. Returning here instead would leave that to chance.
                    guard generation == current else { continue }
                    let spoken = Transcript.searchText(text)
                    guard !spoken.isEmpty else { continue }
                    // Armed, only words open up: noise transcribed as "…" or "-" stays quiet.
                    guard isListening || Self.isSpeech(spoken) else { continue }
                    if updates == 0 { Perf.log("voice: first words after \(Perf.ms(since: start))") }
                    updates += 1
                    self.state = .listening
                    if write(spoken) { stop(after: timing.silence) } else { stop() }
                }
                guard let self, generation == current else { return }
                stop()
            } catch {
                guard let self, generation == current else { return }
                stop()
                fail(Self.describe(error))
            }
        }
    }

    /// Stops listening; what was said stays in the field.
    func stop() {
        guard state != .idle else { return }
        generation += 1
        state = .idle
        session?.cancel()
        silence?.cancel()
        limit?.cancel()
        session = nil
        silence = nil
        limit = nil
    }

    /// A key pressed in the palette stops the microphone, and typing takes over: the key goes on to
    /// the field. Armed, nothing was heard, so nothing is left behind and Escape does what it always
    /// does. Listening, Escape is consumed, so it only stops (what was said stays; a second Escape
    /// closes the palette). Returns whether the key was consumed.
    func keyPressed(isEscape: Bool) -> Bool {
        guard state != .idle else { return false }
        let consumed = isListening && isEscape
        stop()
        return consumed
    }

    /// The mic button and ⌘L: listens (in the open, if it was armed), or stops if it
    /// is listening already. Off, it says where to turn voice on rather than asking for the
    /// microphone from the palette.
    func toggle() {
        if isListening {
            stop()
        } else if isEnabled {
            listen()
        } else {
            fail("Voice is off. Turn it on in Settings ▸ Voice.")
        }
    }

    private func stop(after delay: Duration) {
        silence?.cancel()
        let current = generation
        silence = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, generation == current else { return }
            stop()
        }
    }

    /// Whether a transcript holds a word or a number, rather than only punctuation from noise.
    static func isSpeech(_ text: String) -> Bool {
        text.contains { $0.isLetter || $0.isNumber }
    }

    private static func describe(_ error: any Error) -> String {
        if let error = error as? VoiceError { return error.description }
        return "Couldn't listen: \(error.localizedDescription)"
    }
}

/// Why listening couldn't start, in words for the user.
enum VoiceError: Error, Equatable, CustomStringConvertible {
    case microphoneNotAllowed
    case noMicrophone
    case noLanguage
    case modelMissing

    var description: String {
        switch self {
        case .microphoneNotAllowed: "Wicket can't use the microphone. Allow it in Settings ▸ Voice."
        case .noMicrophone: "No microphone is available."
        case .noLanguage: "None of your languages can be transcribed on this Mac."
        case .modelMissing: "The speech model isn't downloaded yet. Get it in Settings ▸ Voice."
        }
    }
}
