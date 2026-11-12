# Wicket

A small, fast, native macOS launcher with your own AI agent built in, and extensions that agent writes. [SPEC.md](SPEC.md) is the design and its rationale: read it before touching `Sources/`. [README.md](README.md) is the user-facing reference, [ISSUES.md](ISSUES.md) lists open problems and unverified checks, [ROADMAP.md](ROADMAP.md) what is next, and [docs/](docs) holds the settings, provider contract and release notes plus comparisons and research.

## Layout

- `Sources/WicketApp`: everything (AppKit shell, panel, providers, agent, extensions, voice, settings, `Edition`, `Updater`). One library module so tests can `@testable import` it. `Sources/Wicket/main.swift` is the thin executable: headless mode for `--` arguments, otherwise the app.
- `Sources/WicketApp/Resources`: answer stylesheet, bridge script, agent instructions, extension contract and the bundled units extension, found through `Bundle.wicket`.
- `Tests/WicketTests`: headless tests with fakes at the hardware edges (voice, agent, hotkey); recorded agent streams in `Fixtures/`.
- `Resources`: Info.plist, entitlements and icons for the app bundle. `Scripts`: `check.sh`, `build-app.sh`, `release.sh`, `land.sh`, `verify-session.sh`, `hooks/`. `appcast.xml` and `Casks/wicket.rb` are the update feed and the Homebrew cask, written by `release.sh`.

## Rules

- Stack: Swift 6, AppKit + SwiftUI, macOS 26+. Dependencies: swift-cmark and Sparkle (exact 2.10.1). No WebViews beyond the answer renderer, nothing else without a concrete need.
- Keep the core small; anything that can be an extension should be one.
- Concise code, clean architecture, no remains: when a change supersedes a design, delete the old code, settings, tests, docs and comments in the same change. Prefer deleting to adding; an abstraction needs two real users.
- Prefer the newest Apple APIs (SwiftUI, Observation, Liquid Glass, Swift Testing) over hand-written code; use older APIs only where nothing modern works, with a comment saying why.
- Measure performance (hotkey to visible, query latency, idle memory) when touching hot paths.
- Question the product before building it: for new user-facing work, get an unanchored product challenge first. Design first, then compare with other launchers on the merits; never copy their code.
- Record decisions and mechanism in SPEC.md, planned work in ROADMAP.md, open problems in ISSUES.md. Keep them current in the same change that alters behavior.
- Stage files by name (`git add <paths>`), never `git commit -a` or `git add -A`: the owner may have uncommitted work in the tree.
- Never log query text, file paths or AI content publicly (`privacy: .public`); counts and timings only.
- Edition-dependent behavior (folder, hotkey, updates, name) goes through `Edition`; the working folder is resolved only by `Edition.configDirectory()`. Existing files from 0.0.x in the config folder and Application Support are never read as new data and never deleted.

## Commands

- Once per clone: `git config core.hooksPath Scripts/hooks`, so every commit runs `Scripts/check.sh`.
- Check (definition of done): `Scripts/check.sh` builds with warnings as errors, runs the tests and lints formatting against `.swift-format` (2 spaces, 110 columns). It must pass before a commit. Fix formatting with `swift format format --in-place --recursive Sources Tests Package.swift`.
- Test: `swift test`. Opt-in: `WICKET_CAPTURE_DIR=<folder> swift test --filter panelCapture` (offscreen captures), `WICKET_REPLIES=<file.json> WICKET_CAPTURE_DIR=<folder> swift test --filter replyCapture` (answers from `[question, reply]` pairs, then an optional text size and keys such as `down` or `return` to select a target or open a detail, for design work) and `WICKET_LIVE_AGENT=1 swift test --filter liveAgentScratchConversation` (real CLIs in scratch folders).
- Land a builder's branch with `Scripts/land.sh <commits>`: it cherry-picks, then runs the full check, since parallel branches can each pass and still break together.
- Build: `Scripts/build-app.sh` produces `build/Wicket Dev.app` (⌃⌥Space, `~/.config/wicket-dev`, no updates, runs beside an installed Wicket); `Scripts/build-app.sh --release` produces the signed `build/Wicket.app` for `Scripts/release.sh`. The released app comes only from `release.sh` ([docs/release.md](docs/release.md)); never push, tag or release without the owner.
- Headless: `Wicket --query TEXT` or `Wicket --extension ID --input TEXT` inside a bundle, always with `WICKET_CONFIG_DIR` pointing at a temporary folder (never the real one) when testing.
- Settings: `~/.config/wicket/config.json` (`~/.config/wicket-dev` for Wicket Dev), reloaded live.
- Perf log: `/usr/bin/log stream --predicate 'subsystem == "app.wicket"'` (zsh has a `log` builtin, so use the full path).
- Builders never launch the app (no `swift run Wicket`, no opening a built bundle), show no window, play no audio, open no microphone, take no screenshots and send no synthetic input: a second copy puts another menu bar icon and update prompts on the owner's screen. Only the lead launches builds, when the owner says the Mac is free; `Scripts/verify-session.sh` is the checklist for that.
- Do not touch `~/.config/wicket*`, `~/Library/Application Support/*Wicket*`, `/Applications/Wicket.app` or running Wicket processes while testing.
