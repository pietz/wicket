import Foundation

// Strict decoding of what extensions and agents send (docs/extensions.md, AgentOutput.swift). Unknown fields are rejected and
// every rule failure is a `DecodingError` with the path to the offending value, so `describe`
// can tell an agent exactly what to fix.

/// What the host knows while decoding a response: the rules that depend on the command.
public struct WireContext: Sendable {
    /// The mode of the command the response answers; nil skips the mode rules.
    public var mode: Manifest.Command.Mode?
    /// The icon items inherit: the command's, else the extension's.
    public var icon: Item.Icon?
    /// The extension's command ids, which `run` actions must name; nil skips the check.
    public var commands: Set<String>?
    /// The command the response answers: stamped on its items, namespacing their ids, and the
    /// extension `run` actions resolve against. Nil decodes items as sent and rejects `run`.
    public var origin: CommandID?
    /// Who sent the response, which decides the results and actions it may hold (`ActionPolicy`);
    /// an extension's revision is stamped on its `run` actions.
    public var authority: Authority
    /// Where `~/` paths lead.
    public var home = FileManager.default.homeDirectoryForCurrentUser

    public init(
        mode: Manifest.Command.Mode? = nil, icon: Item.Icon? = nil, commands: Set<String>? = nil,
        origin: CommandID? = nil, revision: ExtensionRevision? = nil
    ) {
        self.mode = mode
        self.icon = icon
        self.commands = commands
        self.origin = origin
        authority = .extension(revision)
    }

    /// An agent's reply, its items stamped with `origin`.
    public static func agent(origin: CommandID) -> WireContext {
        var context = WireContext(origin: origin)
        context.authority = .agent
        return context
    }

    var revision: ExtensionRevision? {
        if case .extension(let revision) = authority { revision } else { nil }
    }

    public init(command id: String, in manifest: Manifest, revision: ExtensionRevision? = nil) {
        let command = manifest.command(id)
        self.init(
            mode: command?.mode, icon: command?.icon ?? manifest.icon,
            commands: Set(manifest.commands.map(\.id)), origin: .extension(manifest.id, id),
            revision: revision)
    }

    static let key = CodingUserInfoKey(rawValue: "app.wicket.wire")!
}

/// A coding key for any string, so a decoder can see every key an object holds.
struct AnyKey: CodingKey, Hashable {
    let stringValue: String
    let intValue: Int?

    init(_ string: String) {
        stringValue = string
        intValue = nil
    }

    init?(stringValue: String) { self.init(stringValue) }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

typealias WireObject = KeyedDecodingContainer<AnyKey>

extension Decoder {
    var wire: WireContext { userInfo[WireContext.key] as? WireContext ?? WireContext() }

    /// This value as an object holding only `allowed` keys.
    func object(_ allowed: Set<String>) throws -> WireObject {
        let object = try container(keyedBy: AnyKey.self)
        try object.rejectUnknownKeys(allowed)
        return object
    }

    /// For objects with exactly one key that says what they are, such as actions and results.
    func oneOf(_ kinds: [String], what: String) throws -> (String, WireObject) {
        let object = try container(keyedBy: AnyKey.self)
        let keys = object.allKeys.map(\.stringValue)
        guard keys.count == 1, let kind = keys.first, kinds.contains(kind) else {
            let found = keys.isEmpty ? "none" : keys.sorted().joined(separator: ", ")
            throw invalid(
                "\(what) must have exactly one key, one of \(kinds.joined(separator: ", ")); found \(found)")
        }
        return (kind, object)
    }

    func invalid(_ message: String) -> DecodingError {
        .dataCorrupted(.init(codingPath: codingPath, debugDescription: message))
    }
}

extension KeyedDecodingContainer where Key == AnyKey {
    func rejectUnknownKeys(_ allowed: Set<String>) throws {
        for key in allKeys where !allowed.contains(key.stringValue) {
            throw DecodingError.dataCorruptedError(
                forKey: key, in: self,
                debugDescription:
                    "unknown field \"\(key.stringValue)\"; allowed: \(allowed.sorted().joined(separator: ", "))"
            )
        }
    }

    func has(_ key: String) -> Bool { contains(AnyKey(key)) }

    func required<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T {
        try decode(T.self, forKey: AnyKey(key))
    }

    func optional<T: Decodable>(_ key: String, as type: T.Type = T.self) throws -> T? {
        try decodeIfPresent(T.self, forKey: AnyKey(key))
    }

    func nonEmpty(_ key: String) throws -> String {
        let value = try required(key, as: String.self)
        if value.isEmpty { throw invalid(key, "must not be empty") }
        return value
    }

    func optionalNonEmpty(_ key: String) throws -> String? {
        has(key) ? try nonEmpty(key) : nil
    }

    func slug(_ key: String) throws -> String {
        let value = try required(key, as: String.self)
        guard Manifest.isSlug(value) else {
            throw invalid(
                key,
                "\"\(value)\" is not a valid id: use lowercase letters, digits and single hyphens, "
                    + "at most 64 characters")
        }
        return value
    }

    /// A nested object holding only `allowed` keys.
    func object(_ key: String, _ allowed: Set<String>) throws -> WireObject {
        let object = try nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(key))
        try object.rejectUnknownKeys(allowed)
        return object
    }

    /// A URL, or an absolute or `~/` path as a file URL.
    func location(_ key: String) throws -> URL {
        let value = try nonEmpty(key)
        if value.hasPrefix("/") { return URL(filePath: value) }
        if value.hasPrefix("~/") {
            return FileManager.default.homeDirectoryForCurrentUser.appending(path: String(value.dropFirst(2)))
        }
        if let url = URL(string: value), let scheme = url.scheme, !scheme.isEmpty { return url }
        throw invalid(
            key, "\"\(value)\" must be a URL with a scheme (https:, file:, ...) or an absolute or ~/ path")
    }

    func invalid(_ key: String, _ message: String) -> DecodingError {
        .dataCorruptedError(forKey: AnyKey(key), in: self, debugDescription: message)
    }
}

extension DecodingError {
    /// One line naming where the problem is and what it is, such as
    /// `result.list.items[2].actions[0]: unknown field "titel"; allowed: text, title`.
    public var summary: String {
        switch self {
        case .keyNotFound(let key, let context):
            return "\(Self.path(context.codingPath + [key])): missing required field \"\(key.stringValue)\""
        case .typeMismatch(_, let context), .valueNotFound(_, let context):
            return "\(Self.path(context.codingPath)): \(context.debugDescription)"
        case .dataCorrupted(let context):
            if context.underlyingError != nil { return "not valid JSON" }
            return "\(Self.path(context.codingPath)): \(context.debugDescription)"
        @unknown default:
            return String(describing: self)
        }
    }

    static func path(_ keys: [any CodingKey]) -> String {
        var path = ""
        for key in keys {
            if let index = key.intValue {
                path += "[\(index)]"
            } else {
                path += (path.isEmpty ? "" : ".") + key.stringValue
            }
        }
        return path.isEmpty ? "(top level)" : path
    }
}
