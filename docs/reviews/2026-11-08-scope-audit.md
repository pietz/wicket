# Scope and tech-debt audit (2026-11-08, GPT-6.1 Sol, read-only at 7be6ff9)

Measured against the core in CONCEPT.md: AI through wrapped harnesses, files, calculator, apps, agent-built extensions and voice.

- **Lines today:** 19,447 production and 13,126 test (Swift).
- **Expected after the agreed cuts and the reply cleanup:** about 17,650 and 11,175, give or take 400.

## Extras

- **Prompt commands and Save as Command:** about 300 production and 430 test lines. Remove.
- **Selected-text capture:** about 150 and 150. Simplify to the Finder-folder handoff.
- **Shortcuts pane, aliases and per-command hotkeys:** about 700 and 650. Remove.
- **Start Listening command:** about 37 lines. Remove; the mic button and ⌘L stay.
- **Features pane:** about 160 and 220. Simplify to the AI and Voice controls.
- **Links:** 72 and 62. Keep.

## Remains

- **The unused JSON reply stack:** ReplySchema, AgentOutput, the schema, fixtures and the agent-only wire branches, about 539 Swift lines plus 379 lines of schema. Being deleted by markup M1.
- **The summary, facts and Read Summary architecture:** retire it after markup lands.
- **Helpers used only by tests:** `Screen.text`, `SettingsStore.hotKeyFailed`, `CalculatorResult.isAnswer`, the alias helpers, and the unused signposter in Perf.
- **Duplicated binding-collision logic:** it goes with the binding removal.
- **Stale text:**
  - the gallery JSON still mentions ⌘[;
  - a Voice.swift comment describes Escape wrongly;
  - architecture.md describes the structured output as live, still lists web search and Apple, and ROADMAP has old entries;
  - CONCEPT has superseded prompt and binding decisions, and GeneralPane's copy is inaccurate;
  - `webSearch.url` is still carried along silently.

## Order

1. JSON stack: M1.
2. Summary and facts.
3. Prompt commands.
4. Bindings and the Shortcuts pane.
5. Selected-text capture.
6. The Features pane.
7. Docs and dead helpers.
