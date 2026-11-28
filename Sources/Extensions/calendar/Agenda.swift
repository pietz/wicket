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
/// The agent's read stays under the 1 MiB Wicket reads from a program.
let readLimit = 1_000_000
let noteLimit = 4_000
let titleLimit = 500
/// A call starting this soon counts as now: Return joins it.
let joinLead: TimeInterval = 10 * 60

/// The local days the agenda covers, from the start of today.
func agendaWindow(now: Date, calendar: Calendar) -> DateInterval {
  let today = calendar.startOfDay(for: now)
  return DateInterval(start: today, end: calendar.date(byAdding: .day, value: agendaDays, to: today)!)
}

enum CalendarLayout: String, CaseIterable {
  case agenda, week

  init(_ request: JSON?) {
    self =
      Self.readsAgenda(request)
      ? .agenda
      : request?["fields"]?["view"]?.string.flatMap(Self.init(rawValue:))
        ?? .agenda
  }

  static func readsAgenda(_ request: JSON?) -> Bool {
    request?["submitted"]?.isTrue == true && request?["action"]?.string == "read-agenda"
  }

  func window(now: Date, calendar: Calendar) -> DateInterval {
    switch self {
    case .agenda: agendaWindow(now: now, calendar: calendar)
    case .week: calendar.dateInterval(of: .weekOfYear, for: now)!
    }
  }

  func control(label: String) -> String {
    let options = Self.allCases.map {
      #"{"value":"\#($0.rawValue)","label":"\#($0.rawValue.capitalized)"}"#
    }.joined(separator: ",")
    let caption = self == .agenda && label.count > 60 ? String(label.prefix(59)) + "…" : label
    return
      #"{"name":"view","type":"choice","description":\#(quoted(caption)),"value":"\#(rawValue)","options":[\#(options)]}"#
  }

  static let marker = #"<field name="view"/>"#
}

/// The agent's read without access: it fails, so the agent can tell it from an empty agenda.
struct CalendarAccessDenied: Error, CustomStringConvertible {
  let description =
    "Calendar access was refused. Allow Wicket under System Settings ▸ Privacy & Security ▸ Calendars; "
    + "a sandboxed agent may be refused even when it is on."
}

/// The view for one request: the agenda page, the agent's read, or a row saying why there is nothing.
func calendarView(_ request: JSON?, snapshot: Snapshot, now: Date, calendar: Calendar) throws -> String {
  let reads = CalendarLayout.readsAgenda(request)
  guard case .loaded(let calendars, let events) = snapshot else {
    if reads { throw CalendarAccessDenied() }
    return rowView(
      "denied", "Allow Calendar for Wicket", "Turn on Wicket under Privacy & Security ▸ Calendars",
      icon: "calendar",
      action: openAction(
        "Open Privacy & Security", "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars"
      ))
  }
  guard !calendars.isEmpty else {
    if reads {
      return
        #"{"body":"No calendars on this Mac: add an account in System Settings ▸ Internet Accounts.","items":[]}"#
    }
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
    showAllDay: settings?["showAllDay"]?.string != "false", now: now, calendar: calendar,
    layout: CalendarLayout(request))
  if reads { return agenda.read(calendars: calendars, hidden: hidden) }
  guard !agenda.names.isEmpty else {
    return rowView(
      "all-hidden", "All calendars are hidden", "Clear Hidden calendars in Settings ▸ Extensions ▸ Calendar",
      icon: "eye.slash", action: openAction("Open Settings", "wicket://settings"))
  }
  switch agenda.layout {
  case .agenda: return agenda.page()
  case .week: return agenda.week()
  }
}

private let calendarApp = openAction("Open Calendar", "file:///System/Applications/Calendar.app")

private struct Agenda {
  let names: [String: String]
  let query: String
  let showAllDay: Bool
  let now: Date
  let calendar: Calendar
  let today: Date
  let layout: CalendarLayout
  let window: DateInterval
  /// Listed in order; the agenda caps the list at `eventCap`.
  let events: [AgendaEvent]
  /// How many matched before the cap.
  let total: Int
  private let style: Date.FormatStyle

  init(
    events: [AgendaEvent], calendars: [AgendaCalendar], query: String, showAllDay: Bool, now: Date,
    calendar: Calendar, layout: CalendarLayout
  ) {
    let names = Dictionary(calendars.map { ($0.id, $0.title) }) { first, _ in first }
    let window = layout.window(now: now, calendar: calendar)
    self.layout = layout
    self.window = window
    self.names = names
    self.query = query
    self.showAllDay = showAllDay
    self.now = now
    self.calendar = calendar
    today = calendar.startOfDay(for: now)
    style = Date.FormatStyle(
      date: .omitted, time: .omitted, locale: calendar.locale ?? .autoupdatingCurrent, calendar: calendar,
      timeZone: calendar.timeZone)
    let listed = events.filter { event in
      guard !event.cancelled, !event.declined, let name = names[event.calendarID],
        event.start < window.end, !event.isAllDay || (layout == .agenda && showAllDay)
      else { return false }
      if layout == .agenda {
        guard event.end > (event.isAllDay ? window.start : now) else { return false }
      } else {
        guard event.end > window.start || event.start >= window.start else { return false }
      }
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
    self.events = layout == .agenda ? Array(sorted.prefix(eventCap)) : sorted
    total = sorted.count
  }

  func day(_ event: AgendaEvent) -> Date { listedDay(event, calendar: calendar, today: today) }

  // MARK: The page

  func page() -> String {
    guard !events.isEmpty else {
      if !query.isEmpty {
        return rowView(
          "no-matches", "No events match “\(query)”", "Searched titles, places and calendars for 7 days",
          icon: "magnifyingglass", action: nil, layout: layout)
      }
      let shown = names.count == 1 ? "1 calendar" : "\(names.count) calendars"
      return rowView(
        "no-events", "No events in the next 7 days", shown, icon: "calendar", action: calendarApp,
        layout: layout)
    }
    var lines: [String] = []
    // Return with nothing selected runs the first view action: Join for a call that is on or about to
    // start, else Open Calendar. Links too long for a row's tag follow it.
    let calls = query.isEmpty ? callsNow : []
    var actions = calls.first.map { [openAction("Join \(title($0.0))", $0.1.url.absoluteString)] } ?? []
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
    return page(
      lines, label: summary(calls), actions: calls.isEmpty ? [calendarApp] + actions : actions + [calendarApp]
    )
  }

  private func page(_ lines: [String], label: String, actions: [String] = [calendarApp]) -> String {
    let body = quoted(([CalendarLayout.marker, ""] + lines).joined(separator: "\n"))
    let back = layout == .agenda ? "" : #","back":{"view":"agenda"}"#
    return
      #"{"body":\#(body),"fields":[\#(layout.control(label: label))],"actions":[\#(actions.joined(separator: ","))]\#(back)}"#
  }

  private func dayOffset(_ day: Date, _ count: Int) -> Date {
    calendar.date(byAdding: .day, value: count, to: day)!
  }

  private func events(during day: DateInterval) -> [AgendaEvent] {
    events.filter { $0.start < day.end && ($0.end > day.start || $0.start >= day.start) }
  }

  func week() -> String {
    let days = (0..<7).map { offset in
      calendar.dateInterval(of: .day, for: dayOffset(window.start, offset))!
    }
    let labels = days.map { day in
      let date = day.start
      return attribute(
        date.formatted(style.weekday(.abbreviated)).replacingOccurrences(of: ",", with: "")
          + " " + date.formatted(style.day()))
    }
    let last = days[6].start.formatted(style.month(.abbreviated).day().year())
    let period = window.start.formatted(style.month(.abbreviated).day()) + " – " + last
    var lines: [String] = []
    var spans: [(event: AgendaEvent, lane: String, from: Int, to: Int)] = []
    for (day, lane) in zip(days, labels) {
      for event in events(during: day) {
        let from = minute(max(day.start, event.start), in: day)
        let to = minute(min(day.end, event.end), in: day)
        spans.append((event, lane, from, max(from + 1, to)))
      }
    }
    let marker =
      days.firstIndex { $0.start == today }.map { index in
        #" now="\#(clock(minute(now, in: days[index])))" now-lane="\#(labels[index])""#
      } ?? ""
    let shown = spans.prefix(eventCap)
    let bounds = shown.isEmpty ? #" from="08:00" to="18:00""# : ""
    lines.append(#"<timeline lanes="\#(labels.joined(separator: ","))"\#(bounds)\#(marker)>"#)
    lines += shown.map { span in
      let slots = #" lane="\#(span.lane)" from="\#(clock(span.from))" to="\#(clock(span.to))""#
      var actions: [String] = []
      return row(span.event, &actions, span: slots)
    }
    lines.append("</timeline>")
    let limited = shown.count == spans.count ? "" : " · \(shown.count) of \(spans.count) timed entries"
    return page(lines, label: period + limited)
  }

  private func minute(_ date: Date, in day: DateInterval) -> Int {
    Int(date.timeIntervalSince(day.start) / 60)
  }

  private func clock(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }

  private func eventCount(_ count: Int) -> String { count == 1 ? "1 event" : "\(count) events" }

  /// Calls that are on or start within `joinLead`, each with its first link.
  private var callsNow: [(AgendaEvent, MeetingLink)] {
    events.filter { !$0.isAllDay && $0.start.timeIntervalSince(now) <= joinLead }.compactMap { event in
      meetingLinks(in: event).first.map { (event, $0) }
    }
  }

  private func summary(_ calls: [(AgendaEvent, MeetingLink)]) -> String {
    if !query.isEmpty { return "\(eventCount(total)) matching “\(query)”" }
    if let first = calls.first {
      let overlapping = calls.filter { $0.0.start < first.0.end }.count
      if overlapping > 1 {
        let timing = first.0.start <= now ? "Now" : "Next"
        return "\(timing): \(overlapping) overlapping calls"
      }
    }
    let timed = events.filter { !$0.isAllDay }
    guard let event = calls.first?.0 ?? timed.first(where: { $0.start > now }) ?? timed.first else {
      return eventCount(total)
    }
    if event.start <= now {
      let location = place(event)
      let service = location.isEmpty ? calls.first?.1.service ?? "" : location
      let end = endsSameDay(event) ? time(event.end) : "\(shortDay(event.end)) \(time(event.end))"
      return "Now: \(title(event)) until \(end)" + (service.isEmpty ? "" : " · " + service)
    }
    let day = day(event)
    let start =
      day == today
      ? "at " + time(event.start) : (nearDay(day)?.lowercased() ?? shortDay(day)) + " " + time(event.start)
    return "Next: \(title(event)) \(start)"
  }

  /// An event’s row with its facts and links in the detail, and Join first in Agenda when it fits.
  private func row(_ event: AgendaEvent, _ actions: inout [String], span: String? = nil) -> String {
    let links = meetingLinks(in: event)
    let kind = span == nil ? "row" : "span"
    let timeLabel = layout == .agenda ? label(event) : time(event.start)
    var tag = #"<\#(kind) label="\#(timeLabel)" title="\#(attribute(title(event)))"\#(span ?? "")"#
    let location = place(event)
    let service = links.first?.service
    let subtitle = layout == .week && location.isEmpty ? service ?? "" : location
    if !subtitle.isEmpty { tag += #" subtitle="\#(attribute(subtitle))""# }
    var primary: MeetingLink?
    if layout == .agenda {
      let live = !event.isAllDay && event.start <= now
      let value = [live ? "Now" : nil, service == "Microsoft Teams" ? "Teams" : service]
        .compactMap { $0 }.joined(separator: " · ")
      if !value.isEmpty { tag += #" value="\#(value)""# }
      if let link = links.first {
        let join = tag + #" open="\#(link.url.absoluteString)" action="Join" action-first="true""#
        if join.utf8.count < 4096 {
          tag = join
          primary = link
        }
      }
    }
    var detail = [property("When", when(event)), property("Calendar", names[event.calendarID] ?? "")]
    // The detail keeps other links, such as a map, that the row's place leaves out; calls show as Join.
    let fullLocation = event.location.split(whereSeparator: \.isWhitespace)
      .filter { meetingLink(String($0)) == nil }.joined(separator: " ")
    if !fullLocation.isEmpty { detail.append(property("Location", fullLocation)) }
    var linkRows: [String] = []
    for link in links where link != primary {
      linkRows += target(
        "Join \(link.service)", subtitle: link.host, icon: "video", link.url, action: "Join", event: event,
        &actions)
    }
    if let url = event.url, url.scheme == "https", !links.contains(where: { $0.url == url }) {
      linkRows += target(
        "Open \(url.host() ?? "link")", subtitle: "Event link", icon: "link", url, action: "Open",
        event: event, &actions)
    }
    func item(_ detail: [String]) -> String {
      tag + ">\n" + detail.joined(separator: "\n") + "\n</\(kind)>"
    }
    if layout == .agenda {
      return item(detail + linkRows + (event.notes.isEmpty ? [] : ["", plainText(event.notes)]))
    }

    // Week's details share the reply limit with the grid. Reserve room for links before notes.
    let budget = 8_000
    for link in linkRows where quoted(item(detail + [link])).utf8.count <= budget { detail.append(link) }
    if !event.notes.isEmpty {
      let left = budget - quoted(item(detail)).utf8.count - 2
      if let notes = periodNotes(event.notes, budget: left) { detail += ["", notes] }
    }
    return item(detail)
  }

  private func periodNotes(_ notes: String, budget: Int) -> String? {
    let bytes = notes.utf8.count
    func excerpt(_ limit: Int) -> String {
      plainText(prefix(notes, bytes: limit)) + (limit < bytes ? "…" : "")
    }
    var lower = 0
    var upper = min(bytes, noteLimit)
    while lower < upper {
      let middle = (lower + upper + 1) / 2
      if quoted(excerpt(middle)).utf8.count <= budget { lower = middle } else { upper = middle - 1 }
    }
    let text = excerpt(lower)
    return quoted(text).utf8.count <= budget ? text : nil
  }

  /// A row that opens `url`, or, when its tag would be too long for Wicket to read, a view action instead,
  /// named after `event` when the row's own title does not say which event it belongs to.
  private func target(
    _ title: String, subtitle: String, icon: String, _ url: URL, action: String, event: AgendaEvent? = nil,
    _ actions: inout [String]
  ) -> [String] {
    let tag =
      #"<row icon="\#(icon)" title="\#(attribute(title))" subtitle="\#(attribute(subtitle))" open="\#(url.absoluteString)" action="\#(action)"/>"#
    guard tag.utf8.count > (layout == .agenda ? 1024 : 4096) else { return [tag] }
    guard layout == .agenda else { return [] }
    let link = quoted(url.absoluteString)
    if !actions.contains(where: { $0.contains(link) }) {
      actions.append(openAction(event.map { "\(title): \(self.title($0))" } ?? title, url.absoluteString))
    }
    return []
  }

  // MARK: The agent's read

  /// Plain text for the agent: every listed event as an item with a stable ID, its facts and invitation
  /// notes in the detail, and every calendar with its ID, so the agent can edit `hiddenCalendars`. It stays
  /// within `readLimit` bytes: notes are cut at `noteLimit`, and past the limit events keep only ID, title,
  /// time and calendar.
  func read(calendars: [AgendaCalendar], hidden: Set<String>) -> String {
    let end = calendar.date(byAdding: .day, value: agendaDays - 1, to: today)!
    var scope =
      "Now is \(shortDay(now)) \(time(now)) (\(calendar.timeZone.identifier)); listed through \(shortDay(end))"
    if !query.isEmpty { scope += ", matching “\(query)”" }
    if !showAllDay { scope += ", without all-day events (setting showAllDay)" }
    var head = ["# \(events.count == 1 ? "1 event" : "\(events.count) events")", scope + "."]
    if names.isEmpty { head.append("All calendars are hidden (setting hiddenCalendars), so none are read.") }
    if total > events.count { head.append("Only the first \(events.count) of \(total) are listed.") }
    var list = ["", "Calendars (title, ID; hide one by adding its ID to the hiddenCalendars setting):"]
    list += calendars.map { "- \($0.title), \($0.id)" + (hidden.contains($0.id) ? " (hidden)" : "") }
    var cut = 0
    var seen: Set<String> = []
    // Each event's full and short entry.
    let entries = events.map { event in
      var id = event.id
      while !seen.insert(id).inserted { id += "+" }
      let calendarName = names[event.calendarID] ?? ""
      let facts = ["When: \(when(event))", "Calendar: \(calendarName), \(event.calendarID)"]
      func item(_ facts: [String], joins: [String] = []) -> String {
        let subtitle = [when(event), calendarName].joined(separator: " · ")
        // Titles are capped too, so the short entries of a full week always fit.
        return
          #"{"id":\#(quoted(id)),"title":\#(quoted(prefix(title(event), bytes: titleLimit))),"subtitle":\#(quoted(subtitle)),"detail":\#(quoted(tagsAsText(facts.joined(separator: "\n")))),"actions":[\#(joins.joined(separator: ","))]}"#
      }
      let links = meetingLinks(in: event)
      var more = event.location.isEmpty ? [] : ["Location: \(event.location)"]
      more += links.map { "Join (\($0.service)): \($0.url.absoluteString)" }
      if let url = event.url, !links.contains(where: { $0.url == url }) {
        more.append("Link: \(url.absoluteString)")
      }
      if !event.notes.isEmpty {
        let fits = event.notes.utf8.count <= noteLimit
        if !fits { cut += 1 }
        more += ["", "Notes:", fits ? event.notes : prefix(event.notes, bytes: noteLimit) + "… (cut)"]
      }
      return (
        item(facts + more, joins: links.map { openAction("Join \($0.service)", $0.url.absoluteString) }),
        item(facts + ["Place, links and notes left out (size limit)."])
      )
    }
    // Every short entry fits (with room for the lines saying what was cut); full ones in order while they do.
    var left =
      readLimit - quoted(tagsAsText((head + list).joined(separator: "\n"))).utf8.count - 512
      - entries.reduce(0) { $0 + $1.1.utf8.count + 1 }
    var short = 0
    let items = entries.map { full, brief in
      let extra = full.utf8.count - brief.utf8.count
      guard extra <= left else {
        short += 1
        return brief
      }
      left -= extra
      return full
    }
    if cut > 0 { head.append("Notes longer than \(noteLimit) bytes are cut (\(cut) events).") }
    if short > 0 {
      head.append(
        "\(short) events are listed without place, links and notes to stay within the output limit; "
          + "search with --input to read them.")
    }
    return
      #"{"body":\#(quoted(tagsAsText((head + list).joined(separator: "\n")))),"items":[\#(items.joined(separator: ","))]}"#
  }

  // MARK: Words

  private func title(_ event: AgendaEvent) -> String {
    let title = event.title.trimmingCharacters(in: .whitespacesAndNewlines)
    return title.isEmpty ? "Untitled" : title
  }

  private func place(_ event: AgendaEvent) -> String {
    event.location.split(whereSeparator: \.isWhitespace).filter { word in
      let scheme = URL(string: String(word))?.scheme?.lowercased()
      return scheme != "http" && scheme != "https"
    }.joined(separator: " ")
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
    event.end <= calendar.dateInterval(of: .day, for: event.start)!.end
  }
  private func span(_ event: AgendaEvent) -> String {
    if event.end <= event.start { return time(event.start) }
    let zone = calendar.timeZone
    let startOffset = zone.secondsFromGMT(for: event.start)
    let endOffset = zone.secondsFromGMT(for: event.end)
    let showOffset = layout != .agenda && startOffset != endOffset
    func endpoint(_ date: Date, offset: Int) -> String {
      let sign = offset < 0 ? "−" : "+"
      return time(date) + (showOffset ? " UTC\(sign)\(clock(abs(offset) / 60))" : "")
    }
    let start = endpoint(event.start, offset: startOffset)
    let end = endpoint(event.end, offset: endOffset)
    return endsSameDay(event) ? "\(start)–\(end)" : "\(start) – \(shortDay(event.end)) \(end)"
  }

  /// A row's time: all day, its start, or its end when it began before the day it is listed under.
  private func label(_ event: AgendaEvent) -> String {
    let day = day(event)
    if event.isAllDay { return "All day" }
    guard event.start < day else { return time(event.start) }
    let sameDay = event.end <= calendar.date(byAdding: .day, value: 1, to: day)!
    return "Until " + (sameDay ? time(event.end) : shortDay(event.end))
  }

  /// The local interval: date and times, or the days an all-day event covers.
  private func when(_ event: AgendaEvent) -> String {
    guard event.isAllDay else { return "\(shortDay(event.start)), \(span(event))" }
    let first = calendar.startOfDay(for: event.start)
    // EventKit ends an all-day event a second before midnight; other stores end it at midnight.
    let last = max(first, calendar.startOfDay(for: event.end.addingTimeInterval(-1)))
    return first == last ? "\(shortDay(first)), all day" : "\(shortDay(first)) – \(shortDay(last))"
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
private func rowView(
  _ id: String, _ title: String, _ subtitle: String, icon: String, action: String?,
  layout: CalendarLayout? = nil
) -> String {
  let control =
    layout.map {
      #""body":\#(quoted(CalendarLayout.marker)),"fields":[\#($0.control(label: "Next 7 days"))],"actions":[\#(action ?? "")],"#
    } ?? ""
  return
    #"{\#(control)"items":[{"id":"\#(id)","title":\#(quoted(title)),"subtitle":\#(quoted(subtitle)),"icon":"\#(icon)","actions":[\#(action ?? "")]}]}"#
}

private func property(_ label: String, _ value: String) -> String {
  #"<row label="\#(label)" value="\#(attribute(value))"/>"#
}

/// Invitation text as a tag attribute: one line without double quotes, short enough that the whole tag
/// stays well within the 4,096 bytes Wicket reads.
private func attribute(_ text: String, limit: Int = 300) -> String {
  let line = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    .replacingOccurrences(of: "\"", with: "”")
  return line.utf8.count > limit ? prefix(line, bytes: limit - 3) + "…" : line
}

/// The longest start of `text` within `bytes` UTF-8 bytes, in whole characters.
private func prefix(_ text: String, bytes: Int) -> String {
  var cut = ""
  for character in text {
    if cut.utf8.count + character.utf8.count > bytes { break }
    cut.append(character)
  }
  return cut
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
