import Foundation

// Decoding of items and content from what extensions send (docs/extensions.md), with
// the host's stamps: the item's origin, its namespaced id, what its subject derives and `run`
// actions resolved to a `CommandID`. What the sender may send is `ActionPolicy`'s, by its authority.

/// The fallback when neither the item, its command nor its extension names an icon.
private let extensionIcon = Item.Icon.symbol(name: "puzzlepiece.extension")

extension Item: Decodable {
    /// Decodes an extension's item. Its subject (`file` or `url`, at most one) gives
    /// what the producer leaves out: title, subtitle, icon, id, and actions after the producer's.
    /// Without one, a missing id is the title, a missing icon the one in the decoder's `WireContext`.
    /// With an origin in the context, the item carries it and its id is namespaced by it.
    public init(from decoder: any Decoder) throws {
        let object = try decoder.object([
            "id", "title", "subtitle", "icon", "accessory", "actions", "file", "url",
        ])
        let home = decoder.wire.home
        if object.has("file"), object.has("url") {
            throw object.invalid("url", "an item has one subject, file or url, not both")
        }
        let subject: Subject? = try Self.subject(object, home: home)
        self.init(
            subject: subject, id: try object.optionalNonEmpty("id"),
            title: subject == nil ? try object.nonEmpty("title") : try object.optionalNonEmpty("title"),
            subtitle: try object.optional("subtitle"), icon: try object.optional("icon"),
            accessory: try object.optional("accessory"), actions: try object.optional("actions") ?? [],
            origin: decoder.wire.origin, home: home, defaultIcon: decoder.wire.icon ?? extensionIcon)
    }

    /// The item's subject, `file` or `url`, if it names one.
    private static func subject(_ object: WireObject, home: URL) throws -> Subject? {
        if object.has("file") {
            let value = try object.nonEmpty("file")
            guard let subject = Subject.file(parsing: value, home: home) else {
                throw object.invalid("file", "\"\(value)\" must be an absolute or ~/ path, or a file: URL")
            }
            return subject
        }
        if object.has("url") {
            let value = try object.nonEmpty("url")
            guard let subject = Subject.url(parsing: value) else {
                throw object.invalid(
                    "url", "\"\(value)\" must be a URL with a scheme (https:, mailto:, ...); a file is a file"
                )
            }
            return subject
        }
        return nil
    }

    /// The host id of an item `origin` sent with `id`: "ext:<extension>/<command>:<id>". Extension
    /// and command ids are slugs, so the prefix can't be forged by another extension's ids.
    static func namespaced(_ id: String, by origin: CommandID) -> String {
        "\(origin):\(id)"
    }
}

extension Item.Icon: Decodable {
    public init(from decoder: any Decoder) throws {
        let (kind, object) = try decoder.oneOf(["symbol", "file"], what: "an icon")
        if kind == "symbol" {
            self = .symbol(name: try object.object("symbol", ["name"]).nonEmpty("name"))
        } else {
            self = .file(url: try object.object("file", ["url"]).location("url"))
        }
    }
}

extension Item.Action: Decodable {
    /// The kinds are the sender's (`ActionPolicy`): `reveal` is host only, so no one sends it. `run`
    /// can only name the sender's commands.
    public init(from decoder: any Decoder) throws {
        let kinds = ActionPolicy.actions(from: decoder.wire.authority).filter { $0 != .reveal }
        let (kind, object) = try decoder.oneOf(kinds.map(\.rawValue), what: "an action")
        switch kind {
        case "open":
            let open = try object.object(kind, ["url", "title"])
            self = .open(url: try open.location("url"), title: try open.optional("title"))
        case "copy", "paste":
            let fields = try object.object(kind, ["text", "title"])
            let text: String = try fields.required("text")
            let title: String? = try fields.optional("title")
            self = kind == "copy" ? .copy(text: text, title: title) : .paste(text: text, title: title)
        case "detail":
            self = .detail(try object.required(kind))
        default:
            let run = try object.object(kind, ["command", "args", "title"])
            let command = try run.slug("command")
            if let commands = decoder.wire.commands, !commands.contains(command) {
                throw run.invalid("command", "\"\(command)\" is not a command in wicket.json")
            }
            let args: [String: JSONValue]? = try run.optional("args")
            let title: String? = try run.optional("title")
            // The wire names a command of the sender's own extension.
            guard let origin = decoder.wire.origin, case .extension = origin.owner else {
                throw run.invalid("command", "a run action needs the extension it came from")
            }
            self = .run(
                command: CommandID(owner: origin.owner, name: command), args: args, title: title,
                revision: decoder.wire.revision)
        }
    }
}

extension Detail: Decodable {
    public init(from decoder: any Decoder) throws {
        let object = try decoder.object(["title", "markdown", "metadata", "actions"])
        self.init(
            title: try object.optional("title"), markdown: try object.required("markdown"),
            metadata: try object.optional("metadata") ?? [], actions: try object.optional("actions") ?? [])
    }
}

extension Detail.Metadata: Decodable {
    public init(from decoder: any Decoder) throws {
        let object = try decoder.object(["label", "value"])
        self.init(label: try object.required("label"), value: try object.required("value"))
    }
}

extension RunResult: Decodable {
    public static let itemLimit = 500

    /// The wire has no `show`: a screen's kind (`answer`, `list`, `detail`) is the result's. The
    /// screen is stamped with the sender's authority.
    public init(from decoder: any Decoder) throws {
        let wire = decoder.wire
        let (kind, object) = try decoder.oneOf(RunResult.Kind.allCases.map(\.rawValue), what: "a result")
        let context = ScreenContext(authority: wire.authority)
        switch kind {
        case "answer":
            var item: Item = try object.required(kind)
            item.relevance = .answer
            // Return runs the first action; an answer without any copies its title.
            if item.actions.isEmpty { item.actions = [.copy(text: item.title)] }
            self = .show(.answer(item), context)
        case "list":
            self = .show(
                .list(try Listing(object.object(kind, ["summary", "items", "sections"]), wire)),
                context)
        case "detail":
            self = .show(.detail(try object.required(kind)), context)
        default:
            let message: String? = try object.object(kind, ["message"]).optional("message")
            self = kind == "close" ? .close(message: message) : .reload(message: message)
        }
    }
}

extension Listing {
    /// A list's fields: `items` or `sections`, never both; a summary. Duplicate ids are an error.
    fileprivate init(_ list: WireObject, _ wire: WireContext) throws {
        if list.has("items") == list.has("sections") {
            throw list.invalid(
                list.has("items") ? "sections" : "items", "a list has items or sections, not both")
        }
        if list.has("items") {
            self.init(try list.required("items") as [Item])
        } else {
            self.init(sections: try list.required("sections") as [Section])
        }
        summary = try list.optionalNonEmpty("summary")
        let key = list.has("items") ? "items" : "sections"
        let count = items.count
        if count > RunResult.itemLimit {
            throw list.invalid(key, "has \(count) items; the limit is \(RunResult.itemLimit)")
        }
        var ids = Set<String>()
        for item in items where !ids.insert(item.id).inserted {
            let prefix = wire.origin.map { Item.namespaced("", by: $0).count } ?? 0
            throw list.invalid(
                key,
                "item id \"\(item.id.dropFirst(prefix))\" appears twice; ids (which default to the title, "
                    + "or a file's path or a link) must be unique")
        }
    }
}

extension Listing.Section: Decodable {
    public init(from decoder: any Decoder) throws {
        let object = try decoder.object(["title", "items"])
        self.init(title: try object.nonEmpty("title"), items: try object.required("items"))
    }
}
