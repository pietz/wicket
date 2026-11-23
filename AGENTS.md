# Wicket

A small, fast, native macOS launcher with your own AI agent built in, and extensions that agent writes. There is no separate spec: the code and its comments explain how and why. Doc ownership: [README.md](README.md) (user guide), [ROADMAP.md](ROADMAP.md) (agreed upcoming work), [docs/extensions/README.md](docs/extensions/README.md) (official extension specs and shared decisions), [docs/wicket-js.md](docs/wicket-js.md) (JS runner internals), [ISSUES.md](ISSUES.md) (open problems), `Sources/WicketApp/Resources/extension-contract.md` (extension interface), [docs/manual-checks.md](docs/manual-checks.md) (hands-on checklist), [docs/release.md](docs/release.md) (release runbook).

## Layout

- `Sources/WicketApp`: library module (`@testable import` in tests). `Navigator` owns screens (root, command, agent), transitions, and key/Return handling, talking to the panel only via `PaletteSurface` (draw committed `PalettePresentation`, measure pages, system effects). Command rules live in `CommandScreenBehavior` (resolved by `CommandDirectory`: extension or host command); each visit holds its state (`CommandScreen`, `Screen`). `PaletteController` owns the window, rendering, frame, and system effects; `PanelInput` routes typed/spoken input and owns voice; `LauncherModel` composes services; `AppDelegate` applies config in order (services, hotkeys, status item). `Sources/Wicket/main.swift` is the thin executable (headless for `--` args, else app).
- `Sources/WicketApp/Resources`: `answers.css`, `bridge.js`, `theme-template.css`, `agent-instructions.md` (sent on every Claude turn; on Codex thread start), `extension-contract.md`, and `examples/`, loaded via `Bundle.wicket`.
- `Sources/WicketJS`: the bundled `wicket-js` JavaScriptCore runner executable (`Contents/MacOS/wicket-js`).
- `Sources/ObjCBoundary`: Objective-C exception boundary for private KVC calls (`GlassBlur`).
- `Sources/Extensions`: bundled Swift extensions (`calculator`, `units`, `links-search`, `web`, `window`, `shell`), one executable target each with shared code in `Shared/`. `build-app.sh` copies each binary, manifest, and source into `Contents/Resources/Extensions`.
- `Tests/WicketTests`: headless tests with hardware-edge fakes (voice, agent, hotkey, Spotlight) and recorded streams in `Fixtures/`. Drive conversations through `Navigator` (never the session directly) and use `RecordingSurface`.
- `Resources`: `Info.plist`, entitlements, icons. `Scripts`: `check.sh`, `build-app.sh`, `release.sh`, `land.sh`, `hooks/`. `appcast.xml` and `Casks/wicket.rb` are updated by `release.sh`. `tools/glass-lab`: standalone surface sandbox (`swift run` there; outside app and check).

## Rules

- Stack: Swift 6, AppKit + SwiftUI, macOS 26+. Dependencies: `swift-cmark` and `Sparkle` (exact 2.10.1). No WebViews beyond the answer renderer; no new dependencies without a concrete need. Prefer modern Apple APIs (SwiftUI, Observation, Liquid Glass, Swift Testing); use older APIs only where nothing modern works, with a comment saying why.
- Concise code, clean architecture, no remains: delete superseded code, settings, tests, docs, and comments in the same change. Prefer deleting to adding; an abstraction needs two real users. Comment only the non-obvious *why*, especially where a reader would otherwise "fix" something deliberate.
- Core owns what must stay alive between keystrokes, hold a macOS permission, or be the frame (panel, input, voice, Settings, agent harness, extension host, and apps/files/clipboard sources). Everything that turns input into a screen is an extension.
- Fast path never waits: typing never starts a model, root typing starts a process only for matching `match` patterns, and nothing reruns an open command behind the user's back.
- Results rank by match quality, never user-set source order; learned usage breaks ties only within a tier. One ranking function serves panel and headless mode.
- Native frame, HTML content: input, root list, Settings, and glass shell are SwiftUI/AppKit (not themeable); answers and extension pages are one sandboxed HTML page styled by `theme.css`. The HTML canvas is a settled decision (revisit only if concrete negatives accumulate). Native frame keeps keystrokes and focus in AppKit. JSON items give programs stable IDs and multiple actions; Markdown tags let the agent place actions inline.
- Enabled means trusted: extensions run when enabled, with no approval step and with the user's access. CLI permission mode governs its own tool calls. Extension programs must gate user-visible effects on `submitted:true` and require an explicit action for effects the user should review. URL addresses only open views (`submitted:false`, no `fields` or `action`; optional `input` only).
- The agent is the remote control: everything reachable in Settings (settings, hotkeys, extensions, future catalog installs) works through plain files or headless commands on the same path as the UI.
- Wicket runs the user's `claude` and `codex` CLIs, one process per question resuming the session; nothing runs between questions, and there is no custom model loop.
- Keys have one meaning each: Return runs the selection, ⌘Return asks the agent, Tab moves into argument fields, Escape steps back.
- `config.json` is the only settings store, written through one path preserving unknown fields. Keep Clipboard History and Agent History outside the working folder in `Edition.privateDirectory()`.
- Edition-dependent behavior (folder, hotkey, updates, name) goes through `Edition`; resolve the working folder only via `Edition.configDirectory()`. Never read 0.0.x files as new data and never delete them.
- Put extension-authoring details in `extension-contract.md`, not `agent-instructions.md`. If authoring needs a long explanation, simplify the design instead of the prompt.
- Handle realistic failures only; no scaffolding for contrived timing races or failures of error handling itself.
- Performance: optimize only what users can feel or see. Measure hot paths (hotkey to visible, query latency, idle memory) when changing them.
- Product & review workflow: challenge new user-facing work unanchored first. Every decision brought to the owner carries an independent opinion from Gemini 4 Neon (high thought) alongside the lead's recommendation. Design first, then compare with other launchers on merit; never copy their code. GPT-6.2 Sol (high effort) implements one topic at a time; GPT-6.2 Astra independently reviews every landed change, reporting only bugs with a plausible real-world path (everything else is a non-blocking note).
- `GlassBlur` patches one private Core Animation filter input (`inputBlurRadius` on `glassBackground` inside `NSGlassEffectView`). Keep every step optional so any missing class/filter/key/value leaves plain clear glass with no crash and no logging. Route all KVC calls on the private filter through `Sources/ObjCBoundary`. Recheck on each new macOS.
- Never log query text, file paths, or AI content with `privacy: .public`; counts and timings only.
- Stage files by name (`git add <paths>`), never `git commit -a` or `git add -A`: the owner may have uncommitted work in the tree.
- Docs state only what is true now or agreed next, one owner per fact. Rewrite or delete superseded text in the same change; no dated narratives (history lives in git). Behavior changes update `agent-instructions.md`, `extension-contract.md`, examples, and tests together.

## Commands

- Hook (once per clone): `git config core.hooksPath Scripts/hooks` (runs `Scripts/check.sh` when staging Swift, `Package.swift`, or `.swift-format`).
- Check (definition of done, required before commit): `Scripts/check.sh` (build with warnings as errors, tests, format lint: 2 spaces, 110 columns). Auto-format: `swift format format --in-place --recursive Sources Tests Package.swift`.
- Test: `swift test`. Opt-in tests document how to run at their definitions: `panelCapture`, `replyCapture`, `liveAgentScratchConversation`, `queryLatency`.
- Land a branch: `Scripts/land.sh <commits>` (cherry-picks and runs full check).
- Build: `Scripts/build-app.sh` → `build/Wicket Dev.app` (⌃⌥Space, `~/.config/wicket-dev`, no updates); `--release` → signed `build/Wicket.app` for `Scripts/release.sh` ([docs/release.md](docs/release.md)). Never push, tag, or release without the owner.
- Headless: `Wicket --extension ID --input TEXT` or `Wicket --query TEXT` inside a bundle, with `WICKET_CONFIG_DIR` pointing at a temporary folder.
- Perf log: `/usr/bin/log stream --predicate 'subsystem == "app.wicket"'` (`log` is a zsh builtin).
- Builders never launch the app (`swift run Wicket` or opening a bundle), show windows, play audio, open the mic, take screenshots, or send synthetic input. The owner runs hands-on checks via [docs/manual-checks.md](docs/manual-checks.md).
- Never touch `~/.config/wicket*`, `~/Library/Application Support/*Wicket*`, `/Applications/Wicket.app`, or running Wicket processes while testing.
