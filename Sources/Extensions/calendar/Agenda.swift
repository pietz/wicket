import Foundation

/// A calendar on this Mac, as EventKit names it.
struct AgendaCalendar: Sendable, Equatable {
  let id: String
  let title: String
}

/// One occurrence: EventKit expands a repeating event into one of these per repeat.
struct AgendaEvent: Sendable {
  /// Stable across runs: the event's identifier and its occurrence date.
  var id: String
  var title: String
  var start: Date
  var end: Date
  var isAllDay = false
  var calendarID: String
  var location = ""
  var notes = ""
  var url: URL?
  var cancelled = false
  /// The user declined the invitation.
  var declined = false
}

/// What one read of the calendar store found.
enum Snapshot: Sendable {
  case denied
  case loaded(calendars: [AgendaCalendar], events: [AgendaEvent])
}

let agendaDays = 7
let eventCap = 100
/// A call starting this soon counts as now: Return joins it.
let joinLead: TimeInterval = 10 * 60

/// The local days the agenda covers, from the start of today.
func agendaWindow(now: Date, calendar: Calendar) -> DateInterval {
  let today = calendar.startOfDay(for: now)
  return DateInterval(start: today, end: calendar.date(byAdding: .day, value: agendaDays, to: today)!)
}

/// The view for one request: the agenda page, the agent's read, or a row saying why there is nothing.
func calendarView(_ request: JSON?, snapshot: Snapshot, now: Date, calendar: Calendar) -> String {
  guard case .loaded(let calendars, let events) = snapshot else {
    return rowView(
      "denied", "Allow Calendar for Wicket", "Turn on Wicket under Privacy & Security ▸ Calendars",
      icon: "calendar",
      action: openAction(
        "Open Privacy & Security", "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
      ))
  }
  guard !calendars.isEmpty else {
    return rowView(
      "no-calendars", "No calendars on this Mac", "Add an account in System Settings ▸ Internet Accounts",
      icon: "calendar",
      action: openAction(
        "Open Internet Accounts", "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension"))
  }
  let settings = request?["settings"]
  let hidden = Set(
    (settings?["hiddenCalendars"]?.string ?? "").split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) })
  let query = (request?["fields"]?["query"]?.string ?? request?["input"]?.string ?? "")
    .trimmingCharacters(in: .whitespacesAndNewlines)
  let agenda = Agenda(
    events: events, calendars: calendars.filter { !hidden.contains($0.id) }, query: query,
    showAllDay: settings?["showAllDay"]?.string != "false", now: now, calendar: calendar)
  if request?["submitted"]?.isTrue == true, request?["action"]?.string == "read-agenda" {
    return agenda.read(calendars: calendars, hidden: hidden)
  }
  guard !agenda.names.isEmpty else {
    return rowView(
      "all-hidden", "All calendars are hidden", "Clear Hidden calendars in Settings ▸ Extensions ▸ Calendar",
      icon: "eye.slash", action: openAction("Open Settings", "wicket://settings"))
  }
  return agenda.page()
}

private let calendarApp = openAction("Open Calendar", "file:///System/Applications/Calendar.app")

private struct Agenda {
  let names: [String: String]
  let query: String
  let showAllDay: Bool
  let now: Date
  let calendar: Calendar
  let today: Date
  /// Listed in order, at most `eventCap`.
  let events: [AgendaEvent]
  /// How many matched before the cap.
  let total: Int
  private let style: Date.FormatStyle

  init(
    events: [AgendaEvent], calendars: [AgendaCalendar], query: String, showAllDay: Bool, now: Date,
    calendar: Calendar
  ) {
    let names = Dictionary(calendars.map { ($0.id, $0.title) }) { first, _ in first }
    let window = agendaWindow(now: now, calendar: calendar)
    self.names = names
    self.query = query
    self.showAllDay = showAllDay
    self.now = now
    self.calendar = calendar
    today = window.start
    style = Date.FormatStyle(
      date: .omitted, time: .omitted, locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
      timeZone: calendar.timeZone)
    let listed = events.filter { event in
      guard !event.cancelled, !event.declined, let name = names[event.calendarID],
        event.start < window.end, event.isAllDay ? showAllDay && event.end > window.start : event.end > now
      else { return false }
      return query.isEmpty
        || [event.title, event.location, name].contains { $0.localizedStandardContains(query) }
    }
    let today = window.start
    func day(_ event: AgendaEvent) -> Date { listedDay(event, calendar: calendar, today: today) }
    // Every key, so the same events always list in the same order.
    let sorted = listed.sorted { a, b in
      let (dayA, dayB) = (day(a), day(b))
      if dayA != dayB { return dayA < dayB }
      if a.isAllDay != b.isAllDay { return a.isAllDay }
      if a.start != b.start { return a.start < b.start }
      if a.end != b.end { return a.end < b.end }
      return (a.title, a.id) < (b.title, b.id)
    }
    self.events = Array(sorted.prefix(eventCap))
    total = sorted.count
  }

  func day(_ event: AgendaEvent) -> Date { listedDay(event, calendar: calendar, today: today) }

  // MARK: The page

  func page() -> String {
    guard !events.isEmpty else {
      if !query.isEmpty {
        return rowView(
          "no-matches", "No events match “\(query)”", "Searched titles, places and calendars for 7 days",
          icon: "magnifyingglass", action: nil)
      }
      let shown = names.count == 1 ? "1 calendar" : "\(names.count) calendars"
      return rowView(
        "no-events", "No events in the next 7 days", shown, icon: "calendar", action: calendarApp)
    }
    var lines: [String] = []
    var actions: [String] = []
    if query.isEmpty {
      summary(&lines, &actions)
    } else {
      lines += [
        "# \(events.count == 1 ? "1 event" : "\(events.count) events")",
        "Matching “\(literal(query))” in the next 7 days",
      ]
    }
    if query.isEmpty, let first = events.first, day(first) != today {
      lines += ["", "### Today", "Nothing else today"]
    }
    var shownDay: Date?
    for event in events {
      let day = day(event)
      if day != shownDay {
        lines += ["", "### " + heading(day)]
        shownDay = day
      }
      lines.append(row(event, &actions))
    }
    if total > events.count { lines += ["", "Showing the first \(events.count) of \(total) events."] }
    return
      #"{"body":\#(quoted(lines.joined(separator: "\n"))),"actions":[\#((actions + [calendarApp]).joined(separator: ","))]}"#
  }

  /// The top of the page: calls that are on or about to start, else the next timed event. A call there
  /// is the view's first action, so Return joins it.
  private func summary(_ lines: inout [String], _ actions: inout [String]) {
    let timed = events.filter { !$0.isAllDay }
    let calls = timed.filter { $0.start.timeIntervalSince(now) <= joinLead }.compactMap { event in
      meetingLinks(in: event).first.map { (event, $0) }
    }
    if let (event, link) = calls.first {
      actions.append(openAction("Join \(title(event))", link.url.absoluteString))
    }
    if calls.count > 1 {
      lines += ["# \(calls.count) calls now", "Overlapping calls"]
      for (event, link) in calls {
        lines += target(
          title(event), subtitle: "\(link.service) · \(relative(event))", icon: "video", link.url,
          action: "Join", &actions)
      }
      return
    }
    guard let next = calls.first?.0 ?? timed.first(where: { $0.start > now }) ?? timed.first else {
      lines += [
        "# \(events.count == 1 ? "1 event" : "\(events.count) events")", "No meetings in the next 7 days",
      ]
      return
    }
    let links = meetingLinks(in: next)
    lines += [
      "# " + literal(title(next)),
      ([relative(next)] + [place(next, links)].filter { !$0.isEmpty }.map(literal)).joined(separator: " · "),
    ]
    if let link = links.first {
      lines += target(
        "Join \(link.service)", subtitle: link.host, icon: "video", link.url, action: "Join", &actions)
    }
  }

  /// An event's row: its time, title and place, and its facts as the detail Return opens.
  private func row(_ event: AgendaEvent, _ actions: inout [String]) -> String {
    let links = meetingLinks(in: event)
    var tag =
      #"<row label="\#(event.isAllDay ? "All day" : time(event.start))" title="\#(attribute(title(event)))""#
    let place = place(event, links)
    if !place.isEmpty { tag += #" subtitle="\#(attribute(place))""# }
    if !event.isAllDay, event.start <= now { tag += #" value="Now""# }
    var detail = [property("When", when(event)), property("Calendar", names[event.calendarID] ?? "")]
    let location = event.location.trimmingCharacters(in: .whitespacesAndNewlines)
    if !location.isEmpty, meetingLink(location) == nil { detail.append(property("Location", location)) }
    for link in links {
      detail += target(
        "Join \(link.service)", subtitle: link.host, icon: "video", link.url, action: "Join", event: event,
        &actions)
    }
    if let url = event.url, url.scheme == "https", !links.contains(where: { $0.url == url }) {
      detail += target(
        "Open \(url.host() ?? "link")", subtitle: "Event link", icon: "link", url, action: "Open",
        event: event,
        &actions)
    }
    if !event.notes.isEmpty { detail += ["", plainText(event.notes)] }
    return tag + ">\n" + detail.joined(separator: "\n") + "\n</row>"
  }

  /// A row that opens `url`, or, when its tag would be too long for Wicket to read, a view action instead,
  /// named after `event` when the row's own title does not say which event it belongs to.
  private func target(
    _ title: String, subtitle: String, icon: String, _ url: URL, action: String, event: AgendaEvent? = nil,
    _ actions: inout [String]
  ) -> [String] {
    let tag =
      #"<row icon="\#(icon)" title="\#(attribute(title))" subtitle="\#(attribute(subtitle))" open="\#(url.absoluteString)" action="\#(action)"/>"#
    guard tag.utf8.count > 1024 else { return [tag] }
    let link = quoted(url.absoluteString)
    if !actions.contains(where: { $0.contains(link) }) {
      actions.append(openAction(event.map { "\(title): \(self.title($0))" } ?? title, url.absoluteString))
    }
    return []
  }

  // MARK: The agent's read

  /// Plain text for the agent: every listed event as an item with a stable ID, its facts and invitation
  /// notes in the detail, and every calendar with its ID, so the agent can edit `hiddenCalendars`.
  func read(calendars: [AgendaCalendar], hidden: Set<String>) -> String {
    let end = calendar.date(byAdding: .day, value: agendaDays - 1, to: today)!
    var scope =
      "Now is \(shortDay(now)) \(time(now)) (\(calendar.timeZone.identifier)); listed through \(shortDay(end))"
    if !query.isEmpty { scope += ", matching “\(query)”" }
    if !showAllDay { scope += ", without all-day events (setting showAllDay)" }
    var body = ["# \(events.count == 1 ? "1 event" : "\(events.count) events")", scope + "."]
    if total > events.count { body.append("Only the first \(events.count) of \(total) are listed.") }
    body += ["", "Calendars (title, ID; hide one by adding its ID to the hiddenCalendars setting):"]
    body += calendars.map { "- \($0.title), \($0.id)" + (hidden.contains($0.id) ? " (hidden)" : "") }
    var seen: Set<String> = []
    let items = events.map { event in
      var id = event.id
      while !seen.insert(id).inserted { id += "+" }
      let links = meetingLinks(in: event)
      let calendarName = names[event.calendarID] ?? ""
      var facts = ["When: \(when(event))", "Calendar: \(calendarName), \(event.calendarID)"]
      if !event.location.isEmpty { facts.append("Location: \(event.location)") }
      facts += links.map { "Join (\($0.service)): \($0.url.absoluteString)" }
      if let url = event.url, !links.contains(where: { $0.url == url }) {
        facts.append("Link: \(url.absoluteString)")
      }
      if !event.notes.isEmpty { facts += ["", "Notes:", event.notes] }
      let subtitle = [when(event), calendarName].joined(separator: " · ")
      let joins = links.map { openAction("Join \($0.service)", $0.url.absoluteString) }
      return
        #"{"id":\#(quoted(id)),"title":\#(quoted(title(event))),"subtitle":\#(quoted(subtitle)),"detail":\#(quoted(tagsAsText(facts.joined(separator: "\n")))),"actions":[\#(joins.joined(separator: ","))]}"#
    }
    return
      #"{"body":\#(quoted(tagsAsText(body.joined(separator: "\n")))),"items":[\#(items.joined(separator: ","))]}"#
  }

  // MARK: Words

  private func title(_ event: AgendaEvent) -> String {
    let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Untitled" : title
  }

  /// Where it is: a place, else the call's service.
  private func place(_ event: AgendaEvent, _ links: [MeetingLink]) -> String {
    let location = event.location.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    return location.isEmpty || meetingLink(location) != nil ? links.first?.service ?? "" : location
  }

  private func time(_ date: Date) -> String { date.formatted(style.hour().minute()) }
  private func shortDay(_ date: Date) -> String {
    date.formatted(style.weekday(.abbreviated).day().month(.abbreviated))
  }
  private func nearDay(_ day: Date) -> String? {
    switch calendar.dateComponents([.day], from: today, to: day).day {
    case 0: "Today"
    case 1: "Tomorrow"
    default: nil
    }
  }
  private func heading(_ day: Date) -> String {
    nearDay(day) ?? day.formatted(style.weekday(.wide).day().month(.wide))
  }
  private func endsSameDay(_ event: AgendaEvent) -> Bool {
    event.end <= calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.start))!
  }
  private func span(_ event: AgendaEvent) -> String {
    if event.end <= event.start { return time(event.start) }
    return endsSameDay(event)
      ? "\(time(event.start))–\(time(event.end))"
      : "\(time(event.start)) – \(shortDay(event.end)) \(time(event.end))"
  }

  /// The local interval: date and times, or the days an all-day event covers.
  private func when(_ event: AgendaEvent) -> String {
    guard event.isAllDay else { return "\(shortDay(event.start)), \(span(event))" }
    let first = calendar.startOfDay(for: event.start)
    // EventKit ends an all-day event a second before midnight; other stores end it at midnight.
    let last = max(first, calendar.startOfDay(for: event.end.addingTimeInterval(-1)))
    return first == last ? "\(shortDay(first)), all day" : "\(shortDay(first)) – \(shortDay(last))"
  }

  /// When a timed event is, from now: on now, starting in minutes, or its day and times.
  private func relative(_ event: AgendaEvent) -> String {
    if event.start <= now {
      let until = endsSameDay(event) ? time(event.end) : "\(shortDay(event.end)) \(time(event.end))"
      return "Now until \(until)"
    }
    let minutes = Int((event.start.timeIntervalSince(now) / 60).rounded(.up))
    if minutes < 60 { return "In \(minutes) min · \(span(event))" }
    let day = day(event)
    return "\(nearDay(day) ?? shortDay(day)) \(span(event))"
  }
}

/// The day an event is listed under: one that began before today and is still on shows today.
private func listedDay(_ event: AgendaEvent, calendar: Calendar, today: Date) -> Date {
  max(calendar.startOfDay(for: event.start), today)
}

// MARK: Output

private func openAction(_ title: String, _ url: String) -> String {
  #"{"type":"open","title":\#(quoted(title)),"url":\#(quoted(url))}"#
}

/// One row saying why there is nothing to list, with what fixes it.
private func rowView(_ id: String, _ title: String, _ subtitle: String, icon: String, action: String?)
  -> String
{
  #"{"items":[{"id":"\#(id)","title":\#(quoted(title)),"subtitle":\#(quoted(subtitle)),"icon":"\#(icon)","actions":[\#(action ?? "")]}]}"#
}

private func property(_ label: String, _ value: String) -> String {
  #"<row label="\#(label)" value="\#(attribute(value))"/>"#
}

/// Invitation text as a tag attribute: one line without double quotes, short enough that the whole tag
/// stays well within the 4,096 bytes Wicket reads.
private func attribute(_ text: String, limit: Int = 300) -> String {
  let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    .replacingOccurrences(of: "\"", with: "”")
  guard line.utf8.count > limit else { return line }
  var cut = ""
  for character in line {
    if cut.utf8.count + character.utf8.count > limit - 3 { break }
    cut.append(character)
  }
  return cut + "…"
}

/// Markdown and tag punctuation as character references, so invitation text shows as typed and can
/// neither add tags and links nor change the page around it.
private let syntax = CharacterSet(charactersIn: "!\"#&'()*+-.<>[\\]_`{|}~:")
private func literal(_ text: String) -> String {
  text.unicodeScalars.map { syntax.contains($0) ? "&#\($0.value);" : String($0) }.joined()
}

/// Notes as plain text: lines kept, blank runs as one paragraph break, at most 2,000 characters.
private func plainText(_ notes: String) -> String {
  var text = notes.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
  if text.count > 2000 { text = String(text.prefix(2000)) + "…" }
  var paragraphs: [[String]] = [[]]
  for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
    let line = line.trimmingCharacters(in: .whitespaces)
    if !line.isEmpty {
      paragraphs[paragraphs.count - 1].append(literal(line))
    } else if !paragraphs[paragraphs.count - 1].isEmpty {
      paragraphs.append([])
    }
  }
  // A backslash before the line end keeps the invitation's line breaks.
  return paragraphs.filter { !$0.isEmpty }.map { $0.joined(separator: "\\\n") }.joined(separator: "\n\n")
}

/// The agent's read is read as text, so only tags are neutralized there.
private func tagsAsText(_ text: String) -> String {
  text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
}

extension JSON {
  var isTrue: Bool {
    if case .bool(true) = self { true } else { false }
  }
}
