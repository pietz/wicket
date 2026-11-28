# Calendar

## 1. Summary

Calendar is a bundled read-only EventKit extension for accounts already configured on the Mac. It shows a seven-day agenda with **Join** for the next meeting, the current week and month, and a headless agenda read for the agent. Permissions and onboarding follow the [shared permission model](README.md#decisions-every-spec-follows).

## 2. User experience

- Open **Calendar** by name or hotkey. Starts with the next timed event or active call, then groups the next seven local days under Today, Tomorrow, and date headings. Rows show time (All day, or Until and the end time for an event that began on an earlier day), title, and location/service, with Now on a running event; Today stays listed with “Nothing else today” once its events are over. Search filters title, location, and calendar in the selected view.
- Switch among **Agenda**, **Week**, and **Month** on the page. **Calendar Week** and **Calendar Month** are root items and can have their own hotkeys (`wicket://calendar?item=week` and `wicket://calendar?item=month`). Escape from either view returns to Agenda.
- **Week** starts on the locale’s first weekday. It shows timed events in seven lanes, with overlapping events side by side and a line marking the current time. On clock-change days the axis uses elapsed time from the day’s start. Event details show local times and include the UTC offsets when an event spans a clock change. An **All-day events** row opens the all-day list. **Month** highlights today and shows event counts for the displayed month. Select a day with events to open its list. Escape from the list returns to the month.
- Next meeting carries a labelled **Join** action when a recognized meeting link is present. If live or starting within ~10 minutes, Join is the default Return action (so Calendar hotkey + Return joins); otherwise Return opens Calendar.app. Actions for links too long for a row follow the default. Overlapping calls list each with its title.
- Details show local interval, calendar, location, and invitation notes as plain text (inert under shared work 3), plus Join (or destination hosts for other links).
- Agent questions (“What calls do I have tomorrow?”) use the headless read; ⌘Return inside Calendar sends the last view shown as `<context>`, which after typing a search may still be the unfiltered agenda.

References: [Raycast Calendar](https://manual.raycast.com/calendar) · [Fantastical conference calls](https://flexibits.com/fantastical/help/conference-call-support).

## 3. Design

### Agenda and settings

- Contract 2 manifest: ID/keyword `calendar`, name **Calendar**, icon `calendar`, command `["./main"]`, `"permissions":["calendar"]`, one text field `query`. Reads only on open, search edits, and refresh—never on root typing or idle.
- Swift 6 with EventKit and Foundation, bundled with Wicket ([`Sources/Extensions/calendar`](../../Sources/Extensions/calendar)) until it moves to the [extension catalog](README.md#shared-work) (shared work 10). One `EKEventStore` per run behind a fixture-testable boundary. Uses local calendar boundaries. The agenda reads seven days from today and includes in-progress timed events. Week and Month include elapsed events in the displayed period. Every view excludes cancellations and user-declined occurrences, preserves all-day dates, uses EventKit recurrence expansion, keeps IDs stable across reads (a one-off event's identifier; a repeat adds its original occurrence: the instant for fixed-time events, the local date or date and time for all-day and floating ones), and sorts deterministically. Agenda lists up to 100 events and Week shows up to 100 timed entries. Month counts all matching events and shows up to 12 per day in detail, the same limit as the all-day week list. Distinguishes no calendars, all calendars hidden, no events, no search matches, and denied access, each as one row whose action is the fix. Logs counts and timings only.
- Settings in `config.json`: `hiddenCalendars` (comma-separated EventKit IDs; empty shows all so new calendars appear automatically) and `showAllDay` (bool, default true). An in-page calendar chooser waits on shared work 9 ([saving a page's choices](README.md#shared-work)).

### Join and headless reads

- Render agenda as canvas rows with details from one snapshot. Put a labelled Join target beside the next-meeting summary (and make it the view's first action for live/imminent calls).
- Scan event URL, location, and notes (in order) for validated HTTPS links from Meet (meeting codes and `/lookup/` links only), Zoom, Teams, and Webex. Calendar opens the HTTPS link, and the browser hands off to the installed app. Rewriting Zoom/Teams to `zoommtg://` and `msteams://` (preserving join parameters) waits on shared work 8 (meeting links), which also needs a fallback when the app is missing. Offer a choice in details when multiple links match. Escape invitation text; keep tags ≤1,024 UTF-8 bytes (use JSON `open` actions for longer URLs).
- `Wicket --extension calendar --submitted --action read-agenda` returns a structured agenda with stable IDs, optional search filter, calendar names/IDs (so the agent can edit `hiddenCalendars`), and invitation notes in details. It stays under 1,000,000 bytes: notes are cut at 4,000 bytes, and past the budget events keep only ID, title, time, and calendar, with the body saying what was cut. No calendars or all hidden returns `items: []` with a one-line reason; denied access exits 1 with the reason on stderr (headless `{"error":…}`).

### Permission and signing

Wicket already carries `com.apple.security.personal-information.calendars` (`Resources/Wicket.entitlements`) and `NSCalendarsFullAccessUsageDescription` (`Resources/Info.plist`); the extension carries neither. `ExtensionRunner` launches child processes through `Process` with normal responsible-process attribution, so the grant follows Wicket's Developer ID identity rather than the extension binary's hash. Separate ad-hoc–signed helper apps re-prompt on every rebuild because their designated requirement is tied to cdhash—never use a helper app.

## 4. What exists today

- The extension lives in [`Sources/Extensions/calendar`](../../Sources/Extensions/calendar): `EventKitReader.swift` is the only EventKit code; `Agenda.swift` renders the views, details, state rows, and `read-agenda` from a snapshot; `MeetingLink.swift` validates join links.
- [CalendarTests.swift](../../Tests/WicketTests/CalendarTests.swift) covers the agenda, Join timing and the default action, overlapping calls, overnight rows, inert notes, link validation, search, settings, state rows, the cap, `read-agenda` (its size budget, setup and denied cases), stable IDs, and that root typing never starts the program, all on a recorded week ([calendar-week.json](../../Tests/WicketTests/Fixtures/calendar-week.json)) with no EventKit access. `panelCapture` draws `calendar-agenda`, `calendar-week`, `calendar-month`, `calendar-empty-day`, `calendar-detail`, and `calendar-denied`.
- Wicket gates `calendar` before launch, requests consent in-process, replays on Allow, and returns structured refusals headlessly ([Permission.swift](../../Sources/WicketApp/Permission.swift), [Headless.swift](../../Sources/WicketApp/Headless.swift)).

## 5. Gaps

- Phase 0 real-Mac checks (section 6) have not run; Calendar access in the agent's sandbox is unverified.
- Native conferencing schemes (shared work 8) and in-page calendar chooser (shared work 9).
- `Permission.swift`'s Accessibility subtitle warns that an older build's grant may stop applying after an update, which conflicts with the expectation that Developer ID updates preserve grants—Phase 0 checks both Calendar and Accessibility together.

## 6. Implementation plan

0. **Owner's real-Mac checks:**
   - **Working-folder extension:** Check 6 in [manual checks §7](../manual-checks.md#7-extensions).
   - **Release-update pair:** Compare `codesign -dr -` across two consecutive Developer ID releases; grant Calendar and Accessibility on the first, update via Sparkle, and verify both still work without resetting.
   - **Agent sandbox:** Run `Wicket --extension calendar --submitted --action read-agenda` from Wicket-launched Claude Code and Codex in each permission mode.
   - **Built-in Calendar:** Check 13 in [manual checks §7](../manual-checks.md#7-extensions).
1. **Agenda and Join:** Built (section 4).
2. **Later:** Calendar chooser (shared work 9) and onboarding permission flow ([ROADMAP step 4](../../ROADMAP.md#4-onboarding)).

## 7. Open question

Which agent permission modes block `tccd`/Calendar inside the CLI sandbox and therefore need a host route forwarding headless reads to the running Wicket instance of the same edition? Phase 0 settles this.
