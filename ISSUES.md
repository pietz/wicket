# Known issues

Open problems and unverified behavior, checked against the code on 11 Nov 2026. Fixed items are not listed; git history has them. What is planned is in [ROADMAP.md](ROADMAP.md).

## Before publishing a release

Nothing here needs code. Each needs a person on a real Mac, or credentials.

- **Sparkle upgrade path, never run.** The bundle id, team, feed URL and public key match 0.0.15, but no installed 0.0.15 has yet updated to a 0.1 build. Check once with a real signed, notarized DMG and a staged appcast, then once more for the cask. `release.sh` needs the owner's unlocked login keychain (notarization profile `wicket-notary`, Sparkle key `wicket`).
- **A settings reset for existing users.** 0.1 does not read 0.0.x's `settings.json`, usage, voice or approval files, nor its extensions (another protocol); a customised hotkey falls back to ⌥Space. Nothing is deleted (a test pins this). Say it in the release notes; migration is in the roadmap.
- **Permissions under the release signature.** The microphone grant and any login item from 0.0.x are keyed by the same bundle id and team, so they should carry over; confirm once. Launch at login with a Developer ID build is unverified.
- **Hardened runtime with WebKit and Sparkle.** The release bundle verifies (`codesign --verify --deep --strict`) and runs headless, but the GUI paths (web view, Sparkle's update window, speech) were not exercised in the signed bundle.

## Needs hands-on verification

Everything below is built and covered by headless tests, but was never watched on a real screen, microphone or Mac settings. Audible, on-screen and device-changing checks stay with a person.

Voice, with real audio (`voice-timing.txt` in the config folder records latencies):
- Speak right after opening: first words, sentence start, accuracy, volume indicator and music quality with a Bluetooth headset as the system default. Compare Automatic, the built-in microphone and a named device. Disconnect a named device and check that Automatic is used on the next opening; disconnect a wired one during capture and check the retry hint and that nothing restarts.
- Open and close rapidly, including while it says Starting voice. Capture must be gone before the panel hides and never return after it. Turn voice off and on in Settings. Use another dictation app afterwards and check that input, output and volume are unchanged.
- First consent and denial focus restoration, and whether Dictation settings install the exact `SpeechAnalyzer` asset (unverified).

Conversation and confirmations:
- Follow-ups by typing and by speaking with an answer visible; empty Return; a draft during work; Previous questions with a long question; scrolling, selection and Copy with Stream answers on and off, including a turn that uses tools, cancellation and failure.
- Hide by hotkey and by clicking away, then reopen with a draft, a running turn and each confirmation; the continuing footer; the five-minute expiry; the full Escape order including voice startup and root input clearing.
- Permission and extension-enable cards: Tab, Cmd+Return, plain Return and Escape; Allow once reaching the real agent; deletion wording; Show details scrolling and selecting.

Settings and panel:
- Text size at all four steps, live, with long titles, code, tables and confirmations. Shortcut recording and physical delivery of the global hotkey, including a recorded conflict. Login-item approval and relaunch. Agent pickers before any conversation, switching between Claude and ChatGPT, unavailable choices, Regular versus Fast (fast is untested against a real account). Sources: switching sources off and on, the Settings result, adding the web-search example by hand.
- Panel stability while typing and while late extension results arrive; the glass look in light and dark; IME composition; Spaces and fullscreen; VoiceOver and larger text; contrast over busy backgrounds; selection and trackpad scrolling in answers; live `answers.css` editing; sustained WebKit memory after hiding.

## Product

- **Percentages.** `%` divides by 100, so `200 + 10%` is `200.1`, not `220`. Define and test intuitive semantics before widening the calculator. Decimal commas are not accepted.
- **Reference files are installed once.** `answers.css`, `agent-instructions.md`, `extension-contract.md` and the bundled `units` extension are copied into the config folder only if absent, so a Wicket update never refreshes them. Decide how upgrades deliver changes (an installed version marker, or a diff the user can accept) without overwriting local edits.
- **Enabled means trusted.** A new extension folder, including one an agent writes, runs as soon as it appears, with the user's access and no review; an agent that edits an enabled extension changes what runs next. Edits during a run can affect it, since there is no copy. This is deliberate (SPEC, Extensions), but pattern-triggered runs are invisible: Sources does not show when an enabled extension runs on its own.
- **Card and component polish** (a review, not yet checked in the renderer): cards side by side can have unequal heights; the guidance should say facts are for short label/value pairs and tables for comparable records; bars deserve an accessibility pass.
- **Renderer memory and speed** were measured only on a prototype (242 ms first paint, 37 ms later, 95 MB before and 178 MB after first web-view use). A matched measurement of the integrated app, with the same answers and machine, cold and warm, process-tree memory before, during and after the release delay, is still to do.
- **Agents inherit the user's own configuration**, including MCP servers, which costs start time and memory per question. Wicket says so; a lean profile is a later option.
- Conversations do not survive an app restart.

## Process I/O

- **No backpressure on a slow consumer.** `FileHandle.chunks(limit:perLine:)` stops reading once a flood exceeds its limit, but it yields into an unbounded `AsyncStream` and never waits for the consumer, so a slow reader of a fast writer that stays under the limit can still let read-ahead pile up. Bounded for floods, not backpressured.
- **`Launch.capture` is uncapped.** The login check (`claude auth status`, `codex login status`) appends all stdout into `Data` until the process ends or the 8 s limit passes. Only the time is bounded, not the bytes.
- **Agent stderr is uncapped.** `JSONLines` keeps the last 4 KiB of stderr, but reads it without a byte limit, so a process that floods stderr is read to the end, at CPU cost though not memory.

## Code debt

From a review of an earlier snapshot, rechecked against the current code. The first three items of that review (extension trust, one query composer, screen captures inside the app) are done, as are the Node runtime, the module merge, the voice teardown relay and the duplicated agent handshake.

- **Launcher state is implicit.** `LauncherModel` has no mode value: the open command, its view, problem and busy flag, the conversation and the confirmation are separate properties reset together in several places. One `mode` (search, command, conversation) and one `confirmation` property would remove a class of missed-reset bugs. Risk: medium, covered by `ProviderTests`, `ConversationTests` and `VoiceTests`; check panel jitter by eye afterwards.
- **Callbacks instead of Observation.** `onResultsChange` is called from about fifteen places in the model and `onChange` from `AgentSession`, `ExtensionHost` and `ConfigurationStore`, wired by hand in `AppDelegate`. macOS 26's `Observations` sequences could replace them. Observation coalesces, so the panel may resize one run-loop turn later; panel stability was hard won.
- **`model.problem` carries several things** (config errors, hotkey conflicts, provider errors, paste errors) and is cleared by checking `hasPrefix("Config:")`. Keep each source separate and let the footer pick.
- **Two hardware serialization schemes in voice.** `Microphone` (lock plus an opening stream) and `EngineCapture` (serial queue) both serialize open and close. One class on one serial queue would do. Only with a hands-on voice test: a review fix here once broke Bluetooth voice.
- **Small leftovers.** `ProcessTree.exitStatus` and `Shutdown.notRunning` are unused. `Result` (in `Composition.swift`) shadows `Swift.Result`; rename it when touching those lines. `SettingsActivation` exists only to call a deprecated method without a warning. `ExtensionFailure` is used as the general message-carrying error, including by the headless mode.
- **Tests.** The hotkey `Handle` fake is declared four times in `SettingsTests` and `KeyHandlingTests`; share one. `HeadlessTests` runs `.build/debug/Wicket` from a hard-coded path and silently depends on a debug build existing (`Scripts/check.sh` builds first); say so in the test or build the product from it.
