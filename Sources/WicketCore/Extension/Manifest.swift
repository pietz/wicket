import Foundation

/// An extension's `wicket.json`, with every rule of docs/extensions.md checked while decoding.
public struct Manifest: Sendable, Hashable, Decodable {
    public enum Capability: String, Sendable, Hashable, CaseIterable {
        case network, clipboard, files, shell
    }

    /// A value the user stores in the Keychain; the extension receives it as an environment variable.
    public struct Secret: Sendable, Hashable, Decodable {
        public var name: String
        public var title: String

        public init(from decoder: any Decoder) throws {
            let object = try decoder.object(["name", "title"])
            name = try object.required("name")
            title = try object.nonEmpty("title")
            guard Self.isName(name) else {
                throw object.invalid(
                    "name",
                    "\"\(name)\" must be an environment variable name: uppercase letters, digits and _")
            }
            guard !name.hasPrefix("WICKET_"), !Self.reserved.contains(name) else {
                throw object.invalid("name", "\"\(name)\" is reserved for Wicket's own environment variables")
            }
        }

        private static let reserved: Set = ["PATH", "LANG", "HOME", "USER", "SHELL", "TMPDIR"]

        private static func isName(_ name: String) -> Bool {
            guard let first = name.unicodeScalars.first, first != "_" || name.count > 1 else { return false }
            return !("0"..."9").contains(first)
                && name.unicodeScalars.allSatisfy {
                    ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_"
                }
        }
    }

    public struct Command: Sendable, Hashable, Decodable {
        public enum Mode: String, Sendable, Hashable, CaseIterable {
            /// Runs on Return; a returned list is filtered locally.
            case once
            /// Opens a view that asks the extension on every change of the text.
            case live
        }

        public var id: String
        public var title: String
        public var subtitle: String?
        public var icon: Item.Icon?
        public var mode: Mode
        public var keyword: String?
        /// Words and phrases people would type to find this command, matched locally.
        public var search: [String]
        public var placeholder: String?
        public var hidden: Bool

        public init(from decoder: any Decoder) throws {
            let object = try decoder.object([
                "id", "title", "subtitle", "icon", "mode", "keyword", "placeholder", "hidden", "search",
            ])
            id = try object.slug("id")
            title = try object.nonEmpty("title")
            subtitle = try object.optional("subtitle")
            icon = try object.optional("icon")
            let mode = try object.optional("mode", as: String.self) ?? "once"
            guard let parsed = Mode(rawValue: mode) else {
                throw object.invalid("mode", "\"\(mode)\" must be once or live")
            }
            self.mode = parsed
            keyword = try object.optional("keyword")
            search = object.has("search") ? try object.required("search") : []
            guard search.count <= 16 else {
                throw object.invalid("search", "must contain at most 16 search terms")
            }
            guard
                search.allSatisfy({
                    !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        && $0.unicodeScalars.count <= 128
                })
            else {
                throw object.invalid(
                    "search", "each search term must contain non-whitespace text and at most 128 characters")
            }
            placeholder = try object.optional("placeholder")
            hidden = try object.optional("hidden") ?? false
            if let keyword, keyword.isEmpty || keyword.contains(where: \.isWhitespace) {
                throw object.invalid("keyword", "\"\(keyword)\" must be one word without spaces")
            }
        }
    }

    public static let protocolVersion = 2
    public static let fileName = "wicket.json"

    public var id: String
    public var name: String
    public var description: String?
    public var version: String
    public var icon: Item.Icon?
    /// Program and arguments, started in the extension's folder.
    public var run: [String]
    public var capabilities: [Capability]
    public var secrets: [Secret]
    public var commands: [Command]

    public func command(_ id: String) -> Command? { commands.first { $0.id == id } }

    public init(from decoder: any Decoder) throws {
        let object = try decoder.object([
            "$schema", "protocol", "id", "name", "description", "version", "icon", "run", "capabilities",
            "secrets", "commands",
        ])
        let version: Int = try object.required("protocol")
        guard version == Self.protocolVersion else {
            throw object.invalid(
                "protocol", "is \(version); this Wicket speaks protocol \(Self.protocolVersion)")
        }
        id = try object.slug("id")
        name = try object.nonEmpty("name")
        description = try object.optional("description")
        self.version = try object.required("version")
        let parts = self.version.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3,
            parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) })
        else { throw object.invalid("version", "\"\(self.version)\" must be major.minor.patch, like 1.0.0") }
        icon = try object.optional("icon")
        run = try object.required("run")
        if run.isEmpty || run.contains(where: \.isEmpty) {
            throw object.invalid("run", "must name a program and its arguments, none of them empty")
        }
        let program = run[0].split(separator: "/").last.map(String.init) ?? run[0]
        if program == "uv" || program == "uvx" {
            throw object.invalid(
                "run",
                "Wicket runs only what is in the folder, so it doesn't run uv, which installs packages outside it; vendor Python packages into the folder instead (pip install --target vendor <package>) and run python3"
            )
        }
        let capabilities = try object.optional("capabilities", as: [String].self) ?? []
        self.capabilities = try capabilities.map { name in
            guard let capability = Capability(rawValue: name) else {
                throw object.invalid("capabilities", "\"\(name)\" must be network, clipboard, files or shell")
            }
            return capability
        }
        if Set(capabilities).count != capabilities.count {
            throw object.invalid("capabilities", "lists a capability twice")
        }
        secrets = try object.optional("secrets") ?? []
        if let name = Self.firstDuplicate(secrets.map(\.name)) {
            throw object.invalid("secrets", "declares \"\(name)\" twice")
        }
        commands = try object.required("commands")
        if commands.isEmpty { throw object.invalid("commands", "must hold at least one command") }
        if let id = Self.firstDuplicate(commands.map(\.id)) {
            throw object.invalid("commands", "has two commands with the id \"\(id)\"")
        }
    }

    /// Reads and validates `wicket.json` in `folder`.
    public static func load(from folder: URL) throws(ManifestError) -> Manifest {
        let url = folder.appending(path: fileName)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw ManifestError(description: "\(fileName) not found in \(folder.path)")
        }
        do {
            return try JSONDecoder().decode(Manifest.self, from: data)
        } catch let error as DecodingError {
            throw ManifestError(description: "\(fileName): \(error.summary)")
        } catch {
            throw ManifestError(description: "\(fileName): \(error.localizedDescription)")
        }
    }

    /// Lowercase letters, digits and single hyphens, at most 64 characters.
    public static func isSlug(_ value: String) -> Bool {
        value.count <= 64
            && value.split(separator: "-", omittingEmptySubsequences: false).allSatisfy { part in
                !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLowercase || $0.isNumber) }
            }
    }

    private static func firstDuplicate(_ values: [String]) -> String? {
        var seen = Set<String>()
        return values.first { !seen.insert($0).inserted }
    }
}

public struct ManifestError: Error, Sendable, Equatable, CustomStringConvertible {
    public let description: String
}
