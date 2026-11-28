import Foundation

/// The same request and view are serializable at the process boundary. Scheduling (name,
/// pattern or fallback) belongs to the host, not the provider or its rows.
struct ProviderRequest: Codable, Sendable, Equatable {
  let input: String
  /// Named values: those the user filled into declared fields and those a run action set.
  let fields: [String: String]
  /// The name of this activation, absent on a rerun.
  let action: String?
  /// True only on the one request the user's activation caused; reruns, refreshes and links never are.
  let submitted: Bool
  /// The user's number format, so an extension reads and writes numbers as the user does without a
  /// locale library of its own (the calculator links no Foundation, which costs 10 ms per process).
  let locale: NumberMarks
  /// An extension's settings from config.json over their manifest defaults (`ExtensionHost.view`).
  var settings: [String: JSONValue] = [:]
  /// True for a root pattern run. Omitted from other requests.
  var rootMatch: Bool?
  struct NumberMarks: Codable, Sendable, Equatable {
    var decimal: String
    /// Empty where the user's numbers have no grouping.
    var grouping: String
    // Strings, like every other locale value, so an extension that decodes `locale` as a string map keeps working.
    var groupingSize: String? = "3"
    var secondaryGroupingSize: String? = "3"

    static var current: Self { localized(.autoupdatingCurrent) }

    static func localized(_ locale: Locale) -> Self {
      // FormatStyle does not expose the locale’s two grouping sizes.
      let formatter = NumberFormatter()
      formatter.locale = locale
      formatter.numberStyle = .decimal
      let primary = formatter.groupingSize
      let secondary = formatter.secondaryGroupingSize
      // en_US_POSIX reports a "," separator while grouping is off.
      let grouping = formatter.usesGroupingSeparator ? locale.groupingSeparator ?? "" : ""
      return Self(
        decimal: locale.decimalSeparator ?? ".", grouping: grouping,
        groupingSize: String(primary), secondaryGroupingSize: String(secondary > 0 ? secondary : primary))
    }
  }
  init(
    input: String, fields: [String: String] = [:], action: String? = nil, submitted: Bool = false,
    locale: NumberMarks = .current
  ) {
    self.input = input
    self.fields = fields
    self.action = submitted ? action : nil
    self.submitted = submitted
    self.locale = locale
  }
}

/// One view with optional parts: Markdown `body` (the answer page), `items` (a native list alone, rows
/// after the body on a page) and `actions` for the header. At least one of body and items is present on
/// the wire, unless the view consists of page fields.
struct ProviderView: Codable, Sendable, Equatable {
  var title: String?
  var body: String?
  var items: [Row]
  var actions: [RowAction]
  /// Escape from this page reruns the same command with these field overrides.
  var back: [String: String]?
  let fields: [Field]?
  func pageControls(reservedFields: [Field] = []) -> [Page.Control] {
    guard let fields, !fields.isEmpty else { return [] }
    let reserved = Set(reservedFields.map(\.name))
    let declarations = Dictionary(grouping: fields, by: \.name)
    return fields.compactMap { field in
      guard declarations[field.name]?.count == 1, !reserved.contains(field.name) else { return nil }
      return Page.Control(field)
    }
  }
  func pageBody(reservedFields: [Field] = []) -> String? {
    body ?? (pageControls(reservedFields: reservedFields).isEmpty ? nil : "")
  }

  init(
    body: String? = nil, items: [Row] = [], actions: [RowAction] = [], back: [String: String]? = nil,
    fields: [Field]? = nil, title: String? = nil
  ) {
    self.title = title
    self.body = body
    self.fields = fields
    self.items = items
    self.actions = actions
    self.back = back
  }

  /// A submitted command can hand off directly to the native editor.
  func saveAction(reservedFields: [Field] = []) -> RowAction? {
    guard pageBody(reservedFields: reservedFields) == nil, items.isEmpty, actions.count == 1,
      let action = actions.first, case .save = action.kind
    else { return nil }
    return action
  }

  /// A JSON object without a body, items or fields: nothing to show, which only a hidden run may answer
  /// (`Address.hidden`).
  struct Empty: Error {}
  private struct FieldEntry: Decodable {
    let name: String?
    let field: Field?
    private enum NameKey: String, CodingKey { case name }
    init(from decoder: any Decoder) throws {
      name = try? decoder.container(keyedBy: NameKey.self).decode(String.self, forKey: .name)
      field = try? Field(from: decoder)
    }
  }
  private enum CodingKeys: String, CodingKey { case body, items, actions, back, fields, title }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    let body = try c.decodeIfPresent(String.self, forKey: .body)
    let items = try c.decodeIfPresent([Row].self, forKey: .items)
    var fields: [Field]?
    if let entries = try c.decodeIfPresent([FieldEntry].self, forKey: .fields) {
      // A malformed declaration should leave the body and the other controls usable, while still
      // counting its name so a duplicate valid sibling is dropped too.
      var nameCounts: [String: Int] = [:]
      for entry in entries {
        if let name = entry.name { nameCounts[name, default: 0] += 1 }
      }
      fields = entries.compactMap { entry in
        guard let field = entry.field, nameCounts[field.name] == 1 else { return nil }
        return field
      }
    }
    guard body != nil || items != nil || fields?.isEmpty == false else { throw Empty() }
    guard Row.validIDs(items ?? []) else {
      throw DecodingError.dataCorruptedError(forKey: .items, in: c, debugDescription: Row.invalidIDs)
    }
    self.init(
      body: body, items: items ?? [],
      actions: try c.decodeIfPresent([RowAction].self, forKey: .actions) ?? [],
      back: try c.decodeIfPresent([String: String].self, forKey: .back), fields: fields,
      title: try c.decodeIfPresent(String.self, forKey: .title)
    )
  }
}

struct Row: Codable, Sendable, Equatable, Identifiable {
  /// Stable within a provider; the host namespaces this for selection and usage.
  let id: String
  let title: String
  var subtitle: String?
  var tone: ActionTone?
  /// An SF Symbol name or, for an extension, a PNG or SVG path.
  var icon: String?
  var actions: [RowAction]
  let keywords: [String]?
  let prominent: Bool?
  /// Markdown with the six tags, like a tag row's content: in a command's list it shows beside the list
  /// while the item is selected, and on a page Return opens it.
  let detail: String?
  /// Host only, never decoded: an image file the host shows above the detail, such as a copied image.
  var picture: URL? = nil
  /// Host only, never decoded: the list owning this indexed entry.
  var entryList: String? = nil
  /// Host only, never decoded: the original ID of an item displayed by the index.
  var indexedItemID: String? = nil

  init(
    id: String, title: String, subtitle: String? = nil, icon: String? = nil, actions: [RowAction],
    keywords: [String]? = nil, prominent: Bool? = nil, detail: String? = nil, picture: URL? = nil,
    tone: ActionTone? = nil
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.tone = tone
    self.icon = icon
    self.actions = actions
    self.keywords = keywords
    self.prominent = prominent
    self.detail = detail
    self.picture = picture
  }
  private enum CodingKeys: String, CodingKey {
    case id, title, subtitle, icon, actions, keywords, prominent, detail, tone
  }
  /// The one rule for a list of items, in a view or a manifest: ids nonempty and unique.
  static func validIDs(_ rows: [Row]) -> Bool {
    Set(rows.map(\.id)).count == rows.count && rows.allSatisfy { !$0.id.isEmpty }
  }
  static let invalidIDs = "Item ids must be nonempty and unique"
}

/// A request and where it goes. Every field is optional and an omitted one means "this one, as now":
/// without `extension` the extension that produced the action, without `input` what is typed in the open
/// command (empty anywhere else), without `fields` the command's current values. Two spellings, one value: JSON for an
/// extension's own rows, `{"type":"run","extension":"weather","input":"berlin","fields":{"view":"hourly"}}`,
/// and a URL for outsiders, `wicket://weather?input=berlin`, which carries no fields. `agent`,
/// `settings`, `clipboard` and `history` are reserved targets: `agent` fills the input and never sends,
/// `clipboard` and `history` are the Clipboard and Agent History commands, and an empty
/// `extension`, as in a URL without one, is a root query.
struct Address: Codable, Sendable, Equatable {
  var extensionName: String?
  var input: String?
  var fields: [String: String]?
  var action: String?
  /// Spelled as a URL, or a host row that only shows what a pattern produced as such a URL would.
  /// Following a link is never a choice, so its request is not submitted. Never on the wire.
  var link = false
  /// The run's effect is its own feedback, such as a moved window: the panel hides at once and shows
  /// only for a failure or a view with something in it (`Navigator.runHidden`). A link never is.
  var hidden = false
  /// Start a hidden run with only the supplied values and show the command when its text field is blank.
  var promptIfEmpty = false

  private enum CodingKeys: String, CodingKey {
    case extensionName = "extension"
    case input, fields, action, hidden, promptIfEmpty
  }
  static let schemes = ["wicket", "wicket-dev"]
  static let reserved = ["agent", "settings", "clipboard", "history"]

  init(
    extensionName: String? = nil, input: String? = nil, fields: [String: String]? = nil,
    action: String? = nil,
    link: Bool = false,
    hidden: Bool = false, promptIfEmpty: Bool = false
  ) {
    self.extensionName = extensionName
    self.input = input
    self.fields = fields
    self.action = action
    self.link = link
    self.hidden = hidden
    self.promptIfEmpty = promptIfEmpty
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.init(
      extensionName: try c.decodeIfPresent(String.self, forKey: .extensionName),
      input: try c.decodeIfPresent(String.self, forKey: .input),
      fields: try c.decodeIfPresent([String: String].self, forKey: .fields),
      action: try c.decodeIfPresent(String.self, forKey: .action),
      hidden: try c.decodeIfPresent(Bool.self, forKey: .hidden) ?? false,
      promptIfEmpty: try c.decodeIfPresent(Bool.self, forKey: .promptIfEmpty) ?? false)
  }
  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(extensionName, forKey: .extensionName)
    try c.encodeIfPresent(input, forKey: .input)
    try c.encodeIfPresent(fields, forKey: .fields)
    try c.encodeIfPresent(action, forKey: .action)
    if hidden { try c.encode(true, forKey: .hidden) }
    if promptIfEmpty { try c.encode(true, forKey: .promptIfEmpty) }
  }
  /// The address of an extension by its ID, `extension:weather`.
  init(
    id: String, input: String? = nil, fields: [String: String]? = nil, action: String? = nil,
    link: Bool = false,
    hidden: Bool = false
  ) {
    self.init(
      extensionName: id.hasPrefix("extension:") ? String(id.dropFirst("extension:".count)) : id,
      input: input, fields: fields, action: action, link: link, hidden: hidden)
  }
  /// Parsed leniently: the target is the host or else the path, any query item but `input` is ignored and
  /// the fields are never read, because a URL comes from outside the extension. Percent-encode the
  /// input; `+` stays a plus.
  init?(url: URL) {
    guard let scheme = url.scheme?.lowercased(), Self.schemes.contains(scheme),
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false)
    else { return nil }
    let name = (parts.host ?? "").isEmpty ? parts.path.trimmingCharacters(in: ["/"]) : parts.host!
    self.init(
      extensionName: name,
      input: parts.queryItems?.first { $0.name == "input" }?.value, link: true)
  }

  /// The host's name for the target: a reserved name, an extension ID, or nil for the root.
  var targetID: String? {
    guard let name = extensionName, !name.isEmpty else { return nil }
    if Self.reserved.contains(name.lowercased()) { return name.lowercased() }
    return name.hasPrefix("extension:") ? name : "extension:" + name
  }

  var linkComponents: URLComponents {
    var url = URLComponents()
    url.scheme = Self.schemes[0]
    url.encodedHost = (extensionName ?? "").addingPercentEncoding(withAllowedCharacters: .urlHostAllowed)
    url.queryItems = input.map { [URLQueryItem(name: "input", value: $0)] }
    return url
  }
}

enum ActionTone: String, Codable, Sendable {
  case destructive
}

/// What Return, a button or a menu item does. Every row carries one, including the host's own, so one
/// dispatcher serves all of them and a row's ID is only its identity. An optional `title` names it in
/// menus in place of the kind's own label.
struct RowAction: Codable, Sendable, Equatable {
  enum Kind: Sendable, Equatable {
    case open(URL)
    case copy(String, concealed: Bool = false)
    case paste(String, concealed: Bool = false)
    case run(Address)
    /// Show an existing file or folder in Finder. Nothing is opened or run.
    case reveal(URL)
    /// Host only, never decoded: send the text to the agent as a question.
    case send(String)
    /// Host only, never decoded: ask about the current screen.
    case ask
    /// Host only, never decoded: show this Markdown as its own page, an item's detail, with the item's
    /// own action as a row at its end, exactly as parsed. Escape returns.
    case detail(String, action: Row? = nil)
    /// Host only: advance a field on the visible command page.
    case field(String)
    /// Host only, never decoded: copy or paste the clipboard history's image with this ID, read when it runs.
    case clip(String, paste: Bool)
    /// Host only, never decoded: record a row's hotkey (Set Hotkey…), or with `record` false remove it.
    case hotkey(HotkeyTarget, record: Bool)
    /// Host only, never decoded: ask macOS for a permission, then replay the gated request.
    case grant(Permission, then: Address)
    case save(setting: String, values: [String: String])
    /// Host only: show an extension list in Settings.
    case editList(folder: String, setting: String)
    // Host notice actions, never decoded.
    case checkForUpdates
    case dismissNotice
  }
  var kind: Kind
  var title: String?
  var tone: ActionTone?

  init(_ kind: Kind, title: String? = nil, tone: ActionTone? = nil) {
    self.kind = kind
    self.title = title
    self.tone = tone
  }
  static func open(_ url: URL, title: String? = nil) -> Self { Self(.open(url), title: title) }
  static func copy(_ text: String, title: String? = nil) -> Self { Self(.copy(text), title: title) }
  static func paste(_ text: String, title: String? = nil) -> Self { Self(.paste(text), title: title) }
  static func run(_ address: Address, title: String? = nil) -> Self { Self(.run(address), title: title) }
  static func reveal(_ url: URL, title: String? = nil) -> Self { Self(.reveal(url), title: title) }
  static func send(_ text: String) -> Self { Self(.send(text)) }
  /// Fill the input with the text and send nothing.
  static func agent(_ text: String, title: String? = nil) -> Self {
    .run(Address(extensionName: "agent", input: text), title: title)
  }

  private enum CodingKeys: String, CodingKey {
    case type, url, text, title, paste, concealed, setting, values, tone
    case extensionName = "extension"
  }
  init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    title = try c.decodeIfPresent(String.self, forKey: .title)
    tone = try c.decodeIfPresent(ActionTone.self, forKey: .tone)
    let type = try c.decode(String.self, forKey: .type)
    switch type {
    case "open":
      let url = try c.decode(URL.self, forKey: .url)
      kind = Address(url: url).map(Kind.run) ?? .open(url)
    case "reveal": kind = .reveal(try c.decode(URL.self, forKey: .url))
    case "copy", "paste":
      let text = try c.decode(String.self, forKey: .text)
      let concealed = try c.decodeIfPresent(Bool.self, forKey: .concealed) ?? false
      kind = type == "copy" ? .copy(text, concealed: concealed) : .paste(text, concealed: concealed)
    case "save":
      guard !c.contains(.extensionName) else {
        throw DecodingError.dataCorruptedError(
          forKey: .extensionName, in: c, debugDescription: "Save can only target its own extension")
      }
      kind = .save(
        setting: try c.decode(String.self, forKey: .setting),
        values: try c.decode([String: String].self, forKey: .values))
    case "run": kind = .run(try Address(from: decoder))
    case "agent": kind = Self.agent(try c.decode(String.self, forKey: .text)).kind
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: c, debugDescription: "Unknown action type")
    }
  }
  func encode(to encoder: any Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encodeIfPresent(title, forKey: .title)
    try c.encodeIfPresent(tone, forKey: .tone)
    switch kind {
    case .open(let url):
      try c.encode("open", forKey: .type)
      try c.encode(url, forKey: .url)
    case .reveal(let url):
      try c.encode("reveal", forKey: .type)
      try c.encode(url, forKey: .url)
    case .copy(let text, let concealed), .paste(let text, let concealed):
      if case .copy = kind {
        try c.encode("copy", forKey: .type)
      } else {
        try c.encode("paste", forKey: .type)
      }
      try c.encode(text, forKey: .text)
      if concealed { try c.encode(true, forKey: .concealed) }
    case .run(let address) where address.link:
      try c.encode("open", forKey: .type)
      try c.encode(address.linkComponents.string ?? "wicket://", forKey: .url)
    case .run(let address):
      try c.encode("run", forKey: .type)
      try address.encode(to: encoder)
    case .send(let text):
      try c.encode("send", forKey: .type)
      try c.encode(text, forKey: .text)
    case .ask:
      try c.encode("ask", forKey: .type)
    case .detail(let text, _):
      try c.encode("detail", forKey: .type)
      try c.encode(text, forKey: .text)
    case .field(let name):
      try c.encode("field", forKey: .type)
      try c.encode(name, forKey: .text)
    case .clip(let id, let paste):
      try c.encode("clip", forKey: .type)
      try c.encode(id, forKey: .text)
      try c.encode(paste, forKey: .paste)
    case .hotkey(let target, let record):
      try c.encode(record ? "setHotkey" : "removeHotkey", forKey: .type)
      try c.encode(target.description, forKey: .text)
    case .grant(let permission, _):
      try c.encode("grant", forKey: .type)
      try c.encode(permission.rawValue, forKey: .text)
    case .save(let setting, let values):
      try c.encode("save", forKey: .type)
      try c.encode(setting, forKey: .setting)
      try c.encode(values, forKey: .values)
    case .editList:
      try c.encode("editList", forKey: .type)
    case .checkForUpdates:
      try c.encode("checkForUpdates", forKey: .type)
    case .dismissNotice:
      try c.encode("dismissNotice", forKey: .type)
    }
  }
}

/// What an `open` or `reveal` may touch, checked when the action runs rather than when a view is decoded,
/// so one vanished or unsafe file refuses only its own action and never the whole view.
enum OpenPolicy {
  static func allowed(_ url: URL) -> Bool {
    // System Settings panes too, so an extension can send the user to the permission it needs.
    guard url.isFileURL else {
      return ["http", "https", "mailto", "x-apple.systempreferences"].contains(url.scheme?.lowercased() ?? "")
    }
    let file = url.resolvingSymlinksInPath()
    let ext = file.pathExtension.lowercased()
    guard
      !["command", "pkg", "mpkg", "dmg", "sh", "bash", "zsh", "py", "js", "scpt", "applescript", "workflow"]
        .contains(ext)
    else { return false }
    var directory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: file.path, isDirectory: &directory) else { return false }
    return directory.boolValue || !FileManager.default.isExecutableFile(atPath: file.path)
  }
  /// Revealing selects an item in Finder and runs nothing, so any existing file or folder will do.
  static func revealable(_ url: URL) -> Bool {
    url.isFileURL && FileManager.default.fileExists(atPath: url.path)
  }
  /// Why an open or reveal must do nothing, or nil when it may run.
  static func refusal(_ action: RowAction) -> String? {
    switch action.kind {
    case .open(let url) where !allowed(url):
      guard url.isFileURL else {
        return "Wicket opens only http, https, mailto, System Settings and wicket links"
      }
      return revealable(url) ? "Wicket does not open scripts, installers or executables" : missing
    case .reveal(let url) where !revealable(url): return url.isFileURL ? missing : "Reveal needs a file"
    default: return nil
    }
  }
  private static let missing = "This file no longer exists"
}
