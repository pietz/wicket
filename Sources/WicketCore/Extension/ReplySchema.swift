import Foundation

/// The provider schema for a reply, projected from the extension schema (docs/extension.schema.json,
/// JSON Schema 2020-12), so agents and extensions share one vocabulary. One projection serves Codex's
/// `outputSchema` (OpenAI strict mode) and Claude Code's `--json-schema` (draft-07, validated by the
/// CLI): their common subset, as the structured-output spike found it. The committed copy is
/// docs/agent-reply.schema.json, which a test regenerates.
public enum ReplySchema {
    /// Who the schema is for.
    public enum Profile: Sendable {
        /// An agent's reply: the screens and actions `ActionPolicy` allows `.agent`.
        case agent

        var authority: Authority { .agent }
    }

    public enum Failure: Error, Equatable {
        /// The source has no such definition, or not of the shape the projection reads.
        case missing(String)
    }

    /// The schema for `profile`'s replies, from `source`, the extension schema:
    ///
    /// - The root is the wire shape, an object `{"reply": Screen}`. `Screen` is the source's `Result`
    ///   with only the profile's screens, `Action` only its actions; definitions stay definitions
    ///   (`$defs`, `$ref`), so Detail → Action → Detail ends by reference. Only the definitions the
    ///   root reaches are kept, and the profile's omitted fields are left out (an agent's items have
    ///   no `id`, `icon` or `relevance`: its subjects give those).
    /// - Every object lists every property as required, an optional one as `anyOf [T, null]`
    ///   (`AgentOutput.normalize` drops the nulls), and has `additionalProperties: false`.
    /// - Alternatives are `anyOf` (each branch an object with its own one key, so they're disjoint).
    ///   Constraints on an object as a whole (`anyOf` of required keys, `not`, `if`) are dropped: the
    ///   decoder enforces them.
    /// - Only `type`, `enum`, `const`, `pattern`, `minItems`, `maxItems` and `description` are kept
    ///   from a value's keywords; there is no `$schema`, since each side reads its own dialect.
    public static func project(_ source: JSONValue, for profile: Profile) throws -> JSONValue {
        guard case .object(let defs)? = source["$defs"] else { throw Failure.missing("$defs") }
        var projection = Projection(defs: defs, profile: profile)
        try projection.visit("Screen")
        return .object([
            "type": "object",
            "properties": ["reply": ["$ref": "#/$defs/Screen"]],
            "required": ["reply"],
            "additionalProperties": false,
            "$defs": .object(projection.projected),
        ])
    }

    private struct Projection {
        let defs: [String: JSONValue]
        let profile: Profile
        var projected: [String: JSONValue] = [:]
        private var queue: [String] = []

        init(defs: [String: JSONValue], profile: Profile) {
            self.defs = defs
            self.profile = profile
        }

        /// Projects `name` and every definition it reaches.
        mutating func visit(_ name: String) throws {
            queue = [name]
            while let name = queue.popLast() {
                guard projected[name] == nil else { continue }
                let source = name == "Screen" ? "Result" : name
                guard let definition = defs[source] else { throw Failure.missing(source) }
                projected[name] = .null  // reached: a reference back to it doesn't queue it again
                projected[name] = node(definition, in: name)
            }
        }

        /// The screens and actions the profile keeps, as the source's branches name them.
        private func keeps(_ branch: JSONValue, of definition: String) -> Bool {
            switch definition {
            case "Screen":
                let screens = ActionPolicy.screens(from: profile.authority).map(\.rawValue)
                guard case .array(let required)? = branch["required"], case .string(let key)? = required.first
                else { return false }
                return screens.contains(key)
            case "Action":
                let actions = ActionPolicy.actions(from: profile.authority).map {
                    $0.rawValue.capitalized + "Action"
                }
                guard case .string(let ref)? = branch["$ref"] else { return false }
                return actions.contains { ref == "#/$defs/" + $0 }
            default:
                return true
            }
        }

        /// The fields the profile leaves out of a definition.
        private func omitted(in definition: String?) -> Set<String> {
            definition == "Item" ? ["id", "icon", "relevance"] : []
        }

        /// One schema node projected; `definition` names the definition it is the root of, if any.
        private mutating func node(_ value: JSONValue, in definition: String? = nil) -> JSONValue {
            guard case .object(let schema) = value else { return value }
            if case .string(let ref)? = schema["$ref"] {
                queue.append(String(ref.dropFirst("#/$defs/".count)))
                return ["$ref": .string(ref)]
            }
            var out: [String: JSONValue] = [:]
            if let description = schema["description"] { out["description"] = description }
            if case .object(let properties)? = schema["properties"] {
                let required = Set(schema["required"].flatMap(\.strings) ?? [])
                let kept = properties.filter { !omitted(in: definition).contains($0.key) }
                var projected: [String: JSONValue] = [:]
                for (key, property) in kept {
                    let property = node(property)
                    projected[key] =
                        required.contains(key) ? property : ["anyOf": [property, ["type": "null"]]]
                }
                out["type"] = "object"
                out["properties"] = .object(projected)
                out["required"] = .array(kept.keys.sorted().map(JSONValue.string))
                out["additionalProperties"] = false
                return .object(out)
            }
            if case .array(let branches)? = schema["oneOf"] ?? schema["anyOf"] {
                out["anyOf"] = .array(branches.filter { keeps($0, of: definition ?? "") }.map { node($0) })
                return .object(out)
            }
            for key in ["type", "enum", "const", "pattern", "minItems", "maxItems"] {
                if let keyword = schema[key] { out[key] = keyword }
            }
            if let items = schema["items"] { out["items"] = node(items) }
            return .object(out)
        }
    }
}

extension JSONValue {
    /// An array of strings' values; nil for anything else.
    fileprivate var strings: [String]? {
        guard case .array(let array) = self else { return nil }
        return array.compactMap { if case .string(let string) = $0 { string } else { nil } }
    }
}
