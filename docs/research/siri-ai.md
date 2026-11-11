# Siri AI on macOS 27 and what it means for Wicket

Researched 10 Nov 2026 from Apple documentation and reviews. Claims about Apple's roadmap are inference.

## What shipped

- Siri AI rolled out as a beta on 14 Sep 2026. M1 or later; the larger on-device model and advanced dictation need M3 or later with 12 GB.
- Languages: English, French, Japanese, Korean, Portuguese, Spanish. German is absent.
- It is integrated into Spotlight: Command-Space opens Spotlight, and a typed question becomes a Siri conversation with follow-ups. There is also a separate Siri app with history, a menu bar entry, and Shift-Command-Space to ask about the active window.
- It can use screen context, search mail, messages, photos and calendar, answer from the web, and act in apps that support it.
- Models: Apple's on-device and Private Cloud Compute models. ChatGPT is a selectable external extension. Claude is not selectable. No public way was found to plug a coding agent or an MCP host into Siri.
- Spotlight itself keeps app and file search, clipboard history, hundreds of actions, quick keys and Shortcuts.
- Reviews: useful conversations but terse answers; AI-built Shortcuts refuse tasks outside existing actions. No reliable latency numbers.

## Where Wicket overlaps and loses

- "One surface for launching and asking" is no longer a difference. Spotlight does that now.
- File search, clipboard history and a catalogue of app actions: Spotlight is broader. Not worth rebuilding without a proven need.
- Personal and on-screen context: Apple has privileged access a third-party app does not get.

## Where Wicket is different

- The user's own coding agents (Claude Code, Codex) with their existing subscriptions, one hotkey away, by typing or speaking.
- The loop from a request to a reusable extension: the agent writes a plain program, the user approves it, and it becomes a command.
- Everything is files: config, instructions, styles, extensions.
- Works in German and any language the agents handle.

## What Wicket could use from the system

| Idea | Effort | What it gives |
| --- | --- | --- |
| Keep Apple's on-device speech (already used) | Low | Dictation with no model to ship |
| Expose Wicket commands through App Intents | Low to medium | Wicket's commands appear in Spotlight and Siri |
| Run the user's Shortcuts as an extension bridge | Medium | Access to app actions without building them |
| On-device Foundation Models for small tasks | Medium | Fast classification or summaries, off the typing path |

A third-party launcher cannot list and run other apps' intents in general, and cannot inherit Siri's screen and personal context.

## Recommendations

1. Position Wicket as the launcher for your existing coding agent and the tools it creates. Show the request-to-extension loop.
2. Keep app launching and math fast and predictable, as foundations and not as the headline. Do not rebuild Spotlight's file index, clipboard history or action catalogue.
3. Make extension approval and inspection exceptionally clear. It is central to trust.
4. Keep voice optional and measure it.
5. Use Apple integrations selectively: App Intents outward and a Shortcuts bridge before any large app-action layer.
