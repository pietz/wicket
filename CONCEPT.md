# Wicket: concept

> A wicket is the small door built into a big gate. Wicket is a small, fast, native macOS launcher that opens onto your whole Mac and your agents.

This page holds the why: the thesis, the principles and each decision as its call and its reason. How the code works is in [docs/architecture.md](docs/architecture.md); what is built and what comes next is in [ROADMAP.md](ROADMAP.md). "(owner)" marks calls only the owner changes.

## Purpose and scope

A launcher should be a small, very fast native core plus **one extension protocol simple enough that your coding agent writes the extensions**. Once agents exist, a large built-in feature set and a click-optimised store matter less than a documented, fast way to extend. Wicket hosts no AI: it drives the agent the user already has (Claude Code or Codex, on their own subscription). Raycast moved to WebViews and Node, and Spotlight on macOS 26 took the casual tier, so a new launcher has to win on speed, depth and taste.

**The core, and nothing else for now (owner, 2026-11-08).** A simple, fast, AI-native launcher, six things:
1. **AI** through the user's own harness, under that harness's own permission policy, with replies drawn natively from markdown plus a fixed catalog of tags.
2. **File search.**
3. **Calculator,** with units and currencies.
4. **App launcher.**
5. **Extensions the agent builds on request,** reviewed and enabled per revision.
6. **Voice input:** speaking instead of typing is part of the experience.

Supporting behaviour stays because the six need it: typed web addresses, Finder context for the agent, paste-back, the settings file, text size, usage ranking, the menu bar icon, updates and the `wicket` tool. Nothing else, new features or polish, until these six are on point.

**Not doing, and why** (owner, 2026-11-08), so nobody rebuilds them by accident:
- **Prompt commands, Save as Command, Make a Command:** a reusable command is something you ask the agent to build, so extensions stay one concept.
- **Aliases, per-command hotkeys, the Shortcuts pane, Start Listening:** no real need yet; the mic button and ⌘L start listening.
- **A switch per source (the Features pane):** apps, files, the calculator and links cost little. Only AI and Voice can be turned off.
- **Selected-text capture:** unreliable, and it needed Accessibility.
- **Quick Look on Space:** the preview needs an active app while Space already filters a list; an on-screen focus spike must settle it before building.
- **A web search row:** Run Agent answers and searches when it needs to; a second fallback is only another choice.
- **Wicket's own permission levels, Allow for Session, answer-only runs (`wicket agent ask`):** the harness's configuration is the user's policy; a second one on top drifted from it (see AI).
- **Streaming partial answers:** a half-written answer is rarely worth reading in a launcher.
- **Spoken answers (TTS):** voice is input to the launcher; speaking replies is outside the six-pillar core.
- **An Apple Intelligence provider:** a choice that can only answer made Run Agent behave differently by provider. Apple's on-device model may return for small internal jobs, never as a choice.
- **Extension sessions, root mode, rollback, capabilities, a sandboxed fixture checker, Wicket-managed uv:** see Extensions.

## Principles

1. **Native and fast, and measured.** AppKit and SwiftUI, no WebViews, no Node. Hotkey to visible, keystroke to results and idle memory are measured on every hot-path change and compared with Tinycast. The bar: about 25 ms median hotkey to visible and about 20 MB idle (Tinycast: 46 ms, 38 MB). Numbers and method: [docs/architecture.md](docs/architecture.md#performance).
2. **AI never sits on the keystroke path.** Deterministic results answer at once; Run Agent is a deliberate row, and partial queries never reach a model.
3. **A small core, extensions for the rest.** A feature belongs in the core only if it needs deep OS integration or must be instant. One protocol, one guide and a JSON schema, enough for an agent with no other context.
4. **Explicit consent; the settings file never grants it.** Agents and people edit `settings.json`, so anything that amounts to a permission (enabling an extension, turning voice on) is granted only in Wicket's UI and kept in a store only Wicket writes, failing closed. Lesson from Tinycast's settings import.
5. **Restrained UI.** Apple's interface guidelines over custom styling (owner): concentric shapes, one-line rows of one height, whole rows only. Compact by default (owner): summoning shows only the pill, and a card grows when there is something to show.
6. **Private.** No accounts, no telemetry, no hosted AI. Logs hold counts and timings, never query text, paths or AI content.
7. **Simple over clever, newest APIs.** Fewer settings, fewer special cases; the newest Apple frameworks over hand-written code.

## Interaction

- **Shell.** A non-activating palette keeps the previous app as the paste target; the global hotkey needs no Accessibility or Input Monitoring. Host-owned sizing keeps the top edge from drifting. macOS 26 minimum, for Liquid Glass and the newest APIs without fallbacks. ⌘Q is inert in the palette: a launcher dismissed by reflex shouldn't quit.
- **Pill and card.** A glass pill with a card below that fits its content, grows at once and shrinks only after 300 ms, because Spotlight results drop and return a beat after each keystroke. A page is measured up to eight rows and only grows within one run, so a short answer stays compact and a growing answer never jumps. A command opens its frame at once, the pill spinning with its title until the first result, so every way in looks the same and Escape always backs out.
- **Ranking.** Host-owned relevance tiers instead of comparing each source's scores, with frecency among local matches and apps ahead of equal files. Fallbacks, computed answers and rows inside a command get no frecency: a fixed menu shouldn't move, and only the root search ranks by use.
- **Stable selection.** The highlight stays on the top row until the user moves it, then follows its item, so a late result never changes a row the user chose. A vanished selection stays on its row; only new query text resets it.
- **Run Agent on top when typing reads like a request.** With nothing local a strong match, a request moves Run Agent to the top so Return asks. A cheap deterministic rule keeps AI off the keystroke path; a classifier can replace it only if needed.
- **Keywords.** A keyword and a space opens its command (Alfred's model). A built-in keeps its keyword everywhere; among extensions the first in registry order wins, so the winner never depends on install order. Every way in (a row, a keyword, a `run` action, `wicket run`) goes through one invocation policy, so a command behaves the same however it is reached.
- **Keyboard.** Return runs, ⌘↩ the second action (Follow Up on an answer), ⌘K the actions menu (a native `NSMenu`, prototyped in place of the earlier overlay with its own search field, since a system menu may feel more native), ⌘1 to ⌘9 a row (by key code, so AZERTY works), ⌃N/⌃P move, ⌘L listens, ⌘, opens Settings. **Escape goes up one layer (owner):** it stops listening, closes the actions menu, leaves a page, clears the text, then hides; one key for back, since nobody guessed ⌘[. The hotkey closes from any depth.
- **Pages read first.** Nothing is selected until an arrow moves, so an answer opens at its top and Return copies it. Typing on an answer starts Follow Up with the typed text, since the next keystroke there is almost always the next question.
- **Copy and paste-back.** Copy takes a page's plain text, never its tags. Paste types ⌘V into the app that was frontmost at summon, using the current layout's key; Accessibility is asked on a paste, never at launch. If the target doesn't come front, Wicket only copies rather than type into the wrong app. The clipboard isn't restored: reading it triggers macOS's alert and a restore races the target's read.
- **Built-in sources.** Apps: a scan of fixed folders, since Spotlight also returns copies in Downloads, build folders and disk images. Files: Spotlight's word-prefix search (about 30 ms), not our own index, which would need Full Disk Access and thousands of lines. Calculator: a pure engine that runs on every keystroke, locale-aware and never guessing (`2,5` in English gives no answer rather than a wrong one), ECB rates cached a day; phrases and dates are extension work. A typed address gets an Open row only when unambiguous, since a wrong guess would sit above the user's files.
- **Settings.** `~/.config/wicket/settings.json` is the truth, reloaded live, plain JSON people and agents edit; the Settings window only writes it. Every field fails alone, and a file that isn't valid JSON (often an agent mid-write) keeps the last good settings. Text size is named steps (owner), which fit a picker and can't produce odd sizes; only pages follow it.

## AI and native replies

- **One Run Agent entry (owner).** One AI row, keyword `ai`, answers, researches or acts in the user's Claude Code or Codex. Agents are capable now, a plan-and-run gate on every action is friction, and the harness's settings are the user's own policy on their own subscription. It is called Run Agent because it acts. Wicket adds no safety on top of what the user lets their agent do unasked.
- **The harness's own permission policy (owner).** Wicket passes no mode; what the agent may do unasked is what the user set in Claude Code or Codex, also on a resumed conversation. When the agent asks, the palette shows exactly what it asks for (command and folder, host, paths) with **Allow once** or **Deny**. Claude's permission suggestions are never sent back, so answering never widens the session; a standing grant belongs in the harness's configuration. Questions the palette has no form for are declined, and the agent asks in its reply.
- **Whole messages (owner).** The page shows what the agent writes, each message once whole, then the answer; no tool use, no thinking.
- **Machine interfaces, no SDK.** Codex `app-server` and Claude Code's stream-json, one adapter each, tested against one major.minor per CLI (others run with a warning). Status is checked before each run, and a chosen provider that isn't ready is reported, never swapped for another.
- **Model, effort and speed (owner).** Settings ▸ AI picks one provider by the subscription people know ("Claude" or "ChatGPT") and its model, reasoning effort and speed, remembered per provider. Wicket always names them (Claude's `sonnet`, ChatGPT's GPT-6.1 Terra, medium effort, regular speed), so what runs is what the pane shows; faster spends more of the plan, so it is never the default. The pickers list what each CLI reports, so they never go stale, but only the newest model of each family, largest first (Astra, Sol, Terra, Luna; Fable, Opus, Sonnet, Haiku), since older versions are only clutter (owner).
- **Finder context.** Opened from Finder, the agent works in the selection's folder and is told which files were selected. Captured after the palette shows and only if Automation of Finder was already granted, since a prompt at summon would take the keyboard. The clipboard is never read: macOS alerts on it.
- **Native replies: markdown plus a fixed catalog of block-level tags (owner).** Models are fluent in markdown with tags, prose and components interleave naturally, and fixed screen slots felt underwhelming. No harness structured output: a schema could only guarantee "a string" at double the output. Wicket stays in control: whitelisted tags and attributes, bounded layout (no sizes or colours, a semantic tone only), unknown tags shown as text. Catalog: [docs/markup.md](docs/markup.md).
- **Agent content only presents.** A reply can be steered by prompt injection, so it may open web, mail and file links and copy, never paste or run a command; a link that would run something (an app, a script) is revealed in Finder instead.
- **Tolerant for agents, strict for extensions.** Model output may be imperfect, so a problem never fails a reply; an extension's markup is linted strictly by `wicket run`, so its author can fix it before enabling it. Wicket owns the block syntax, so it also owns its parser.
- **One file per component, one registry (owner).** The agent's instructions, docs/markup.md, the lint and the tests are generated from or checked against it, so the catalog grows without the code growing around it.
- **The agent is told the catalog inline, and structure becomes components (owner).** Told "plain Markdown first", models wrote tables and lists where Wicket draws cards, stats and timelines; a short brief (the reply is a native page, so give content with a shape the tag that draws it; prose stays prose) and one example fixed that without tagging plain answers, as well as a rule per tag did and in fewer words (docs/reviews/2026-11-08-markup-eval.md). About 1k tokens cached with the prompt beats a file the model must remember to read before every reply.
- **Online images: Wicket fetches, on by default.** A weather or person page without its image is the worse product. Fetches are credential-free, bounded and checked against private-network requests (SSRF); "Show online content" turns them off. DNS rebinding between the check and the connection is an accepted v1 risk; closing it needs our own connection stack.
- **Wicket's rules ship in the app; agent.md is the user's (owner).** Bundled rules update with Wicket; the user's own instructions start empty and are added after, so app updates never overwrite them. Generated context holds only what Wicket alone knows. It is instructions, never consent.
- **Follow Up resumes the harness's session (owner).** Same session, folder, model, effort and speed, even if Settings changed since, so the agent keeps what it did and read, not just its words. Persist and resume, not a process kept alive: nothing idles or needs killing on quit. The cost: runs land in the user's own Claude Code and Codex history. A follow-up lives as long as the palette's frames.
- **The AI builds commands when asked (owner).** "Build a command that shows the weather" goes to Run Agent like anything else. When the run ends, the extensions it added or changed are offered first as **Review and Enable**, also when the run failed, since what it wrote is still there; a run the user stops has no page left, so what it wrote shows up for review in the Extensions command, with its conversation kept for Fix and Change with Agent. Consent is unchanged. **Fix with Agent** and **Change with Agent** resume the conversation that built the extension, since that agent knows why it is the way it is; if resuming fails, the page offers Start New Conversation and nothing retries on its own, since a silent fresh run could redo half-done work. Fix is offered only where the extension's own code failed, never for Wicket's refusals.

## Extensions and trust

- **One data model, two execution modes.** Built-ins run in process, extensions out of process, so a crash never takes Wicket down; both produce the same items, screens and actions, drawn natively. A wire `run` resolves only within its sender's extension, so only the host can name a built-in.
- **Protocol 2: one process per run (owner and lead).** One JSON request on stdin, one result on stdout, exit; Wicket ends whatever the program started. Persistent sessions' recovery rules were most of the runtime's code and bugs, and a cold start is cheap by comparison; slow set-up is cached in `WICKET_DATA_DIR`. Two modes, `once` and `live`. Extensions add no rows to the main search: that put processes on the keystroke path for a rarely used feature. Guide: [docs/extensions.md](docs/extensions.md).
- **Full freedom (owner).** An extension is any executable and runs with the user's permissions, the same trust as the agent that wrote it. Protection is review before enable, approval per exact revision, and never auto-enabling anything downloaded. A sandbox can come if extensions are ever shared with strangers.
- **`wicket check` is static; `wicket run` is the real test.** The review before Enable validates the sealed folder and runs none of its code, since generated code must not run with the user's permissions before they approve it. A sandboxed fixture replay cost a profile and canned paths and proved only the canned path. The agent tests for real with `wicket run`, which fails on an invalid or error answer or bad markup.
- **Approval per revision, owned by Wicket (owner).** A revision is the hash of the folder; any change needs approval again, because an agent can rewrite an extension at any time and approving a name would approve its next version. Approvals live in a store only Wicket's UI writes, failing closed, and Enable needs a token from a review screen Wicket drew in this run of the app, so no file, link or other process can approve.
- **What runs is a sealed copy.** A read-only, hashed copy, so what was checked, approved and runs are the same bytes while an agent keeps writing. A changed folder keeps running its approved revision until the new one is enabled, so editing never breaks it. A run from replaced code is refused ("the extension changed") with an explicit Run Again, never rerun by itself.
- **Dependencies are vendored (owner and lead).** Packages go in the folder (`pip install --target vendor`, `node_modules`), so they are hashed, sealed and approved with the code and nothing installs at run time. `uv` and `uvx` are refused: they would run packages the revision never saw.
- **Each run happens once, and an extension's runs never overlap in the app.** Nothing is resent, so a toggle can't fire twice; cleanup finishes before the next run, so state writes within the app need no locking. Stopping or quitting also stops the run's descendants.
- **Secrets** are declared in the manifest, kept in the Keychain and passed as environment variables; they are redacted from anything Wicket stores.
- **Run history and `wicket log` (owner).** Every run in Wicket is recorded with its outcome and why (not one the user abandons, nor `wicket run`'s), the input kept only for failures, outliving a restart, so the user, Copy Diagnostics and the agent can see why a run failed. A failure lives once, in the history. No rollback: Fix with Agent repairs faster than a second approved revision. No capabilities: unenforced claims on the review screen implied a guarantee.
- **Move to Trash, without a confirmation:** the Trash is the undo. Approvals and sealed copies go with it; data and secrets stay, since deleting them couldn't be undone.
- **One runtime for the app and the CLI** (`WicketHost`), so `wicket run` runs an extension as the palette does.

## Voice

- **Summon and speak, into the search field (owner).** Words appear in the field as they are said; listening runs through pauses until Return, any key, Escape or 60 s of silence, since stopping at a short silence cut people off. Speech is another way to type the query: the same routing, nothing runs until Return, and a spoken keyword never opens its command mid-sentence.
- **Quiet arming (owner).** With voice on, the microphone arms quietly on every open; a small filled mic glyph is the only sign. The first key turns it off and drops anything heard, so typing is never interrupted; the first words switch to listening, shown by a moving waveform. Noise transcribed as punctuation doesn't count as words. The mic button and ⌘L toggle listening by hand (press, not hold).
- **Apple's on-device SpeechAnalyzer.** Live results in many languages, no model to ship, run in a system process, so idle memory is unchanged with voice off and only the microphone permission is needed. The language is the first preferred one transcription supports.
- **Turning voice on is consent.** It lives in a Wicket-owned file written only by Settings ▸ Voice, which also asks for the microphone; never at a summon, where the dialog would take the keyboard.

## Distribution and releases

- **A notarized DMG on GitHub Releases, a Homebrew cask, Sparkle for updates.** Installing should be like any Mac app. Sparkle is the one third-party dependency: in-app updates are a concrete need and a signed updater of our own would outgrow what it serves. Automatic checks are on by default (one GET of a public file) and can be turned off in Settings ▸ General.
- **Wicket Dev beside Wicket.** Local builds are Wicket Dev, with its own hotkey (⌃⌥Space), folders and no updater, so the owner runs the released app and works on the next one at once. One edition read from the bundle id, not a compile flag, so the same binary is tested either way.
- **SwiftPM and a build script, no Xcode project;** signed with a stable identity so macOS permissions survive rebuilds. Versions are 0.0.x alphas for now. How a release is cut: [docs/release.md](docs/release.md).

## Reference policy

- Tinycast (AGPL-3.0) and Vicinae (GPL-3.0) are **references, not sources**: their docs and issue trackers record many pitfalls. A local clone may live in `reference/` (gitignored).
- **Design first, then compare;** if theirs is cleaner, adopt the idea, re-implemented.
- **Never copy code:** it would force our licence to (A)GPL.

## Open questions

- **Licence:** MIT versus GPL/AGPL; leaning MIT for adoption.
- **Name:** Apache Wicket is a minor clash, wicket.app is for sale and the plain GitHub org is taken. Trademark check before going public.
- **Interpreters on live queries:** Python answers in about 12 ms warm; Node and heavier imports aren't measured.
- **"Extensions in seconds" oversells it:** an agent build takes a minute or more. The promise is "one sentence, no code".
