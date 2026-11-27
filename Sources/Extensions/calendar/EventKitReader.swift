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
    let repeats = event.hasRecurrenceRules || event.isDetached
    self.init(
      id: eventID(
        event.eventIdentifier ?? event.calendarItemIdentifier,
        occurrence: repeats ? event.occurrenceDate : nil,
        allDay: event.isAllDay, floating: event.timeZone == nil, calendar: .autoupdatingCurrent),
      title: event.title ?? "", start: start, end: event.endDate ?? start, isAllDay: event.isAllDay,
      calendarID: event.calendar?.calendarIdentifier ?? "", location: event.location ?? "",
      notes: event.notes ?? "", url: event.url, cancelled: event.status == .canceled,
      declined: event.attendees?.first(where: \.isCurrentUser)?.participantStatus == .declined)
  }
}

/// An ID that stays the same across reads. A one-off event keeps its own, even when rescheduled. A repeat
/// adds which occurrence it is by its original date, which moving just that repeat leaves alone: the
/// instant for a fixed-time event, else the local date (and time), which a time-zone change leaves alone.
func eventID(_ identifier: String, occurrence: Date?, allDay: Bool, floating: Bool, calendar: Calendar)
  -> String
{
  guard let occurrence else { return identifier }
  guard allDay || floating else { return "\(identifier)@\(Int(occurrence.timeIntervalSince1970))" }
  let local = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: occurrence)
  var key = String(format: "%04d-%02d-%02d", local.year!, local.month!, local.day!)
  if !allDay { key += String(format: "T%02d:%02d", local.hour!, local.minute!) }
  return "\(identifier)@\(key)"
}
