# Wicket

A small, fast, native macOS launcher whose extensions are written by agents. Read [CONCEPT.md](CONCEPT.md) first: it holds the thesis, scope, principles and decisions. [ROADMAP.md](ROADMAP.md) is the living plan with every workstream and its status. [docs/architecture.md](docs/architecture.md) is the shape of the code and how to add a feature: read it before touching `Sources/`.

- Stack: Swift 6, AppKit + SwiftUI, macOS 26+. No WebViews, no third-party dependencies without a concrete need.
- Keep the core small; anything that can be an extension should be one.
- Concise code, clean architecture, no remains (owner): when a change supersedes a design, delete the old code, settings, tests, docs and comments in the same change. Prefer deleting to adding; an abstraction needs two real users. After each product pivot the lead runs a tech-debt audit and lands its cleanup before new features pile on.
- Measure performance (hotkey-to-visible, query latency, idle memory) when touching hot paths.
- Question the product before building it: for new user-facing work, get an unanchored product challenge first (see ROADMAP's cross-cutting rules). If a brief hands you a design that exposes internal distinctions to the user, say so before building.
- Design first, then compare: work out our own approach, check how Tinycast (and Vicinae if relevant) does it before building, then pick the better one on the merits. Never copy their code (see "Reference policy" in CONCEPT.md).
- Prefer the newest Apple APIs (SwiftUI, Observation, Liquid Glass, Swift Testing) over hand-written code; use older APIs only where nothing modern works, with a comment saying why.
- When a decision is made, record the call and its reason in CONCEPT.md in a few lines; mechanism (types, flows, how it works) goes in docs/architecture.md, never in CONCEPT.md. ROADMAP.md is owned by the lead: delegated builders report status in their final message instead of editing it (parallel edits kept conflicting).
- Stage files by name (`git add <paths>`), never `git commit -a` or `git add -A` on main: the owner may have uncommitted work in the tree.
- Never log query text, file paths or AI content publicly (`privacy: .public`); counts and timings only.

## Commands

- Full [script and opt-in check reference](docs/architecture.md#developer-commands-and-opt-in-checks), including off-screen snapshots, live agent evaluations and benchmarks.
- Once per clone: `git config core.hooksPath Scripts/hooks`, so every commit runs `Scripts/check.sh`.
- Land a builder's branch with `Scripts/land.sh <commits>`: it cherry-picks, then runs the full check, since parallel branches can each pass and still break together.

- Check (definition of done): `Scripts/check.sh` builds with warnings as errors, runs the tests and lints formatting against `.swift-format`. It must pass before a commit. Fix formatting with `swift format format --in-place --recursive Sources Tests Package.swift`.
- Test: `swift test` (pure logic in `Sources/WicketCore`).
- Build and bundle: `Scripts/build-app.sh` (release config) or `Scripts/build-app.sh debug`, producing `build/Wicket Dev.app`: Wicket Dev runs beside an installed Wicket with ⌃⌥Space, `~/.config/wicket-dev` and its own Application Support folder. The released app comes only from `Scripts/release.sh` (docs/release.md).
- Settings: `~/.config/wicket/settings.json` (`~/.config/wicket-dev` for Wicket Dev), reloaded live; point `WICKET_CONFIG_DIR` at another folder to test without touching the real one.
- Perf log: `/usr/bin/log stream --predicate 'subsystem == "app.wicket"'` (zsh has a `log` builtin, so use the full path).
- On-screen checks with synthetic keys (`Scripts/bench/keys.swift`) can be swallowed by another app's keyboard event tap (Raycast's, seen 2026-11-06): if a chord never arrives even at a minimal Carbon test program, the cause is outside Wicket; list taps with `CGGetEventTapList` and never type plain keys unless the palette is confirmed key, or they land in the front app.
- Builders never launch the app (no `swift run Wicket`, no opening a built bundle): a second copy puts another menu bar icon and update errors on the owner's screen. Only the lead launches builds, when the owner says the Mac is free.
- Latency benchmark: `Scripts/bench/hotkey-latency.swift`. It posts real keystrokes and takes over the screen, so only run it when the user says the Mac is free.
