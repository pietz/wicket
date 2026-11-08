import Foundation
import FoundationModels
import Testing
import WicketCore

@testable import WicketHost

@Suite struct AppleModelTests {
    @Test(arguments: [
        (SystemLanguageModel.Availability.available, nil as String?),
        (
            .unavailable(.appleIntelligenceNotEnabled),
            "Enable Apple Intelligence in System Settings ▸ Apple Intelligence & Siri."
        ),
        (.unavailable(.deviceNotEligible), "This Mac is not eligible for Apple Intelligence."),
        (
            .unavailable(.modelNotReady),
            "The on-device model is not ready. Check Apple Intelligence & Siri in System Settings."
        ),
    ])
    func mapsAvailability(availability: SystemLanguageModel.Availability, reason: String?) {
        let status = AppleModel.status(for: availability)
        #expect(status.provider == .apple)
        #expect(status.state == reason.map { .unavailable($0) } ?? .ready)
        #expect(status.version == nil)
        #expect(status.warning == nil)
        if let reason { #expect(status.description.contains(reason)) }
    }

    @Test func systemStatusNeedsNoCLI() async {
        #expect(await Agent.locate(.apple) == nil)
        #expect(await Agent.status(of: .apple) == AppleModel.status())
        #expect(AgentProvider.apple.loginCommand == nil)
        #expect(AgentProvider.apple.testedVersion == nil)
    }

    @Test(
        .enabled(
            if: ProcessInfo.processInfo.environment["WICKET_TEST_APPLE_MODEL"] == "1"
                && SystemLanguageModel.default.isAvailable))
    func liveAnswerStreamsAndCompletes() async {
        let request = AgentRequest(
            prompt: "Reply with a short greeting.", workingDirectory: FileManager.default.temporaryDirectory,
            mode: .answer)
        let run = await AgentBackend.installed.run(.apple, request)
        var received: [AgentEvent] = []
        for await event in run { received.append(event) }
        guard case .answer(let answer, usage: nil)? = received.last else {
            Issue.record("The live model did not finish with an answer.")
            return
        }
        #expect(!answer.isEmpty)
        #expect(text(received) == answer)
        #expect(await run.ended == .notRunning)
    }
}
