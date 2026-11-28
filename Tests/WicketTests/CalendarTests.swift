import Foundation
import Testing

@testable import WicketApp
@testable import calendar

// The bundled Calendar extension on a recorded week (`Fixtures/calendar-week.json`): nothing here reads
// EventKit or asks for access.

/// The recorded week: Monday 30 November 2026, 13:55 in Berlin, in the middle of a Zoom call.
struct CalendarWeek: Decodable {
  let now: Date
  let timeZone: String
  let calendars: [Source]
  let events: [Event]
  struct Source: Decodable {
    let id: String
    let title: String
  }
  struct Event: Decodable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let calendar: String
    var allDay: Bool?
    var location: String?
    var notes: String?
    var url: String?
    var cancelled: Bool?
    var declined: Bool?
  }

  static func recorded() throws -> CalendarWeek {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try decoder.decode(CalendarWeek.self, from: Data(contentsOf: fixtureURL("calendar-week.json")))
  }

  var snapshot: Snapshot {
    .loaded(
      calendars: calendars.map { AgendaCalendar(id: $0.id, title: $0.title) },
      events: events.map { event in
        AgendaEvent(
          id: event.id, title: event.title, start: event.start, end: event.end,
          isAllDay: event.allDay ?? false,
          calendarID: event.calendar, location: event.location ?? "", notes: event.notes ?? "",
          url: event.url.flatMap(URL.init(string:)), cancelled: event.cancelled ?? false,
          declined: event.declined ?? false)
      })
  }

  /// The view the extension prints for this week, `minutes` after the recorded moment.
  func view(
    minutes: Double = 0, query: String = "", view: String? = nil,
    settings: [String: String] = [:], action: String? = nil,
    snapshot: Snapshot? = nil
  ) throws -> ProviderView {
    let output = try output(
      minutes: minutes, query: query, view: view, settings: settings, action: action, snapshot: snapshot)
    return try JSONDecoder().decode(ProviderView.self, from: Data(output.utf8))
  }

  /// What the extension prints, as printed.
  func output(
    minutes: Double = 0, query: String = "", view: String? = nil,
    settings: [String: String] = [:], action: String? = nil,
    snapshot: Snapshot? = nil
  ) throws -> String {
    var fields = query.isEmpty ? [:] : ["query": query]
    fields["view"] = view
    var request = ProviderRequest(input: query, fields: fields, action: action, submitted: action != nil)
    request.settings = settings.mapValues(JSONValue.string)
    let bytes = try Array(JSONEncoder().encode(request))
    var position = 0
    var local = Calendar(identifier: .gregorian)
    local.timeZone = try #require(TimeZone(identifier: timeZone))
    local.locale = Locale(identifier: "en_GB")
    local.firstWeekday = 2
    return try calendarView(
      calendar.JSON.read(bytes, &position), snapshot: snapshot ?? self.snapshot,
      now: now.addingTimeInterval(minutes * 60), calendar: local)
  }
}

private let agendaStart = CalendarLayout.marker + "\n\n"

private func page(_ view: ProviderView) throws -> Page { Page(body: try #require(view.body), runs: true) }
private func opened(_ action: RowAction?) -> URL? {
  if case .open(let url)? = action?.kind { url } else { nil }
}
/// What Return opens on a body row: its detail.
private func detailOf(_ row: Row?) -> String? {
  if case .detail(let markdown, _)? = row?.actions.first?.kind { markdown } else { nil }
}

@Test func calendarLeadsWithTheLiveCallAndReturnJoinsIt() throws {
  let view = try CalendarWeek.recorded().view()
  let body = try #require(view.body)
  #expect(view.pageControls().first?.label == "Now: Design review until 14:30 · Zoom")
  #expect(body.hasPrefix(agendaStart + "\n### Today\n"))
  // With nothing selected Return runs the first view action.
  let zoom = "https://acme.zoom.us/j/81234567890?pwd=Xy7"
  #expect(
    view.actions.first?.title == "Join Design review" && opened(view.actions.first)?.absoluteString == zoom)
  #expect(view.actions.last?.title == "Open Calendar")

  let targets = try page(view).targets
  #expect(
    targets.map(\.title) == [
      "Design review", "Focus time", "Team offsite", "1:1 with Sam", "Dentist",
      "Quarterly planning",
      "Climbing", "Ada’s birthday",
    ])
  for heading in ["### Today", "### Tomorrow", "### Wednesday 2 December", "### Friday 4 December"] {
    #expect(body.contains(heading))
  }
  #expect(body.contains(#"<row label="13:30" title="Design review" subtitle="Zoom" value="Now">"#))
  #expect(body.contains(#"<row label="All day" title="Team offsite" subtitle="Spreewald">"#))
  // Elapsed, cancelled, declined and next week's events stay out.
  for gone in ["Morning standup", "Old plan", "Vendor pitch", "Next week"] { #expect(!body.contains(gone)) }
}

@Test func calendarJoinIsReturnOnlyWithinTenMinutes() throws {
  let week = try CalendarWeek.recorded()
  let early = try week.view(minutes: -40)
  #expect(early.pageControls().first?.label == "Next: Design review at 13:30")
  #expect(try page(early).targets.first?.title == "Design review")
  #expect(early.actions.map(\.title) == ["Open Calendar"])
  let soon = try week.view(minutes: -34)
  #expect(soon.pageControls().first?.label == "Next: Design review at 13:30")
  #expect(soon.actions.first?.title == "Join Design review")
  // After the call, the next event leads, without a link to join.
  let later = try week.view(minutes: 40)
  #expect(later.pageControls().first?.label == "Next: Focus time at 15:00")
  #expect(later.actions.map(\.title) == ["Open Calendar"])
  // After the last event of the day: the rest of today is empty, and the next meeting is tomorrow.
  let evening = try week.view(minutes: 4 * 60)
  let body = try #require(evening.body)
  #expect(evening.pageControls().first?.label == "Next: 1:1 with Sam tomorrow 10:00")
  #expect(body.contains("### Today\nNothing else today\n\n### Tomorrow"))
  #expect(try page(evening).targets.first?.title == "Team offsite")
}

@Test func calendarSummarizesOverlappingCallsAndKeepsTheirRows() throws {
  let week = try CalendarWeek.recorded()
  guard case .loaded(let calendars, var events) = week.snapshot else { return }
  events.append(
    AgendaEvent(
      id: "vendor", title: "Vendor sync", start: week.now.addingTimeInterval(5 * 60),
      end: week.now.addingTimeInterval(35 * 60), calendarID: "work",
      notes: "Click https://teams.microsoft.com/meet/123456?p=abc to join"))
  let view = try week.view(snapshot: .loaded(calendars: calendars, events: events))
  #expect(view.pageControls().first?.label == "Now: 2 overlapping calls")
  let targets = try page(view).targets
  #expect(targets.prefix(2).map(\.title) == ["Design review", "Vendor sync"])
  #expect(targets[1].subtitle == "Microsoft Teams")
  #expect(view.actions.first?.title == "Join Design review")
}

@Test func calendarDetailsKeepInvitationTextInertAndOfferEveryLink() throws {
  let targets = try page(try CalendarWeek.recorded().view()).targets
  let review = try #require(targets.first { $0.title == "Design review" })
  let detail = try #require(detailOf(review))
  #expect(detail.contains(#"<row label="When" value="Mon 30 Nov, 13:30–14:30"/>"#))
  #expect(detail.contains(#"<row label="Calendar" value="Work"/>"#))
  // The location is the call's link, so it shows as Join rather than as a place.
  #expect(!detail.contains(#"label="Location""#))
  let inner = Page(body: detail, runs: true)
  #expect(inner.targets.map(\.title) == ["Join Zoom"])
  let blocks = PageDocument(inner, turn: "t", streaming: false).blocks
  #expect(blocks.flatMap(\.inlineLinks).isEmpty)
  #expect(blocks.map(\.renderedText).joined().contains("Agenda:\n"))
  #expect(blocks.map(\.renderedText).joined().contains("<row title"))

  let planning = try #require(targets.first { $0.title == "Quarterly planning" })
  let links = Page(body: try #require(detailOf(planning)), runs: true).targets
  #expect(links.map(\.title) == ["Join Microsoft Teams", "Join Zoom"])
  #expect(opened(links[1].actions.first)?.absoluteString == "https://zoom.us/j/222333444")
  #expect(detailOf(planning)?.contains(#"<row label="Location" value="Room 2"/>"#) == true)
}

@Test func calendarMovesLinksTooLongForATagIntoActionsAfterTheDefault() throws {
  let week = try CalendarWeek.recorded()
  let long = "https://teams.microsoft.com/l/meetup-join/" + String(repeating: "a", count: 1100)
  let call = AgendaEvent(
    id: "long", title: "Board call", start: week.now.addingTimeInterval(3600),
    end: week.now.addingTimeInterval(7200), calendarID: "work", location: long)
  let work = [AgendaCalendar(id: "work", title: "Work")]
  // An hour ahead, Return still opens Calendar; the link follows it.
  let view = try week.view(snapshot: .loaded(calendars: work, events: [call]))
  #expect(try page(view).targets.map(\.title) == ["Board call"])
  #expect(view.actions.map(\.title) == ["Open Calendar", "Join Microsoft Teams: Board call"])
  #expect(opened(view.actions.last)?.absoluteString == long)
  // Five minutes ahead, Return joins it, once.
  let soon = try week.view(minutes: 55, snapshot: .loaded(calendars: work, events: [call]))
  #expect(soon.actions.map(\.title) == ["Join Board call", "Open Calendar"])
  #expect(opened(soon.actions.first)?.absoluteString == long)
}

@Test func calendarListsAnOvernightEventUntilItsEnd() throws {
  let week = try CalendarWeek.recorded()
  let flight = AgendaEvent(
    id: "flight", title: "Night flight", start: week.now.addingTimeInterval(-15 * 3600),
    end: week.now.addingTimeInterval(-6 * 3600 - 55 * 60), calendarID: "work")
  // At 05:00 the flight that left at 22:55 yesterday lists under today until 07:00.
  let view = try week.view(
    minutes: -8 * 60 - 55,
    snapshot: .loaded(calendars: [AgendaCalendar(id: "work", title: "Work")], events: [flight]))
  #expect(view.body?.contains(#"<row label="Until 07:00" title="Night flight" value="Now">"#) == true)
}

@Test func calendarRecognizesOnlyJoinPagesOfKnownServices() {
  let accepted = [
    ("https://meet.google.com/abc-defg-hij", "Google Meet"),
    ("https://meet.google.com/ABC-defg-hij?authuser=1", "Google Meet"),
    ("https://meet.google.com/lookup/b6xyz7abcd", "Google Meet"),
    ("https://meet.google.com/lookup/quick-sync", "Google Meet"),
    ("https://us02web.zoom.us/j/8123?pwd=x", "Zoom"),
    ("https://zoom.us/my/ada).", "Zoom"),
    (
      "https://teams.microsoft.com/l/meetup-join/19%3ameeting%40thread.v2/0?context=%7b%7d", "Microsoft Teams"
    ),
    ("https://teams.live.com/meet/9876", "Microsoft Teams"),
    ("https://acme.webex.com/acme/j.php?MTID=m1", "Webex"),
    ("https://acme.webex.com/meet/ada", "Webex"),
  ]
  for (text, service) in accepted { #expect(meetingLink(text)?.service == service, "\(text)") }
  let refused = [
    "http://zoom.us/j/1", "https://zoom.us.evil.example/j/1", "https://zoom.us@evil.example/j/1",
    "https://evilzoom.us/j/1", "https://zoom.us/pricing", "https://meet.google.com/",
    "https://meet.google.com/landing", "https://meet.google.com/new",
    "https://meet.google.com/abc-defg-hij/x",
    "https://zoom.us:8443/j/1",
    "https://teams.microsoft.com/v2/", "https://webex.com.evil.example/meet/x",
  ]
  for text in refused { #expect(meetingLink(text) == nil, "\(text)") }
}

@Test func calendarSearchesTitlesPlacesAndCalendars() throws {
  let week = try CalendarWeek.recorded()
  let home = try week.view(query: "home")
  #expect(home.pageControls().first?.label == "2 events matching “home”")
  #expect(try page(home).targets.map(\.title) == ["Dentist", "Climbing"])
  #expect(try page(week.view(query: "torstrasse")).targets.map(\.title) == ["Dentist"])
  let none = try week.view(query: "xyz")
  #expect(none.body == CalendarLayout.marker && none.items.map(\.id) == ["no-matches"])
  #expect(none.items.first?.title == "No events match “xyz”")
}

@Test func calendarSettingsHideCalendarsAndAllDayEvents() throws {
  let week = try CalendarWeek.recorded()
  let titles = try page(week.view(settings: ["hiddenCalendars": "birthdays, home", "showAllDay": "false"]))
    .targets.map(\.title)
  #expect(titles == ["Design review", "Focus time", "1:1 with Sam", "Quarterly planning"])
  let hidden = try week.view(settings: ["hiddenCalendars": "work,home,birthdays"])
  #expect(hidden.items.map(\.id) == ["all-hidden"])
}

@Test func calendarSaysWhyNothingIsListed() throws {
  let week = try CalendarWeek.recorded()
  let denied = try week.view(snapshot: .denied)
  #expect(denied.items.map(\.id) == ["denied"] && denied.items.first?.title == "Allow Calendar for Wicket")
  #expect(opened(denied.items.first?.actions.first)?.scheme == "x-apple.systempreferences")
  let none = try week.view(snapshot: .loaded(calendars: [], events: []))
  #expect(none.items.map(\.id) == ["no-calendars"])
  // The agent's read lists no setup rows as events, and fails without access.
  let noneRead = try week.view(action: "read-agenda", snapshot: .loaded(calendars: [], events: []))
  #expect(noneRead.items.isEmpty && noneRead.body?.hasPrefix("No calendars on this Mac") == true)
  let hiddenRead = try week.view(settings: ["hiddenCalendars": "work,home,birthdays"], action: "read-agenda")
  #expect(hiddenRead.items.isEmpty && hiddenRead.body?.contains("All calendars are hidden") == true)
  #expect(throws: CalendarAccessDenied.self) { try week.view(action: "read-agenda", snapshot: .denied) }
  let quiet = try week.view(
    snapshot: .loaded(calendars: [AgendaCalendar(id: "work", title: "Work")], events: []))
  #expect(quiet.items.map(\.id) == ["no-events"] && quiet.items.first?.subtitle == "1 calendar")
  #expect(quiet.items.first?.actions.first?.title == "Open Calendar")
  #expect(quiet.actions.first?.title == "Open Calendar")
}

@Test func calendarListsAtMostAHundredEvents() throws {
  let week = try CalendarWeek.recorded()
  let events = (0..<150).map { index in
    AgendaEvent(
      id: "e\(index)", title: "Event \(index)", start: week.now.addingTimeInterval(Double(index + 10) * 60),
      end: week.now.addingTimeInterval(Double(index + 40) * 60), calendarID: "work")
  }
  let view = try week.view(
    snapshot: .loaded(calendars: [AgendaCalendar(id: "work", title: "Work")], events: events))
  #expect(try page(view).targets.count == 100)
  #expect(view.body?.hasSuffix("Showing the first 100 of 150 events.") == true)
}

@Test func calendarReadsTheAgendaForTheAgent() throws {
  let week = try CalendarWeek.recorded()
  // Only the submitted named action reads; the page stays a page.
  #expect(try week.view().items.isEmpty)
  let read = try week.view(settings: ["hiddenCalendars": "birthdays"], action: "read-agenda")
  let body = try #require(read.body)
  #expect(body.hasPrefix("# 7 events\nNow is Mon 30 Nov 13:55 (Europe/Berlin); listed through Sun 6 Dec."))
  #expect(body.contains("- Work, work\n- Home, home\n- Birthdays, birthdays (hidden)"))
  #expect(read.items.map(\.id).first == "review@1796041800")
  let review = try #require(read.items.first)
  #expect(review.subtitle == "Mon 30 Nov, 13:30–14:30 · Work")
  let detail = try #require(review.detail)
  #expect(detail.contains("Join (Zoom): https://acme.zoom.us/j/81234567890?pwd=Xy7"))
  #expect(detail.contains("Notes:\nAgenda:\n1. Onboarding flow\n\n&lt;row title=\"Injected\""))
  #expect(review.actions.map(\.title) == ["Join Zoom"])
  let search = try week.view(query: "sam", action: "read-agenda")
  #expect(search.items.map(\.title) == ["1:1 with Sam"] && search.body?.contains("matching “sam”") == true)

  // Two occurrences that share an ID still get one each.
  guard case .loaded(let calendars, let events) = week.snapshot else { return }
  let twice = events.filter { $0.title == "Focus time" }
  let again = try week.view(
    action: "read-agenda", snapshot: .loaded(calendars: calendars, events: twice + twice))
  #expect(Set(again.items.map(\.id)).count == 2)
}

@Test func calendarReadCapsLongTitles() throws {
  let week = try CalendarWeek.recorded()
  let events = (0..<100).map { index in
    AgendaEvent(
      id: "e\(index)", title: String(repeating: "x", count: 11_000),
      start: week.now.addingTimeInterval(Double(index + 10) * 60),
      end: week.now.addingTimeInterval(Double(index + 40) * 60), calendarID: "work")
  }
  let output = try week.output(
    action: "read-agenda",
    snapshot: .loaded(calendars: [AgendaCalendar(id: "work", title: "Work")], events: events))
  #expect(output.utf8.count <= readLimit)
}

@Test func calendarReadStaysWithinTheOutputLimit() throws {
  let week = try CalendarWeek.recorded()
  // Each note grows fivefold as text (`&amp;`), so whole notes for 100 events would be about 2 MB.
  let events = (0..<100).map { index in
    AgendaEvent(
      id: "e\(index)", title: "Event \(index)", start: week.now.addingTimeInterval(Double(index + 10) * 60),
      end: week.now.addingTimeInterval(Double(index + 40) * 60), calendarID: "work",
      notes: "https://zoom.us/j/\(index) " + String(repeating: "&", count: 10_000))
  }
  let output = try week.output(
    action: "read-agenda",
    snapshot: .loaded(calendars: [AgendaCalendar(id: "work", title: "Work")], events: events))
  #expect(output.utf8.count <= readLimit)
  let read = try JSONDecoder().decode(ProviderView.self, from: Data(output.utf8))
  #expect(read.items.map(\.title) == events.map(\.title))
  let first = try #require(read.items.first?.detail)
  #expect(first.contains("Join (Zoom): https://zoom.us/j/0") && first.hasSuffix("… (cut)"))
  let last = try #require(read.items.last?.detail)
  #expect(
    last.hasPrefix("When: Mon 30 Nov") && last.hasSuffix("Place, links and notes left out (size limit)."))
  #expect(read.items.last?.actions.isEmpty == true)
  let body = try #require(read.body)
  #expect(body.contains("Notes longer than 4000 bytes are cut (100 events)."))
  #expect(body.contains("events are listed without place, links and notes"))
}

@Test func calendarEventIDsSurviveReschedulingAndTimeZoneChanges() throws {
  func local(_ zone: String) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: zone))
    return calendar
  }
  let (berlin, tokyo) = (try local("Europe/Berlin"), try local("Asia/Tokyo"))
  let instant = try Date("2026-12-01T10:00:00+01:00", strategy: .iso8601)
  // A one-off keeps its identifier wherever it moves.
  #expect(eventID("one", occurrence: nil, allDay: false, floating: false, calendar: berlin) == "one")
  // A fixed-time repeat is keyed by its original instant, whatever the zone.
  #expect(
    eventID("rep", occurrence: instant, allDay: false, floating: false, calendar: tokyo) == "rep@1796115600")
  // Floating and all-day repeats are keyed by local wall time, which follows the Mac's zone.
  let tokyoTen = try Date("2026-12-01T10:00:00+09:00", strategy: .iso8601)
  #expect(
    eventID("f", occurrence: instant, allDay: false, floating: true, calendar: berlin)
      == eventID("f", occurrence: tokyoTen, allDay: false, floating: true, calendar: tokyo))
  #expect(
    eventID("f", occurrence: instant, allDay: false, floating: true, calendar: berlin) == "f@2026-12-01T10:00"
  )
  #expect(eventID("d", occurrence: tokyoTen, allDay: true, floating: true, calendar: tokyo) == "d@2026-12-01")
}

/// Root typing never starts Calendar's program: it has no pattern, so only Return or a link runs it.
@MainActor @Test func calendarRootItemsAndCanvasSwitchThroughTheCommand() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "Sources/Extensions/calendar/wicket.json")
  var manifest = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
  #expect(manifest["match"] == nil && manifest["fallback"] == nil)
  manifest["command"] = ["/bin/sh", "main.sh"]
  let folder = try extensionFolder(
    root, name: "calendar",
    script: #"""
      cat > request.json
      case "$(cat request.json)" in
        *'"view":"week"'*) cat week.json ;;
        *) cat agenda.json ;;
      esac
      """#, fields: manifest)
  let fixture = try CalendarWeek.recorded()
  for layout in CalendarLayout.allCases {
    let output = try fixture.output(view: layout.rawValue)
    try Data(output.utf8).write(to: folder.appending(path: "\(layout.rawValue).json"))
  }
  let requestFile = folder.appending(path: "request.json")
  func request() throws -> ProviderRequest {
    try JSONDecoder().decode(ProviderRequest.self, from: Data(contentsOf: requestFile))
  }
  let model = LauncherModel.testing(in: root)
  model.extensions.permissions = Permissions(status: { _ in .granted }, request: { _ in })
  await model.extensions.reload()
  for input in ["cal", "calendar", "calendar standup"] {
    model.navigator.input = input
    await model.navigator.settled()
    #expect(model.navigator.results.contains { $0.provider == "extension:calendar" })
  }
  #expect(!FileManager.default.fileExists(atPath: requestFile.path))

  let navigator = model.navigator
  navigator.input = "Calendar Week"
  await navigator.settled()
  let week = try #require(navigator.results.first { $0.row.title == "Calendar Week" })
  navigator.select(week.id)
  #expect(model.activateReturn())
  await navigator.settled()
  #expect(try request().fields["view"] == "week")
  #expect(try request().submitted)
  #expect(navigator.body?.contains("<timeline") == true)

  #expect(navigator.escape())
  await navigator.settled()
  #expect(navigator.body?.contains("### Tomorrow") == true)
  model.press(try #require(HotkeyTarget("wicket://calendar?item=week")))
  await navigator.settled()
  #expect(try request().fields["view"] == "week")
  #expect(try request().submitted)
  #expect(navigator.body?.contains("<timeline") == true)
  let event = try #require(navigator.results.first { $0.row.title == "Design review" })
  navigator.select(event.id)
  #expect(model.activateReturn())
  #expect(navigator.inDetail)
  #expect(navigator.escape())
  #expect(navigator.body?.contains("<timeline") == true)

  navigator.input = "studio"
  await navigator.settled()
  navigator.changeField(.init(name: "view", value: "agenda", phase: .commit), turn: navigator.pageTurn)
  await navigator.settled()
  #expect(try request().fields == ["view": "agenda", "query": "studio"])
  #expect(try !request().submitted)
  #expect(navigator.body?.contains("### Tomorrow") == true)
  await model.finish()
}

@Test func calendarWeekIncludesPastEventsAndKeepsTheAgendaRead() throws {
  let fixture = try CalendarWeek.recorded()
  let week = try fixture.view(view: "week")
  let body = try #require(week.body)
  let control = try #require(week.pageControls().first)
  guard case .choice(let options) = control.control else {
    Issue.record("Expected a view choice")
    return
  }
  #expect(options.map(\.value) == ["agenda", "week"])
  #expect(control.value == "week" && control.label == "30 Nov – 6 Dec 2026")
  #expect(week.back == ["view": "agenda"])
  #expect(body.contains(#"lanes="Mon 30,Tue 1,Wed 2,Thu 3,Fri 4,Sat 5,Sun 6" now="13:55" now-lane="Mon 30""#))
  #expect(body.contains(#"lane="Mon 30" from="09:00" to="12:30""#))
  #expect(
    !body.contains("Team offsite") && !body.contains("Ada’s birthday") && body.contains("Morning standup"))
  #expect(!body.contains("Next week"))
  #expect(!body.contains("Vendor pitch") && !body.contains("Old plan"))
  let filtered = try fixture.view(query: "boulderhalle", view: "week")
  #expect(try page(filtered).targets.map(\.title) == ["Climbing"])
  let read = try fixture.view(view: "week", action: "read-agenda")
  #expect(read == (try fixture.view(action: "read-agenda")))
}

@Test func calendarUsesCivilDayBoundariesAfterAMidnightClockChange() throws {
  let start = try Date("2026-04-25T00:30:00+03:00", strategy: .iso8601)
  let meeting = AgendaEvent(
    id: "early", title: "Early meeting", start: start, end: start.addingTimeInterval(1800), calendarID: "work"
  )
  let fixture = CalendarWeek(now: start, timeZone: "Africa/Cairo", calendars: [], events: [])
  let snapshot = Snapshot.loaded(calendars: [AgendaCalendar(id: "work", title: "Work")], events: [meeting])
  let week = try fixture.view(view: "week", snapshot: snapshot)
  #expect(try page(week).targets.map(\.title) == ["Early meeting"])
  #expect(week.body?.contains(#"lane="Sat 25" from="00:30" to="01:00""#) == true)
}

@Test func calendarWeekPreservesDurationAcrossTheRepeatedHour() throws {
  let start = try Date("2026-10-25T02:45:00+02:00", strategy: .iso8601)
  let end = try Date("2026-10-25T02:15:00+01:00", strategy: .iso8601)
  let late = try Date("2026-10-25T23:30:00+01:00", strategy: .iso8601)
  let meetings = [
    AgendaEvent(id: "overnight", title: "Night shift", start: start, end: end, calendarID: "work"),
    AgendaEvent(
      id: "late", title: "Wrap", start: late, end: late.addingTimeInterval(1800), calendarID: "work"),
  ]
  let fixture = CalendarWeek(now: start, timeZone: "Europe/Berlin", calendars: [], events: [])
  let snapshot = Snapshot.loaded(calendars: [AgendaCalendar(id: "work", title: "Work")], events: meetings)
  let week = try page(fixture.view(view: "week", snapshot: snapshot))
  let blocks = PageDocument(week, turn: "week", streaming: false).blocks
  guard case .timeline(let timeline)? = blocks.last else {
    Issue.record("Expected a timeline")
    return
  }
  #expect(timeline.spans.map(\.from) == [165, 1470])
  #expect(timeline.spans.map(\.to) == [195, 1500])
  #expect(detailOf(week.targets.first)?.contains("02:45 UTC+02:00–02:15 UTC+01:00") == true)
}

@Test func calendarWeekReservesRoomForJoinBeforeTruncatingNotes() throws {
  let fixture = try CalendarWeek.recorded()
  let link = try #require(URL(string: "https://meet.google.com/abc-defg-hij"))
  let event = AgendaEvent(
    id: "long-notes", title: "Planning", start: fixture.now, end: fixture.now.addingTimeInterval(1800),
    calendarID: "work", notes: "Plan & test. " + String(repeating: "&", count: 1_900) + "Last paragraph.",
    url: link)
  let snapshot = Snapshot.loaded(calendars: [AgendaCalendar(id: "work", title: "Work")], events: [event])
  let week = try page(fixture.view(view: "week", snapshot: snapshot))
  let eventDetail = try #require(detailOf(week.targets.first))
  #expect(eventDetail.contains("Plan &#38; test&#46;"))
  #expect(eventDetail.hasSuffix("…") && !eventDetail.contains("Last paragraph"))
  let actions = Page(body: eventDetail, runs: true).targets
  #expect(actions.map(\.title) == ["Join Google Meet"])
  #expect(opened(actions.first?.actions.first) == link)
}
