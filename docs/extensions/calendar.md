# Calendar

## 1. Summary

Calendar is a planned read-only EventKit extension for accounts already configured on the Mac. Version 1 shows a 7-day agenda, event details, a **Join** action on the next meeting, and a headless agenda read for the agent. Permissions and onboarding follow the [shared permission model](README.md#decisions-every-spec-follows).

## 2. User experience

- Open **Calendar** by name or hotkey. Starts with the next timed event or active call, then groups the next seven local days under Today, Tomorrow, and date headings. Rows show time (or All day), title, and location/service; search filters title, location, and calendar across those seven days.
- Next meeting carries a labelled **Join** action when a recognized meeting link is present. If live or starting within ~10 minutes, Join is the default Return action (so Calendar hotkey + Return joins). Overlapping calls list each with its title.
- Details show local interval, calendar, location, and invitation notes as plain text (inert under shared work 3), plus Join (or destination hosts for other links).
- Agent questions (“What calls do I have tomorrow?”) use the headless read; ⌘Return inside Calendar sends the visible agenda as `<context>`.

References: [Raycast Calendar](https://manual.raycast.com/calendar) · [Fantastical conference calls](https://flexibits.com/fantastical/help/conference-call-support).

## 3. Design

### Agenda and settings

- Contract 2 manifest: ID/keyword `calendar`, name **Calendar**, icon `calendar`, command `["./main"]`, `"permissions":["calendar"]`, one text field `query`. Reads only on open, search edits, and refresh—never on root typing or idle.
- Swift 6 with EventKit and Foundation, shipped via shared work 10 ([extension catalog](README.md#shared-work)). One `EKEventStore` per run behind a fixture-testable boundary. Queries 7 local days via calendar arithmetic, includes in-progress events, drops elapsed timed events, cancellations, and user-declined occurrences, preserves all-day dates, uses EventKit recurrence expansion with occurrence dates in display IDs, sorts deterministically, and caps at 100 events. Distinguishes no calendars, no events, no search matches, and denied access. Logs counts and timings only.
- Settings in `config.json`: `hiddenCalendars` (comma-separated EventKit IDs; empty shows all so new calendars appear automatically) and `showAllDay` (bool, default true). An in-page calendar chooser waits on shared work 9 ([saving a page's choices](README.md#shared-work)).

### Join and headless reads

- Render agenda as canvas rows with details from one snapshot. Put a labelled Join target beside the next-meeting summary (and make it the view's first action for live/imminent calls).
- Scan event URL, location, and notes (in order) for validated HTTPS links from Meet, Zoom, Teams, and Webex. Rewrite Zoom/Teams to `zoommtg://` and `msteams://` (preserving join parameters) through shared work 8 (meeting links). Offer a choice in details when multiple links match. Escape invitation text; keep tags ≤1,024 UTF-8 bytes (use JSON `open` actions for longer URLs).
- `Wicket --extension calendar --submitted --action read-agenda` returns a structured, bounded agenda with stable IDs, optional search filter, calendar names/IDs (so the agent can edit `hiddenCalendars`), and invitation notes in details.

### Permission and signing

Wicket already carries `com.apple.security.personal-information.calendars` (`Resources/Wicket.entitlements`) and `NSCalendarsFullAccessUsageDescription` (`Resources/Info.plist`); the extension carries neither. `ExtensionRunner` launches child processes through `Process` with normal responsible-process attribution, so the grant follows Wicket's Developer ID identity rather than the extension binary's hash. Separate ad-hoc–signed helper apps re-prompt on every rebuild because their designated requirement is tied to cdhash—never use a helper app.

## 4. What exists today

- Wicket gates `calendar` before launch, requests consent in-process, replays on Allow, and returns structured refusals headlessly ([Permission.swift](../../Sources/WicketApp/Permission.swift), [Headless.swift](../../Sources/WicketApp/Headless.swift)).
- Canvas pages, details, view actions, command hotkeys, and settings persistence all exist ([agenda example](../../Sources/WicketApp/Resources/examples/agenda.py)).

## 5. Gaps

- EventKit reader, agenda UI, and headless read (extension work).
- Native conferencing schemes (shared work 8) and in-page calendar chooser (shared work 9).
- `Permission.swift`'s Accessibility subtitle warns that an older build's grant may stop applying after an update, which conflicts with the expectation that Developer ID updates preserve grants—Phase 0 checks both Calendar and Accessibility together.

## 6. Implementation plan

0. **Owner's real-Mac checks:**
   - **Working-folder extension:** Check 6 in [manual checks §7](../manual-checks.md#7-extensions).
   - **Release-update pair:** Compare `codesign -dr -` across two consecutive Developer ID releases; grant Calendar and Accessibility on the first, update via Sparkle, and verify both still work without resetting.
   - **Agent sandbox:** Run a minimal EventKit probe via `Wicket --extension calendar --submitted --action read-agenda` from Wicket-launched Claude Code and Codex in each permission mode.
1. **Agenda and Join:** Build agenda, details, Join, and `read-agenda` (all testable headlessly with fixture EventKit and fake `Permissions`). Verify root search never launches the binary.
2. **Later:** Calendar chooser (shared work 9) and onboarding permission flow ([ROADMAP step 4](../../ROADMAP.md#4-onboarding)).

## 7. Open question

Which agent permission modes block `tccd`/Calendar inside the CLI sandbox and therefore need a host route forwarding headless reads to the running Wicket instance of the same edition? Phase 0 settles this.
