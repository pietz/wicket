import Foundation

/// A global keyboard shortcut spelled like `"ctrl+option+space"`: lowercase modifiers in any order
/// (`cmd`, `ctrl`, `option` or its aliases `opt` and `alt`, `shift`) joined by `+`, then one key.
public struct Shortcut: Hashable, Sendable, CustomStringConvertible {
    public struct Modifiers: OptionSet, Hashable, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        // Carbon's modifier flags (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`), so `rawValue`
        // can go straight to `RegisterEventHotKey`.
        public static let command = Modifiers(rawValue: 0x100)
        public static let shift = Modifiers(rawValue: 0x200)
        public static let option = Modifiers(rawValue: 0x800)
        public static let control = Modifiers(rawValue: 0x1000)
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case unknown(String)
        case missingKey
        case multipleKeys(String, String)

        public var description: String {
            switch self {
            case .unknown(let token): "unknown key or modifier \"\(token)\""
            case .missingKey: "no key, only modifiers"
            case .multipleKeys(let a, let b): "more than one key (\"\(a)\" and \"\(b)\")"
            }
        }
    }

    public static let `default` = Shortcut(key: "space", modifiers: .option)

    /// Canonical key name, a key of `keyCodes`.
    public let key: String
    public let modifiers: Modifiers

    /// Carbon virtual key code (`kVK_*`) of `key`.
    public var keyCode: Int { Self.keyCodes[key]! }

    private init(key: String, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }

    public init(_ spelling: String) throws(ParseError) {
        var modifiers: Modifiers = []
        var key: String?
        for token in spelling.lowercased().split(separator: "+", omittingEmptySubsequences: false) {
            let token = token.trimmingCharacters(in: .whitespaces)
            if let modifier = Self.modifierNames[token] {
                modifiers.insert(modifier)
            } else if Self.keyCodes[token] != nil {
                if let key { throw .multipleKeys(key, token) }
                key = token
            } else {
                throw .unknown(token)
            }
        }
        guard let key else { throw .missingKey }
        self.init(key: key, modifiers: modifiers)
    }

    /// A shortcut recorded from a key press, or nil if it can't be a global hotkey: an unknown key, or
    /// no Command, Control or Option (Shift alone would take over typing), except for F-keys.
    public init?(keyCode: Int, modifiers: Modifiers) {
        guard let key = Self.keyCodes.first(where: { $0.value == keyCode })?.key else { return nil }
        self.init(key: key, modifiers: modifiers)
        guard leavesTypingAlone else { return nil }
    }

    /// Whether it can be a global hotkey without taking over typing: it has Command, Control or
    /// Option (Shift alone would swallow capitals), or it is an F-key.
    public var leavesTypingAlone: Bool {
        let isFunctionKey = key.count > 1 && key.hasPrefix("f")
        return isFunctionKey || !modifiers.isDisjoint(with: [.command, .control, .option])
    }

    /// How macOS menus show it, such as "⌃⌥Space".
    public var symbols: String {
        let names: [(Modifiers, String)] = [(.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
        let keyName =
            switch key {
            case "return": "↩"
            case "tab": "⇥"
            case "escape": "⎋"
            case "space": "Space"
            default: key.uppercased()
            }
        return names.filter { modifiers.contains($0.0) }.map(\.1).joined() + keyName
    }

    public var description: String {
        let names: [(Modifiers, String)] = [
            (.control, "ctrl"), (.option, "option"), (.shift, "shift"), (.command, "cmd"),
        ]
        return (names.filter { modifiers.contains($0.0) }.map(\.1) + [key]).joined(separator: "+")
    }

    static let modifierNames: [String: Modifiers] = [
        "cmd": .command, "command": .command, "ctrl": .control, "control": .control,
        "option": .option, "opt": .option, "alt": .option, "shift": .shift,
    ]

    /// Carbon virtual key codes (`kVK_*` in HIToolbox's Events.h). Letters, digits and punctuation
    /// are physical positions on an ANSI keyboard, which is what `RegisterEventHotKey` matches.
    static let keyCodes: [String: Int] = [
        "a": 0x00, "s": 0x01, "d": 0x02, "f": 0x03, "h": 0x04, "g": 0x05, "z": 0x06, "x": 0x07,
        "c": 0x08, "v": 0x09, "b": 0x0B, "q": 0x0C, "w": 0x0D, "e": 0x0E, "r": 0x0F, "y": 0x10,
        "t": 0x11, "o": 0x1F, "u": 0x20, "i": 0x22, "p": 0x23, "l": 0x25, "j": 0x26, "k": 0x28,
        "n": 0x2D, "m": 0x2E,
        "1": 0x12, "2": 0x13, "3": 0x14, "4": 0x15, "6": 0x16, "5": 0x17, "9": 0x19, "7": 0x1A,
        "8": 0x1C, "0": 0x1D,
        "=": 0x18, "-": 0x1B, "]": 0x1E, "[": 0x21, "'": 0x27, ";": 0x29, "\\": 0x2A, ",": 0x2B,
        "/": 0x2C, ".": 0x2F, "`": 0x32,
        "return": 0x24, "tab": 0x30, "space": 0x31, "escape": 0x35,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62,
        "f8": 0x64, "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "f13": 0x69, "f14": 0x6B,
        "f15": 0x71, "f16": 0x6A, "f17": 0x40, "f18": 0x4F, "f19": 0x50, "f20": 0x5A,
    ]
}

extension Shortcut: Codable {
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let spelling = try container.decode(String.self)
        do {
            try self.init(spelling)
        } catch {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "\"\(spelling)\": \(error)")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(description)
    }
}
