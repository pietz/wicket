import Foundation

/// An agent's reply: the screen it sends through its harness's structured output (Codex
/// `outputSchema`, Claude Code `--json-schema`), shaped by `ReplySchema.project(_:for: .agent)` as
/// `{"reply": {"list": …}}`, the extension wire's result wrapped in one key.
public enum AgentOutput {
    /// Decodes an agent's structured output into the screen it shows: nulls normalized away, then
    /// the extension wire's strict decoder under agent authority (`ActionPolicy`: answer, list or
    /// detail; open, copy and detail actions at any depth), its items stamped with `origin`. An
    /// error is a `DecodingError` whose `summary` names the path.
    public static func decode(_ output: JSONValue, origin: CommandID) throws -> Screen {
        let decoder = JSONDecoder()
        decoder.userInfo[WireContext.key] = WireContext.agent(origin: origin)
        return try decoder.decode(Envelope.self, from: JSONEncoder().encode(normalize(output))).screen
    }

    /// `value` without null-valued keys, at any depth. A strict provider schema makes every key
    /// required and an optional one nullable, while the wire decoder treats a key that is there as
    /// sent (an empty title is an error, not a missing one), so absent is how null reaches it.
    public static func normalize(_ value: JSONValue) -> JSONValue {
        switch value {
        case .object(let object): .object(object.filter { $0.value != .null }.mapValues(normalize))
        case .array(let array): .array(array.map(normalize))
        default: value
        }
    }

    private struct Envelope: Decodable {
        var screen: Screen

        init(from decoder: any Decoder) throws {
            let object = try decoder.object(["reply"])
            guard case .show(let screen, _) = try object.required("reply", as: RunResult.self) else {
                throw object.invalid("reply", "must be a screen")
            }
            self.screen = screen
        }
    }
}
