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
    minutes: Double = 0, query: String = "", settings: [String: String] = [:], action: String? = nil,
    snapshot: Snapshot? = nil
  ) throws -> ProviderView {
    var request = ProviderRequest(
      input: query, fields: query.isEmpty ? [:] : ["query": query], action: action, submitted: action != nil)
    request.settings = settings.mapValues(JSONValue.string)
    let bytes = try Array(JSONEncoder().encode(request))
    var position = 0
    var local = Calendar(identifier: .gregorian)
    local.timeZone = try #require(TimeZone(identifier: timeZone))
    local.locale = Locale(identifier: "en_GB")
    let output = calendarView(
      calendar.JSON.read(bytes, &position), snapshot: snapshot ?? self.snapshot,
      now: now.addingTimeInterval(minutes * 60), calendar: local)
    return try JSONDecoder().decode(ProviderView.self, from: Data(output.utf8))
  }
}

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
  #expect(body.hasPrefix("# Design review\nNow until 14:30 · Zoom\n"))
  // With nothing selected Return runs the first view action.
  let zoom = "https://acme.zoom.us/j/81234567890?pwd=Xy7"
  #expect(
    view.actions.first?.title == "Join Design review" && opened(view.actions.first)?.absoluteString == zoom)
  #expect(view.actions.last?.title == "Open Calendar")

  let targets = try page(view).targets
  #expect(
    targets.map(\.title) == [
      "Join Zoom", "Design review", "Focus time", "Team offsite", "1:1 with Sam", "Dentist",
      "Quarterly planning",
      "Climbing", "Ada’s birthday",
    ])
  #expect(targets[0].subtitle == "acme.zoom.us" && opened(targets[0].actions.first)?.absoluteString == zoom)
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
  #expect(early.body?.hasPrefix("# Design review\nIn 15 min · 13:30–14:30 · Zoom\n") == true)
  #expect(try page(early).targets.first?.title == "Join Zoom")
  #expect(early.actions.map(\.title) == ["Open Calendar"])
  let soon = try week.view(minutes: -34)
  #expect(soon.body?.contains("In 9 min") == true && soon.actions.first?.title == "Join Design review")
  // After the call, the next event leads, without a link to join.
  let later = try week.view(minutes: 40)
  #expect(later.body?.hasPrefix("# Focus time\nIn 25 min · 15:00–17:00\n") == true)
  #expect(later.actions.map(\.title) == ["Open Calendar"])
  // After the last event of the day: the rest of today is empty, and the next meeting is tomorrow.
  let evening = try week.view(minutes: 4 * 60)
  let body = try #require(evening.body)
  #expect(body.hasPrefix("# 1&#58;1 with Sam\nTomorrow 10:00–10:30 · Google Meet\n"))
  #expect(body.contains("### Today\nNothing else today\n\n### Tomorrow"))
  #expect(try page(evening).targets.first?.title == "Join Google Meet")
}

@Test func calendarListsOverlappingCallsEachWithItsTitle() throws {
  let week = try CalendarWeek.recorded()
  guard case .loaded(let calendars, var events) = week.snapshot else { return }
  events.append(
    AgendaEvent(
      id: "vendor", title: "Vendor sync", start: week.now.addingTimeInterval(5 * 60),
      end: week.now.addingTimeInterval(35 * 60), calendarID: "work",
      notes: "Click https://teams.microsoft.com/meet/123456?p=abc to join"))
  let view = try week.view(snapshot: .loaded(calendars: calendars, events: events))
  #expect(view.body?.hasPrefix("# 2 calls now\nOverlapping calls\n") == true)
  let targets = try page(view).targets
  #expect(targets.prefix(2).map(\.title) == ["Design review", "Vendor sync"])
  #expect(targets[1].subtitle == "Microsoft Teams · In 5 min · 14:00–14:30")
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
  let html = AnswerMarkdown.html(inner.source)
  #expect(!html.contains("evil.example\"") && !html.contains("<a "))
  #expect(html.contains("Agenda:<br />") && html.contains("&lt;row title"))

  let planning = try #require(targets.first { $0.title == "Quarterly planning" })
  let links = Page(body: try #require(detailOf(planning)), runs: true).targets
  #expect(links.map(\.title) == ["Join Microsoft Teams", "Join Zoom"])
  #expect(opened(links[1].actions.first)?.absoluteString == "https://zoom.us/j/222333444")
  #expect(detailOf(planning)?.contains(#"<row label="Location" value="Room 2"/>"#) == true)
}

@Test func calendarMovesLinksTooLongForATagIntoActions() throws {
  let week = try CalendarWeek.recorded()
  let long = "https://teams.microsoft.com/l/meetup-join/" + String(repeating: "a", count: 1100)
  let call = AgendaEvent(
    id: "long", title: "Board call", start: week.now.addingTimeInterval(3600),
    end: week.now.addingTimeInterval(7200), calendarID: "work", location: long)
  let view = try week.view(
    snapshot: .loaded(calendars: [AgendaCalendar(id: "work", title: "Work")], events: [call]))
  #expect(try page(view).targets.map(\.title) == ["Board call"])
  #expect(view.actions.map(\.title) == ["Join Microsoft Teams", "Open Calendar"])
  #expect(opened(view.actions.first)?.absoluteString == long)
}

@Test func calendarRecognizesOnlyJoinPagesOfKnownServices() {
  let accepted = [
    ("https://meet.google.com/abc-defg-hij", "Google Meet"),
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
    "https://zoom.us:8443/j/1",
    "https://teams.microsoft.com/v2/", "https://webex.com.evil.example/meet/x",
  ]
  for text in refused { #expect(meetingLink(text) == nil, "\(text)") }
}

@Test func calendarSearchesTitlesPlacesAndCalendars() throws {
  let week = try CalendarWeek.recorded()
  let home = try week.view(query: "home")
  #expect(home.body?.hasPrefix("# 2 events\nMatching “home” in the next 7 days") == true)
  #expect(try page(home).targets.map(\.title) == ["Dentist", "Climbing"])
  #expect(try page(week.view(query: "torstrasse")).targets.map(\.title) == ["Dentist"])
  let none = try week.view(query: "xyz")
  #expect(none.body == nil && none.items.map(\.id) == ["no-matches"])
  #expect(none.items.first?.title == "No events match “xyz”")
}

@Test func calendarSettingsHideCalendarsAndAllDayEvents() throws {
  let week = try CalendarWeek.recorded()
  let titles = try page(week.view(settings: ["hiddenCalendars": "birthdays, home", "showAllDay": "false"]))
    .targets.map(\.title)
  #expect(titles == ["Join Zoom", "Design review", "Focus time", "1:1 with Sam", "Quarterly planning"])
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
  let quiet = try week.view(
    snapshot: .loaded(calendars: [AgendaCalendar(id: "work", title: "Work")], events: []))
  #expect(quiet.items.map(\.id) == ["no-events"] && quiet.items.first?.subtitle == "1 calendar")
  #expect(quiet.items.first?.actions.first?.title == "Open Calendar")
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

/// Root typing never starts Calendar's program: it has no pattern, so only Return or a link runs it.
@MainActor @Test func calendarStartsNoProcessWhileTyping() async throws {
  let root = try scratch()
  defer { try? FileManager.default.removeItem(at: root) }
  let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().appending(path: "Sources/Extensions/calendar/wicket.json")
  var manifest = try #require(
    try JSONSerialization.jsonObject(with: Data(contentsOf: source)) as? [String: Any])
  #expect(manifest["match"] == nil && manifest["fallback"] == nil)
  manifest["command"] = ["/bin/sh", "main.sh"]
  _ = try extensionFolder(
    root, name: "calendar", script: "cat >> \"\(root.path)/requests\"\necho '{\"items\":[]}'",
    fields: manifest)
  let model = LauncherModel.testing(in: root)
  model.extensions.permissions = Permissions(status: { _ in .granted }, request: { _ in })
  await model.extensions.reload()
  for input in ["cal", "calendar", "calendar standup"] {
    model.navigator.input = input
    await model.navigator.settled()
    #expect(model.navigator.results.contains { $0.provider == "extension:calendar" })
  }
  #expect(!FileManager.default.fileExists(atPath: root.appending(path: "requests").path))
  model.navigator.input = "calendar standup"
  await model.navigator.settled()
  #expect(model.activateReturn())
  await model.navigator.settled()
  #expect(FileManager.default.fileExists(atPath: root.appending(path: "requests").path))
}
