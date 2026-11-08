# Wicket

A small, fast, native macOS launcher whose extensions are written by agents.

Press ⌥Space and Wicket opens apps, files, a calculator with units and currencies, typed web addresses, and an AI that answers questions or does things through the coding agent you already use. Ask it to "build a command that shows the weather" and your agent writes a Wicket extension; you review it and turn it on. No WebViews, no Node runtime, about 20 MB of memory at idle.

> **Alpha.** This is an early 0.0.x release: expect rough edges, missing features and settings that change between versions. Bug reports are welcome as GitHub issues.

## Install

With Homebrew:

```sh
brew install --cask pietz/wicket/wicket
```

Or download `Wicket-<version>.dmg` from the [latest release](https://github.com/pietz/wicket/releases/latest), open it and drag Wicket to Applications. Wicket updates itself; you can check by hand from its menu bar icon or Settings ▸ General.

## Requirements

- macOS 26 (Tahoe) or later.
- For the AI: [Claude Code](https://claude.com/claude-code) or [Codex](https://github.com/openai/codex), signed in on your own subscription. Wicket runs them on your Mac; Settings ▸ AI picks one (Claude or ChatGPT), its model, effort and speed. What the agent may do without asking is its own setting: `permissions.defaultMode` in `~/.claude/settings.json` (`default` asks, `acceptEdits` allows edits, `auto` decides by itself), or `approval_policy` and `sandbox_mode` in `~/.codex/config.toml`. When it asks, Wicket shows the question with Allow and Deny. Everything else works without any AI.

## Privacy

- No accounts, no telemetry, no analytics.
- Wicket itself only goes online to check for updates (one request for a public file on GitHub, which you can turn off in Settings ▸ General) and for currency rates in the calculator.
- What you send to the AI goes to the agent you chose, under that agent's own terms. Opened from Finder, Wicket tells it which files you had selected, only if you gave it permission to read Finder's selection.
- Voice input is off until you turn it on, and transcribes on your Mac.
- Extensions are programs on your Mac. Each one, and each change to it, runs only after you review and enable it.

## Settings and extensions

Settings live in `~/.config/wicket/settings.json`, plain JSON that you or an agent can edit; the Settings window writes the same file. Extensions live in `~/Library/Application Support/Wicket/Extensions`. To write one by hand, see [docs/extensions.md](docs/extensions.md). Run Agent tells your agent about Wicket with rules built into the app ([Resources/agent.md](Resources/agent.md)), then adds your own instructions from `~/.config/wicket/agent.md`, which Settings ▸ AI ▸ Edit Agent Instructions opens.

## Build from source

You need Xcode 26 or later (Swift 6.2).

```sh
git clone https://github.com/pietz/wicket
cd wicket
Scripts/build-app.sh
open "build/Wicket Dev.app"
```

This builds **Wicket Dev**, which runs beside an installed Wicket: ⌃⌥Space instead of ⌥Space, its own settings (`~/.config/wicket-dev`) and data folders, and no updates. `Scripts/check.sh` builds with warnings as errors, runs the tests and checks formatting. [CONCEPT.md](CONCEPT.md) explains the ideas and decisions, [docs/architecture.md](docs/architecture.md) the code, and [docs/release.md](docs/release.md) how releases are made.
