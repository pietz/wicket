import Foundation
import Synchronization
import Testing
import WicketCore

@testable import WicketApp

/// A microphone the test speaks into: each `transcribe()` hands out the next session, whose
/// continuation the test drives, and records when its consumer stopped listening.
private final class FakeTranscriber: Transcriber {
    let stream: AsyncThrowingStream<String, any Error>
    let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let ended = Flag()

    init() {
        (stream, continuation) = AsyncThrowingStream.makeStream(of: String.self)
        continuation.onTermination = { [ended] _ in ended.value.withLock { $0 = true } }
    }

    var isStopped: Bool { ended.value.withLock { $0 } }
    func transcribe() -> AsyncThrowingStream<String, any Error> { stream }
}

private final class Flag: Sendable {
    let value = Mutex(false)
}

@MainActor
private final class Harness {
    let consent: VoiceConsent
    let voice: VoiceInput
    private(set) var sessions: [FakeTranscriber] = []
    private(set) var written: [String] = []
    private(set) var failures: [String] = []
    var accepts = true

    init(mode: VoiceMode = .onOpen, timing: VoiceInput.Timing = .init()) throws {
        consent = VoiceConsent(url: temporaryURL())
        try consent.set(mode)
        weak var harness: Harness?
        voice = VoiceInput(consent: consent, timing: timing) {
            let session = FakeTranscriber()
            harness?.sessions.append(session)
            return session
        }
        harness = self
        voice.write = { [weak self] text in
            guard let self, accepts else { return false }
            written.append(text)
            return true
        }
        voice.fail = { [weak self] in self?.failures.append($0) }
    }

    var session: FakeTranscriber { sessions[sessions.count - 1] }
}

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory.appending(path: "wicket-tests/\(UUID().uuidString)/voice.json")
}

/// Waits up to two seconds of real time, for the timers' sake.
@MainActor
private func soon(_ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(2)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return condition()
}

/// Long enough that no timer fires during a test that doesn't wait for one.
private let patient = VoiceInput.Timing(silence: .seconds(30), noSpeech: .seconds(30), limit: .seconds(60))

@MainActor
struct VoiceInputTests {
    /// Words go into the field as they come (without a trailing full stop), and a short silence after
    /// them ends listening, which stops the microphone; nothing runs.
    @Test func wordsGoToTheFieldAndASilenceEndsListening() async throws {
        let harness = try Harness(timing: .init(silence: .milliseconds(60), noSpeech: .seconds(30)))
        harness.voice.listen()
        #expect(harness.voice.isListening)
        harness.session.continuation.yield("Open")
        #expect(await soon { harness.written == ["Open"] })
        harness.session.continuation.yield("Open Safari.")
        #expect(await soon { harness.written == ["Open", "Open Safari"] })
        #expect(await soon { !harness.voice.isListening })
        #expect(await soon { harness.session.isStopped })
        #expect(harness.failures.isEmpty)
    }

    /// Any key stops listening and goes on to the field; Escape only stops. What was said stays, and
    /// words the recognizer delivers afterwards are dropped.
    @Test func aKeyStopsListeningAndLateWordsAreDropped() async throws {
        let harness = try Harness(timing: patient)
        #expect(!harness.voice.keyPressed(isEscape: false))  // Not listening: the key is the field's.
        harness.voice.listen()
        harness.session.continuation.yield("Calendar")
        #expect(await soon { harness.written == ["Calendar"] })
        #expect(!harness.voice.keyPressed(isEscape: false))
        #expect(!harness.voice.isListening)
        #expect(await soon { harness.session.isStopped })
        harness.session.continuation.yield("Calendar tomorrow")
        await Task.yield()
        #expect(harness.written == ["Calendar"])

        harness.voice.listen()
        #expect(harness.sessions.count == 2)
        #expect(harness.voice.keyPressed(isEscape: true))
        #expect(!harness.voice.isListening)
        #expect(!harness.voice.keyPressed(isEscape: true))  // The next Escape is the field's again.
    }

    /// Nothing said: listening gives up after a while instead of keeping the microphone open.
    @Test func noSpeechGivesUp() async throws {
        let harness = try Harness(timing: .init(silence: .seconds(30), noSpeech: .milliseconds(50)))
        harness.voice.listen()
        #expect(await soon { !harness.voice.isListening })
        #expect(await soon { harness.session.isStopped })
        #expect(harness.written.isEmpty)
    }

    /// A failure says why, once, and listening stops.
    @Test func aFailureIsReported() async throws {
        let harness = try Harness(timing: patient)
        harness.voice.listen()
        harness.session.continuation.finish(throwing: VoiceError.microphoneNotAllowed)
        #expect(await soon { !harness.voice.isListening })
        #expect(harness.failures == [VoiceError.microphoneNotAllowed.description])
    }

    /// When the field no longer takes the words (a frame opened above the root), listening stops.
    @Test func aRefusedWriteStopsListening() async throws {
        let harness = try Harness(timing: patient)
        harness.accepts = false
        harness.voice.listen()
        harness.session.continuation.yield("Weather")
        #expect(await soon { !harness.voice.isListening })
        #expect(await soon { harness.session.isStopped })
    }

    /// On open the microphone is armed quietly: nothing is written, and the first key stops it and
    /// goes on to the field (Escape too, so it still clears or hides), leaving no text; words the
    /// recognizer delivers afterwards are dropped.
    @Test func typingWhileArmedStopsQuietly() async throws {
        let harness = try Harness(timing: patient)
        harness.voice.arm()
        #expect(harness.voice.state == .armed)
        #expect(!harness.voice.isListening)
        #expect(!harness.voice.keyPressed(isEscape: false))
        #expect(harness.voice.state == .idle)
        #expect(await soon { harness.session.isStopped })
        harness.session.continuation.yield("Safari")
        await Task.yield()
        #expect(harness.written.isEmpty)

        harness.voice.arm()
        #expect(!harness.voice.keyPressed(isEscape: true))
        #expect(harness.voice.state == .idle)
    }

    /// The first words heard while armed switch to listening in the open, and go into the field.
    @Test func firstWordsWhileArmedStartListening() async throws {
        let harness = try Harness(timing: patient)
        harness.voice.arm()
        harness.session.continuation.yield("")
        await Task.yield()
        #expect(harness.voice.state == .armed)
        harness.session.continuation.yield("Weather")
        #expect(await soon { harness.voice.isListening })
        #expect(harness.written == ["Weather"])
    }

    /// Armed, a silence just turns the microphone off: no failure, no text.
    @Test func armedSilenceStopsQuietly() async throws {
        let harness = try Harness(timing: .init(silence: .seconds(30), noSpeech: .milliseconds(50)))
        harness.voice.arm()
        #expect(await soon { harness.voice.state == .idle })
        #expect(await soon { harness.session.isStopped })
        #expect(harness.written.isEmpty)
        #expect(harness.failures.isEmpty)
    }

    /// The mic button and ⌘L (both `toggle`) while armed listen in the open on the same session,
    /// then stop.
    @Test func startingByHandWhileArmedKeepsTheSession() throws {
        let harness = try Harness(timing: patient)
        harness.voice.arm()
        harness.voice.toggle()
        #expect(harness.voice.isListening)
        #expect(harness.sessions.count == 1)
        harness.voice.toggle()
        #expect(harness.voice.state == .idle)
    }

    /// Off, nothing listens: not on open, not on Start Listening, which says where to turn it on.
    @Test func offNeverListens() throws {
        let harness = try Harness(mode: .off)
        #expect(!harness.voice.listensOnOpen)
        harness.voice.listen()
        harness.voice.arm()
        #expect(harness.voice.state == .idle)
        harness.voice.toggle()
        #expect(!harness.voice.isListening)
        #expect(harness.sessions.isEmpty)
        #expect(harness.failures == ["Voice is off. Turn it on in Settings ▸ Voice."])
    }

    /// The mic button, ⌘L and Start Listening toggle, listening in the open at once; "only when
    /// asked" doesn't arm on open.
    @Test func startingByHandToggles() throws {
        let harness = try Harness(mode: .onCommand, timing: patient)
        #expect(!harness.voice.listensOnOpen)
        harness.voice.toggle()
        #expect(harness.voice.isListening)
        harness.voice.toggle()
        #expect(!harness.voice.isListening)
    }
}

@MainActor
struct VoiceConsentTests {
    /// The consent survives a relaunch; a missing, damaged or newer file means off.
    @Test func persistsAndFailsClosed() throws {
        let url = temporaryURL()
        #expect(VoiceConsent(url: url).mode == .off)
        try VoiceConsent(url: url).set(.onCommand)
        #expect(VoiceConsent(url: url).mode == .onCommand)

        try Data("not json".utf8).write(to: url)
        #expect(VoiceConsent(url: url).mode == .off)
        try Data(#"{"version": 2, "listen": "onOpen"}"#.utf8).write(to: url)
        #expect(VoiceConsent(url: url).mode == .off)
        try Data(#"{"version": 1, "listen": "always"}"#.utf8).write(to: url)
        #expect(VoiceConsent(url: url).mode == .off)
    }
}

/// The language follows the user's preferred languages, region first, then the language's likely
/// region, never an arbitrary regional variant.
@Test func voiceLanguageFollowsPreferredLanguages() {
    let supported = ["en_SG", "en_IE", "en_US", "en_GB", "de_AT", "de_DE"].map { Locale(identifier: $0) }
    let choose = { VoiceLanguage.choose(preferred: $0, supported: supported)?.identifier }
    #expect(choose(["en-US", "de-DE"]) == "en_US")
    #expect(choose(["en-GB"]) == "en_GB")
    #expect(choose(["en-DE"]) == "en_US")
    #expect(choose(["en"]) == "en_US")
    #expect(choose(["de"]) == "de_DE")
    #expect(choose(["de-CH"]) == "de_DE")
    #expect(choose(["tlh", "de-AT"]) == "de_AT")
    #expect(choose(["tlh"]) == nil)
}
