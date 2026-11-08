import Foundation
import WicketCore

/// Validates JSON against the subset of JSON Schema the agent schema uses (`type`, `properties`,
/// `required`, `additionalProperties: false`, `items`, `anyOf`, `$ref`, `enum`, `const`, `pattern`,
/// `minItems`, `maxItems`), as a strict provider would, and records which properties the values
/// validated so far used, so fixtures can be checked to cover the whole schema.
struct SchemaValidator {
    let schema: JSONValue
    /// "Definition/path.to.property" for every property a valid value gave a non-null value.
    private var covered: Set<String> = []

    init(schema: JSONValue) {
        self.schema = schema
    }

    /// Where `value` breaks the schema; empty if it doesn't.
    mutating func validate(_ value: JSONValue) -> [String] {
        var used = Set<String>()
        let problems = check(value, schema, at: "#", in: ("#", ""), used: &used)
        if problems.isEmpty { covered.formUnion(used) }
        return problems
    }

    /// The properties the schema has that no valid value used.
    func uncovered() -> [String] {
        var all = Set<String>()
        func collect(_ node: JSONValue, _ definition: String, _ path: String) {
            guard case .object(let object) = node else { return }
            if case .object(let properties)? = object["properties"] {
                for (key, value) in properties {
                    let property = path.isEmpty ? key : path + "." + key
                    all.insert("\(definition)/\(property)")
                    collect(value, definition, property)
                }
            }
            if case .array(let branches)? = object["anyOf"] {
                for branch in branches { collect(branch, definition, path) }
            }
            if let items = object["items"] { collect(items, definition, path) }
        }
        collect(schema, "#", "")
        if case .object(let defs)? = schema["$defs"] {
            for (name, definition) in defs { collect(definition, name, "") }
        }
        return all.subtracting(covered).sorted()
    }

    private func check(
        _ value: JSONValue, _ node: JSONValue, at path: String, in place: (definition: String, path: String),
        used: inout Set<String>
    ) -> [String] {
        guard case .object(let rule) = node else { return ["\(path): schema node isn't an object"] }
        if case .string(let ref)? = rule["$ref"] {
            let name = String(ref.dropFirst("#/$defs/".count))
            guard let definition = schema["$defs"]?[name] else { return ["\(path): \(ref) unresolved"] }
            return check(value, definition, at: path, in: (name, ""), used: &used)
        }
        if case .array(let branches)? = rule["anyOf"] {
            for branch in branches {
                var branchUsed = Set<String>()
                if check(value, branch, at: path, in: place, used: &branchUsed).isEmpty {
                    used.formUnion(branchUsed)
                    return []
                }
            }
            return ["\(path): matches no branch"]
        }
        if let type = rule["type"], !Self.matches(value, type) { return ["\(path): not \(type.json)"] }
        if case .array(let options)? = rule["enum"], !options.contains(value) {
            return ["\(path): not in enum"]
        }
        if let constant = rule["const"], constant != value { return ["\(path): not \(constant.json)"] }
        if case .string(let pattern)? = rule["pattern"], case .string(let string) = value,
            string.range(of: pattern, options: .regularExpression) == nil
        {
            return ["\(path): doesn't match \(pattern)"]
        }
        var problems: [String] = []
        if case .array(let array) = value {
            if case .integer(let min)? = rule["minItems"], array.count < min {
                problems.append("\(path): too few")
            }
            if case .integer(let max)? = rule["maxItems"], array.count > max {
                problems.append("\(path): too many")
            }
            if let items = rule["items"] {
                for (index, element) in array.enumerated() {
                    problems += check(element, items, at: "\(path)[\(index)]", in: place, used: &used)
                }
            }
        }
        if case .object(let object) = value, case .object(let properties)? = rule["properties"] {
            if case .array(let required)? = rule["required"] {
                for case .string(let key) in required where object[key] == nil {
                    problems.append("\(path): no \(key)")
                }
            }
            for (key, element) in object {
                guard let property = properties[key] else {
                    if rule["additionalProperties"] == false { problems.append("\(path): unknown \(key)") }
                    continue
                }
                let inner = place.path.isEmpty ? key : place.path + "." + key
                if element != .null { used.insert("\(place.definition)/\(inner)") }
                problems += check(
                    element, property, at: "\(path).\(key)", in: (place.definition, inner), used: &used)
            }
        }
        return problems
    }

    private static func matches(_ value: JSONValue, _ type: JSONValue) -> Bool {
        switch type {
        case .array(let types): return types.contains { matches(value, $0) }
        case .string(let name):
            switch (name, value) {
            case ("object", .object), ("array", .array), ("string", .string), ("boolean", .bool),
                ("null", .null),
                ("integer", .integer), ("number", .integer), ("number", .number):
                return true
            default: return false
            }
        default: return false
        }
    }
}
