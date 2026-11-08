import Foundation
import FoundationModels
import WicketCore

/// Apple's text-only model shares the CLI providers' events, draft rendering and cancellation.
enum AppleModel {
    static func status(
        for availability: SystemLanguageModel.Availability = SystemLanguageModel.default.availability
    ) -> AgentStatus {
        let state: AgentStatus.State
        switch availability {
        case .available:
            state = .ready
        case .unavailable(let reason):
            let message =
                switch reason {
                case .appleIntelligenceNotEnabled:
                    "Enable Apple Intelligence in System Settings ▸ Apple Intelligence & Siri."
                case .deviceNotEligible:
                    "This Mac is not eligible for Apple Intelligence."
                case .modelNotReady:
                    "The on-device model is not ready. Check Apple Intelligence & Siri in System Settings."
                @unknown default:
                    "The on-device model is unavailable. Check Apple Intelligence & Siri in System Settings."
                }
            state = .unavailable(message)
        }
        return AgentStatus(provider: .apple, state: state)
    }

    static func run(_ request: AgentRequest) -> AgentRun {
        AgentRun { output in
            guard !Task.isCancelled else { return .notRunning }
            let status = status()
            guard status.state == .ready else {
                output.yield(.error(status.description))
                return .notRunning
            }
            do {
                let session = LanguageModelSession(
                    instructions: "Answer briefly and directly. Use Markdown when helpful.")
                // Never prewarm at launch or when the status pane opens.
                session.prewarm()
                var text = ""
                for try await snapshot in session.streamResponse(to: request.prompt) {
                    try Task.checkCancellation()
                    // Foundation Models yields cumulative snapshots; AgentEvent carries deltas.
                    let delta = String(snapshot.content.dropFirst(text.count))
                    text = snapshot.content
                    if !delta.isEmpty { output.yield(.text(delta)) }
                }
                try Task.checkCancellation()
                output.yield(.answer(text, usage: nil))
            } catch {
                if !Task.isCancelled { output.yield(.error(error.localizedDescription)) }
            }
            return .notRunning
        }
    }
}
