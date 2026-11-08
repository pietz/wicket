import AVFoundation
import Speech
import WicketCore

/// On-device live transcription of the default microphone with Apple's SpeechAnalyzer and
/// SpeechTranscriber (macOS 26). The model runs in a system process (Wicket's own footprint grows by
/// a few MB while listening) and needs no speech recognition permission, only the microphone's.
struct AppleTranscriber: Transcriber {
    func transcribe() -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            // Off the main actor: starting the audio engine and the analyzer takes tens of ms.
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await Self.listen { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func listen(yield: @escaping @Sendable (String) -> Void) async throws {
        // Never prompt from here: a permission dialog would take the keyboard from the palette.
        guard AVAudioApplication.shared.recordPermission == .granted else {
            throw VoiceError.microphoneNotAllowed
        }
        guard let locale = await VoiceLanguage.locale() else { throw VoiceError.noLanguage }
        let transcriber = SpeechTranscriber(
            locale: locale, transcriptionOptions: [], reportingOptions: [.volatileResults, .fastResults],
            attributeOptions: [])
        // Not `AssetInventory.status`: it said `supported` for an installed model before its first use.
        guard try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) == nil else {
            throw VoiceError.modelMissing
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
            throw VoiceError.noLanguage
        }
        try Task.checkCancellation()
        let (inputs, feed) = AsyncStream.makeStream(of: AnalyzerInput.self)
        let microphone = try Microphone(format: format, feed: feed)
        // Lingering keeps the model loaded for a while after this utterance, so the next summon's
        // first words come faster (about 25 ms against 170 ms cold), and lets it go once voice rests.
        let analyzer = SpeechAnalyzer(
            modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        defer {
            microphone.stop()
            feed.finish()
        }
        try await withTaskCancellationHandler {
            try await analyzer.start(inputSequence: inputs)
            var transcript = Transcript()
            for try await result in transcriber.results {
                transcript.apply(String(result.text.characters), isFinal: result.isFinal)
                yield(transcript.text)
            }
        } onCancel: {
            microphone.stop()
            feed.finish()
            Task { await analyzer.cancelAndFinishNow() }
        }
    }
}

/// The default input device through `AVAudioEngine`, converted to the analyzer's format. macOS 27's
/// `CaptureInputSequenceProvider` would do this, but Wicket still supports macOS 26.
private final class Microphone: @unchecked Sendable {
    // Unchecked: the engine is started in `init` and only stopped after that, from whichever task
    // ends the session first; AVAudioEngine's stop and removeTap are safe to call from any thread,
    // and the lock makes the second call a no-op.
    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private var stopped = false

    init(format: AVAudioFormat, feed: AsyncStream<AnalyzerInput>.Continuation) throws {
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
            let converter = AVAudioConverter(from: inputFormat, to: format)
        else { throw VoiceError.noMicrophone }
        let conversion = Conversion(
            converter: converter, format: format, ratio: format.sampleRate / inputFormat.sampleRate)
        input.installTap(onBus: 0, bufferSize: 2048, format: inputFormat) { buffer, _ in
            if let converted = conversion.convert(buffer) { feed.yield(AnalyzerInput(buffer: converted)) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            throw error
        }
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return }
        stopped = true
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Converts the microphone's buffers on the audio thread, one at a time (the tap calls serially).
private final class Conversion: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let ratio: Double

    init(converter: AVAudioConverter, format: AVAudioFormat, ratio: Double) {
        self.converter = converter
        self.format = format
        self.ratio = ratio
    }

    func convert(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        nonisolated(unsafe) var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, inputStatus in
            if supplied {
                inputStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            inputStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0 else { return nil }
        return output
    }
}

/// Which language Wicket listens in: the first of the user's preferred languages that on-device
/// transcription supports, matched by language and region, else by language alone. SpeechTranscriber
/// takes one language per session, so a German speaker with English first gets English.
enum VoiceLanguage {
    static func locale() async -> Locale? {
        choose(preferred: Locale.preferredLanguages, supported: await SpeechTranscriber.supportedLocales)
    }

    /// The first preferred language with the same region in `supported`, else with the language's
    /// likely region (English in Germany listens in US English), else any region of it. Not
    /// `SpeechTranscriber.supportedLocale(equivalentTo:)`, which on macOS 27.2 mapped "en" to
    /// Singapore and "en-DE" to Irish English.
    static func choose(preferred: [String], supported: [Locale]) -> Locale? {
        for identifier in preferred {
            let wanted = Locale(identifier: identifier)
            guard let language = wanted.language.languageCode else { continue }
            let likely = Locale(
                identifier: Locale.Language(identifier: language.identifier).maximalIdentifier)
            let candidates = supported.filter { $0.language.languageCode == language }
            for region in [wanted.region, likely.region].compactMap(\.self) {
                if let match = candidates.first(where: { $0.region == region }) { return match }
            }
            if let any = candidates.first { return any }
        }
        return nil
    }

    /// Whether `locale`'s model still has to be downloaded. Not `AssetInventory.status`, which said
    /// `supported` for an installed model before its first use.
    static func needsDownload(_ locale: Locale) async throws -> Bool {
        try await AssetInventory.assetInstallationRequest(supporting: [transcriber(locale)]) != nil
    }

    /// Downloads the model for `locale` if it is missing, reporting progress from 0 to 1.
    static func install(_ locale: Locale, progress: @escaping @MainActor (Double) -> Void) async throws {
        guard
            let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(locale)])
        else { return }
        let watch = Task { @MainActor in
            while !Task.isCancelled {
                progress(request.progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { watch.cancel() }
        try await request.downloadAndInstall()
    }

    /// Keeps `locale`'s model reserved for Wicket while voice is on; released when it is turned off.
    static func reserve(_ locale: Locale, _ keep: Bool) async {
        if keep {
            _ = try? await AssetInventory.reserve(locale: locale)
        } else {
            await AssetInventory.release(reservedLocale: locale)
        }
    }

    private static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, preset: .progressiveTranscription)
    }
}
