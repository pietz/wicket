# Settings

The menu bar icon's menu offers **Settings…** (Cmd+, while Wicket is active), as does typing `settings` in the launcher. **Open Config Folder** is a secondary action. The window is an AppKit toolbar tab controller with native SwiftUI grouped forms, 560 by 480 points of pane content. It keeps its selected tab while open, and closing it returns the app to accessory mode. The main menu provides Cmd+W and Cmd+Q. [SPEC.md](../SPEC.md) has the full rules.

## Tabs

- **General:** shortcut recorder with registration conflict feedback, background transparency, Text size (Small to Larger), launch at login and config-folder access. In the released edition, an Updates section: a switch for automatic checks, the version and **Check for Updates…** (Sparkle; absent in Wicket Dev and outside an app bundle). Launch at login reads `SMAppService.mainApp.status` and is not a config key; pending approval links to Login Items, and registration failures show the macOS error with a note that ad hoc builds may be refused.
- **Voice:** `voice.enabled`, the Microphone picker (Automatic or a named input, stored by UID), microphone permission state and a System Settings link. Permission is read without requesting it, and opening the tab never listens.
- **Agent:** Claude or ChatGPT, model, effort, permission mode, speed and Stream answers. Choices come from what each installed CLI lists, asked without a model call when the tab opens and cached per agent for an hour in `agent-options-claude.json` and `agent-options-codex.json`. Saved values survive a failed listing. Switching agent clears the model, effort, mode and speed of the previous one and keeps unknown fields.
- **Sources:** on/off switches for math, apps, files and each discovered extension, and the extensions folder. Results are ranked by match quality, so there is no order to set. Below them, Clipboard history: its switch (`clipboard.enabled`, off by default), a hint when macOS would ask before each pasteboard read, the number of saved texts and Clear History with a confirmation. Limits and excluded apps are edited in `config.json`.

## One write path

`config.json` is the single source of truth, with no UserDefaults copy. `ConfigurationFile.edit` is the only way settings are written: it reads the latest bytes, validates them with `Configuration`, patches the JSON object, validates the result and replaces the file atomically. Unknown root, nested and provider-entry fields survive, as does the provider list as written. `ConfigurationStore` publishes the last good configuration and the same `Config: …` problem the launcher shows. An exact-file watcher, including atomic replacement, reloads on outside edits; a second one reloads the agent-options cache. A broken file stays untouched with its last good values visible, editing disabled and the config-folder button and tabs usable; repairing it restores editing live. A failed write shows its own message and leaves the controls usable.

Updates are the exception on purpose: Sparkle's switch lives in Sparkle's user defaults, because it is the app's housekeeping rather than a preference an agent should edit.

## Shortcut recording

Recording uses a local raw-key monitor, so Option combinations and command equivalents survive, and pauses Wicket's global registration. Escape, app deactivation, leaving the pane or closing the window stops it. A replacement is registered before it is saved: a conflict keeps the previous working registration and file value with feedback in Settings, and a failed save restores the previous registration. Command plus a single letter is refused. `PaletteHotKey.apply` produces the feedback and tests inject fake registration handles.
