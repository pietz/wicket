# Wicket

A small, fast, native macOS launcher with your own AI agent built in, and extensions that agent writes. There is no spec: the code and its comments say how things work and why. [README.md](README.md) is the user guide, [ROADMAP.md](ROADMAP.md) the agreed work in order, [ISSUES.md](ISSUES.md) the open problems, `Sources/WicketApp/Resources/extension-contract.md` the extension interface (for authors and the in-app agent), [docs/manual-checks.md](docs/manual-checks.md) the hands-on checklist and [docs/release.md](docs/release.md) the release runbook.

## Layout

- `Sources/WicketApp`: the app as one library module, so tests can `@testable import` it. `Sources/Wicket/main.swift` is the thin executable: headless mode for `--` arguments, otherwise the app.
- `Sources/WicketApp/Resources`: answer stylesheet, bridge script, `agent-instructions.md` (sent with every question), the extension contract and the examples, found through `Bundle.wicket`.
- `Sources/Extensions`: the bundled extensions (calculator, units, window, shell), one executable target each in plain Swift without Foundation, plus the shared `Shared/JSON.swift`; `build-app.sh` puts each binary with its manifest and source in `Contents/Resources/Extensions`.
- `Tests/WicketTests`: headless tests with fakes at the hardware edges (voice, agent, hotkey); recorded agent streams in `Fixtures/`.
- `Resources`: Info.plist, entitlements and icons. `Scripts`: `check.sh`, `build-app.sh`, `release.sh`, `land.sh`, `verify-session.sh`, `hooks/`. `appcast.xml` and `Casks/wicket.rb` are the update feed and the Homebrew cask, written by `release.sh`.

## Rules

- Stack: Swift 6, AppKit + SwiftUI, macOS 26+. Dependencies: swift-cmark and Sparkle (exact 2.10.1). No WebViews beyond the answer renderer, nothing else without a concrete need. Prefer the newest Apple APIs (SwiftUI, Observation, Liquid Glass, Swift Testing); use older ones only where nothing modern works, with a comment saying why.
- Concise code, clean architecture, no remains: when a change supersedes a design, delete the old code, settings, tests, docs and comments in the same change. Prefer deleting to adding; an abstraction needs two real users. Comment only the non-obvious why, especially where a reader would otherwise "fix" something deliberate.
- Core is what must stay alive between keystrokes, hold a macOS permission, or be the frame (panel, input, voice, Settings, the agent harness, the extension host, and the apps, files and clipboard sources). Anything that turns input into a screen is an extension.
- The fast path never waits: typing never starts a model, root typing starts a process only for a matching extension pattern, and nothing reruns an open command behind the user's back.
- Results are ordered by match quality, never by a user-set source order; learned usage only breaks ties within a tier. One ranking function serves the panel and headless mode.
- Native frame, HTML content: the input, root list, Settings and glass shell are SwiftUI and AppKit and not themeable; answers and extension pages are one sandboxed web page styled by `theme.css`. JSON `items` (for programs) and `<row>` tags (for pages and the agent) are two spellings kept on purpose.
- Enabled means trusted: an extension runs when its source is on, with no approval step; the agent CLI's own permission prompts are the gate. Only a `submitted` request may have an effect; addresses name views, never effects, and a URL never carries arguments.
- Wicket runs the user's installed `claude` and `codex` CLIs, one process per question that resumes the session; nothing runs between questions, and there is no model loop of our own.
- Keys have one meaning each: Return does the selected thing, ⌘Return asks the agent, Tab moves into argument fields, Escape goes back one step.
- `config.json` is the only settings store, written through one path that preserves unknown fields. Private state the agent must not read (clipboard and agent history) lives in `Edition.privateDirectory()`, outside the working folder.
- Edition-dependent behavior (folder, hotkey, updates, name) goes through `Edition`; the working folder is resolved only by `Edition.configDirectory()`. Files from 0.0.x are never read as new data and never deleted.
- What the agent needs only when writing an extension goes in the contract, not in the instructions sent with every question. If building an extension needs a long explanation, change the design, not the prompt.
- Handle failures that realistically happen in real use. No handling for contrived timing combinations or for failures of the error handling itself.
- Performance: optimise only what a user could feel or see. Measure hot paths (hotkey to visible, query latency, idle memory) when touching them.
- Question the product before building it: for new user-facing work, get an unanchored product challenge first. Design first, then compare with other launchers on the merits; never copy their code.
- Every change that lands gets an independent review. Reviews report only bugs with a plausible real-world path; the rest are notes, never blockers.
- Never log query text, file paths or AI content publicly (`privacy: .public`); counts and timings only.
- Stage files by name (`git add <paths>`), never `git commit -a` or `git add -A`: the owner may have uncommitted work in the tree.
- Docs state only what is true now or agreed next, each fact in the one file that owns it. When a decision supersedes text, rewrite or delete that text in the same change; no dated narratives, history lives in git. A behavior change updates `agent-instructions.md`, the contract, the examples and affected tests with it.

## Commands

- Once per clone: `git config core.hooksPath Scripts/hooks`; the hook runs `Scripts/check.sh` for commits that stage Swift, `Package.swift` or `.swift-format` files.
- Check (definition of done): `Scripts/check.sh` builds with warnings as errors, runs the tests and lints formatting (2 spaces, 110 columns). It must pass before a commit. Fix formatting with `swift format format --in-place --recursive Sources Tests Package.swift`.
- Test: `swift test`. Opt-in tests (offscreen captures, reply captures, live agents, query latency) say how to run them at their definition: `panelCapture`, `replyCapture`, `liveAgentScratchConversation`, `queryLatency`.
- Land a builder's branch with `Scripts/land.sh <commits>`: it cherry-picks, then runs the full check, since parallel branches can each pass and still break together.
- Build: `Scripts/build-app.sh` produces `build/Wicket Dev.app` (⌃⌥Space, `~/.config/wicket-dev`, no updates, runs beside an installed Wicket); `--release` produces the signed `build/Wicket.app` for `Scripts/release.sh` ([docs/release.md](docs/release.md)). Never push, tag or release without the owner.
- Headless: `Wicket --extension ID --input TEXT` or `Wicket --query TEXT` inside a bundle, always with `WICKET_CONFIG_DIR` pointing at a temporary folder when testing.
- Perf log: `/usr/bin/log stream --predicate 'subsystem == "app.wicket"'` (zsh has a `log` builtin).
- Builders never launch the app (no `swift run Wicket`, no opening a bundle), show no window, play no audio, open no microphone, take no screenshots and send no synthetic input: a second copy puts another menu bar icon on the owner's screen. The owner tries Dev builds by hand; `Scripts/verify-session.sh` is the checklist for a lead-run session when the owner says the Mac is free.
- Do not touch `~/.config/wicket*`, `~/Library/Application Support/*Wicket*`, `/Applications/Wicket.app` or running Wicket processes while testing.
