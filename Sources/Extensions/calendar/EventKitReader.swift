import EventKit

/// The one place that touches EventKit, so everything else runs on fixtures. It never asks for access:
/// Wicket holds the grant and asks before it starts this program (`permissions` in the manifest).
enum EventKitReader {
  static func snapshot(in window: DateInterval) -> Snapshot {
    // Wicket checks its grant before launch, but a process the agent starts can still be refused.
    guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return .denied }
    let store = EKEventStore()
    let calendars = store.calendars(for: .event)
    guard !calendars.isEmpty else { return .loaded(calendars: [], events: []) }
    // EventKit expands repeating events into one occurrence each.
    let predicate = store.predicateForEvents(withStart: window.start, end: window.end, calendars: calendars)
    return .loaded(
      calendars: calendars.map { AgendaCalendar(id: $0.calendarIdentifier, title: $0.title) },
      events: store.events(matching: predicate).map(AgendaEvent.init))
  }
}

extension AgendaEvent {
  init(_ event: EKEvent) {
    let start: Date = event.startDate
    // The occurrence date keeps a repeat's ID stable when the user moves just that repeat.
    let occurrence = event.occurrenceDate ?? start
    self.init(
      id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)@\(Int(occurrence.timeIntervalSince1970))",
      title: event.title ?? "", start: start, end: event.endDate ?? start, isAllDay: event.isAllDay,
      calendarID: event.calendar?.calendarIdentifier ?? "", location: event.location ?? "",
      notes: event.notes ?? "", url: event.url, cancelled: event.status == .canceled,
      declined: event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined)
  }
}
