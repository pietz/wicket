import Foundation

// Decoding of items and content from what extensions send (docs/extensions.md), with the host's
// stamps: the item's origin, its namespaced id and `run` actions resolved to a `CommandID`.

/// The fallback when neither the item, its command nor its extension names an icon.
private let extensionIcon = Item.Icon.symbol(name: "puzzlepiece.extension")

extension Item: Decodable {
    /// Decodes an extension's item. A missing id is the title, a missing icon the one in the
    /// decoder's `WireContext`, a missing relevance `match` (answers set their own). With an origin
    /// in the context, the item carries it and its id is namespaced by it.
    public init(from decoder: any Decoder) throws {
        let object = try decoder.object([
            "id", "title", "subtitle", "icon", "accessory", "relevance", "actions",
        ])
        title = try object.nonEmpty("title")
        let id = try object.optionalNonEmpty("id") ?? title
        origin = decoder.wire.origin
        self.id = origin.map { Item.namespaced(id, by: $0) } ?? id
        subtitle = try object.optional("subtitle")
        icon = try object.optional("icon") ?? decoder.wire.icon ?? extensionIcon
        accessory = try object.optional("accessory")
        relevance = .match
        if object.has("relevance") {
            if let mode = decoder.wire.mode, mode != .root {
                throw object.invalid("relevance", "is only for root commands; this is a \(mode) command")
            }
            let value = try object.required("relevance", as: String.self)
            guard let relevance = Relevance(rawValue: value), relevance != .exact else {
                throw object.invalid("relevance", "\"\(value)\" must be answer, match or fallback")
            }
            self.relevance = relevance
        }
        score = 0
        actions = try object.optional("actions") ?? []
    }

    /// The host id of an item `origin` sent with `id`: "ext:<extension>/<command>:<id>". Extension
    /// and command ids are slugs, so the prefix can't be forged by another extension's ids.
    static func namespaced(_ id: String, by origin: CommandID) -> String {
        switch origin.owner {
        case .builtin: "builtin:\(origin.name):\(id)"
        case .extension(let owner): "ext:\(owner)/\(origin.name):\(id)"
        }
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
    /// `reveal` and `command` are host only, so they are not among the kinds.
    public init(from decoder: any Decoder) throws {
        let (kind, object) = try decoder.oneOf(["open", "copy", "paste", "detail", "run"], what: "an action")
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
            self = .run(command: CommandID(owner: origin.owner, name: command), args: args, title: title)
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

    public init(from decoder: any Decoder) throws {
        let kinds = ["answer", "list", "detail", "close", "reload"]
        let (kind, object) = try decoder.oneOf(kinds, what: "a result")
        if decoder.wire.mode == .root, kind != "answer", kind != "list" {
            throw object.invalid(kind, "is not allowed for a root command; return answer or list")
        }
        switch kind {
        case "answer":
            var item: Item = try object.required(kind)
            if !(try object.nestedContainer(keyedBy: AnyKey.self, forKey: AnyKey(kind)).has("relevance")) {
                item.relevance = .answer
            }
            self = .answer(item)
        case "list":
            let list = try object.object(kind, ["items"])
            let items: [Item] = try list.required("items")
            if items.count > Self.itemLimit {
                throw list.invalid("items", "has \(items.count) items; the limit is \(Self.itemLimit)")
            }
            var ids = Set<String>()
            let prefix = decoder.wire.origin.map { Item.namespaced("", by: $0).count } ?? 0
            for item in items where !ids.insert(item.id).inserted {
                throw list.invalid(
                    "items",
                    "item id \"\(item.id.dropFirst(prefix))\" appears twice; ids (which default to the title) "
                        + "must be unique")
            }
            self = .list(items)
        case "detail":
            self = .detail(try object.required(kind))
        default:
            let message: String? = try object.object(kind, ["message"]).optional("message")
            self = kind == "close" ? .close(message: message) : .reload(message: message)
        }
    }
}
