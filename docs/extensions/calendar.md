# Calendar

## 1. Summary

Calendar is a read-only EventKit extension for the accounts already on the Mac. The first release shows a seven-day agenda, opens event details, puts Join on the next meeting and gives the agent a headless agenda read. Permission and onboarding follow the [shared permission model](README.md#decisions-every-spec-follows).

## 2. User experience

- Open **Calendar** by name or with its own hotkey, set from ⌘K on the command. The agenda starts with the next timed event or calls already in progress, then groups the next seven local days under Today, Tomorrow and date headings. Rows show the time or All day, the title and the location or conferencing service. Search filters title, location and calendar within those seven days.
- The next meeting has a labelled **Join** action when it has a recognized meeting link. If the call is live or starts within about ten minutes, Join is selected for Return when the agenda opens. The Calendar hotkey followed by Return joins the call. If calls overlap, show each with its title so the user can choose. ↑ and ↓ move through targets, Return opens details or activates Join, and Escape goes back.
- Details show the local interval, calendar, location and invitation notes as plain text. A meeting's details also offer Join when there is a recognized destination. Other event links show their destination host.
- Ask the agent “What calls do I have tomorrow?” to use the headless read. From an open Calendar view, ⌘Return already sends the view as context, so “Help me prepare for this meeting” can use what's shown. Invitation text follows shared work 3, [agent context is data](README.md#shared-work).

Raycast's My Schedule is the reference for a searchable agenda. Fantastical is the reference for surfacing Join near the start of a call. [Raycast Calendar](https://manual.raycast.com/calendar) · [Fantastical conference calls](https://flexibits.com/fantastical/help/conference-call-support)

## 3. Design

### Agenda and settings

Use a contract 2 manifest with folder ID and keyword `calendar`, name **Calendar**, icon `calendar`, command `["./main"]` and `"permissions":["calendar"]`. Declare one text search field, `query`. Read on opening, search edits and explicit refresh. Root typing and idle Wicket do no Calendar work.

Build the executable in Swift 6 with EventKit and Foundation and ship it with its source through shared work 10, [the extension catalog](README.md#shared-work). Use one `EKEventStore` per invocation and keep a fixture reader at that boundary. Query event calendars for seven local days using calendar date arithmetic. Include active events that began earlier, drop elapsed timed events, cancellations and the user's declined occurrences where known, and preserve all-day dates. Use EventKit's recurrence expansion and include the occurrence date in display IDs for repeating events. Sort deterministically and cap the agenda at 100 results. Distinguish no calendars, no events, no search matches and unavailable access. Measure opening and filtering with busy fixtures and log only counts and timings.

Declare `hiddenCalendars` as a text setting in `config.json`, for example `"hiddenCalendars": "personal-id,holidays-id"`. IDs come from EventKit. Unset or empty shows all calendars, and newly added calendars appear automatically. The `showAllDay` bool defaults to true. The user edits these settings in Settings and the agent edits `config.json`. A calendar chooser with named calendars and account labels can save its choices through shared work 9, [saving a page's choices to config.json](README.md#shared-work), designed with onboarding.

### Join and headless reads

Render the agenda as canvas rows with details from the same snapshot. Place a labelled Join target beside the next-meeting summary. For a live or imminent call, also make that Join the view's first action so it carries the Return hint and works on entry. Check the event URL, location and notes in that order for validated HTTPS meeting links from Meet, Zoom, Teams and Webex. Rewrite Zoom and Teams links to `zoommtg://` and `msteams://`, preserving join parameters, so the explicit `open` action launches the meeting apps directly through shared work 8, meeting links. Offer a choice in details for multiple plausible links. Escape invitation text and keep raw notes from creating actions. Keep tags within the contract's byte limit and use JSON `open` actions for longer URLs. [Shared work](README.md#shared-work) · [Extension contract](../../Sources/WicketApp/Resources/extension-contract.md)

`Wicket --extension calendar --submitted --action read-agenda` returns a structured, bounded agenda with stable item IDs and an optional search filter. It uses the same date bounds and saved calendar choices as the canvas. Expose calendar names and IDs in the headless read so the agent can set `hiddenCalendars`. Keep invitation notes in details.

### Permission and signing

Under the hardened runtime, Wicket needs the Calendars entitlement. It is already in `Resources/Wicket.entitlements` on `main`, and Wicket carries the full-access usage string. The extension carries neither. The signed Dev trial's `caltrial` child had no Calendars entitlement and read real events through Wicket's grant. The grant follows Wicket's identity regardless of the child's hash. `ExtensionRunner` uses Wicket's normal `Process` launch path, with no opt-out from responsible-process attribution. [Wicket entitlements](../../Resources/Wicket.entitlements) · [Info.plist](../../Resources/Info.plist) · [Runner](../../Sources/WicketApp/ExtensionRunner.swift) · [Launch](../../Sources/WicketApp/Launch.swift) · [Apple's hardened runtime documentation](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)

The probable source of the owner's repeat prompts is the separate agent-built app shown as “Helper” in Privacy & Security. The ISSUES entry updated by `d89db5d` records that workaround. Before 0.5.x, Wicket had no Calendar usage string, so a plain child could not get access. An ad hoc signature's designated requirement uses its cdhash. A rebuild that changes the hash looks like a new app to macOS, prompting again and leaving stale entries. Truly unsigned code has no designated requirement. To confirm, compare `codesign -dr - <helper.app>` across two helper builds. Then reset the old helper with `tccutil reset Calendar <helper id>`, delete it and keep Calendar on Wicket's permission gate. [Apple TN3127](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements/)

## 4. What exists today

- Wicket already gates Calendar before launch, requests consent in its own process and replays the gated request after Allow. Headless calls return a structured refusal when the grant is missing. [Permission.swift](../../Sources/WicketApp/Permission.swift) · [Navigator.swift](../../Sources/WicketApp/Navigator.swift) · [Headless.swift](../../Sources/WicketApp/Headless.swift)
- The agenda example shows date headings and details, the canvas supports view actions, and command hotkeys and manifest settings already persist. [Agenda example](../../Sources/WicketApp/Resources/examples/agenda.py) · [Extension contract](../../Sources/WicketApp/Resources/extension-contract.md) · [CommandHotKeys.swift](../../Sources/WicketApp/CommandHotKeys.swift)

## 5. Gaps

- The EventKit reader and agenda are extension work. Native conferencing links and invitation context depend on shared work 8 and 3. The calendar chooser depends on shared work 9. [Shared work](README.md#shared-work)
- The Accessibility gate in `Permission.swift` says a grant for an older copy can still appear on and stop applying after an update. That conflicts with the shared expectation that a Developer ID update keeps the grant. The same release-pair check below settles Calendar and Accessibility together. [Permission.swift](../../Sources/WicketApp/Permission.swift) · [Shared permission model](README.md#decisions-every-spec-follows)

## 6. Implementation plan

0. **Owner's checks on a real Mac.** Run the three shared permission checks.
   - **Working-folder extension.** Follow check 6 in [manual checks §7](../manual-checks.md#7-extensions) for an agent-written extension.
   - **Release-update pair.** Compare `codesign -dr -` across two consecutive Developer ID releases. Grant Calendar and Accessibility on the first release, then update through Sparkle. Read a known event and run a window command on both releases without resetting either grant between them.
   - **Agent sandbox.** Use a minimal EventKit probe with the planned `read-agenda` action. Run `Wicket --extension calendar --submitted --action read-agenda` from Wicket-launched Claude Code and Codex in each of their permission modes. Verify the known event is returned.
1. **Agenda and Join.** Build the agenda, details, Join and headless read. Exercise searches, calendar visibility, DST, recurring and active events, empty and denied states, invitation text, link validation and the explicit Return effect. Verify that root search never launches the reader.
2. **Later.** Add the calendar chooser with shared work 9 and offer Calendar's permission during onboarding through the shared flow. [Official extensions](README.md)

Every phase is testable headlessly with a fixture EventKit reader and fake `Permissions`. Only macOS's real permission store needs the owner.

## 7. Open questions

Which agent permission modes need a host route? If a CLI sandbox blocks `tccd` or the Calendar service, forward the headless read to the running Wicket host of the same edition and return its normal view. Phase 0 determines where that fallback is needed.
