# Design map

Wicket is built from a few building blocks. Every feature should be one of them, or a combination; a feature that needs a new block argues for it openly. Each block names what it is and why it exists. Details stay with their owners ([extension contract](../Sources/WicketApp/Resources/extension-contract.md), [agent instructions](../Sources/WicketApp/Resources/agent-instructions.md), [AGENTS.md](../AGENTS.md)); this page only links.

## Building blocks

1. **Input.** One search field, typed or spoken. Typing never waits on a process or a model; results rank by match quality, and learned usage only breaks ties. *Why:* a launcher is judged by its first 100 ms.
2. **Extension.** A folder with `wicket.json` and, optionally, a program that answers one request per process. Reached by name, keyword, a `match` pattern, or as a fallback. *Why:* anything that turns input into a screen lives outside the core, in any language, written by the agent.
3. **Field.** A typed, named value (`text`, `number`, `bool`, `choice`) that travels as a string, asked for in the search bar, on a page, or in Settings. *Why:* one way to ask for a value everywhere.
4. **Item.** A row with an id, a title, and actions, from core sources (apps, files, clipboard), a manifest, a list, or a program's view. *Why:* stable ids make rows bindable to hotkeys, selectable across updates, and learnable by usage.
5. **Action.** What an item does: `open`, `reveal`, `copy`, `paste`, `run`, `agent`. `run` sends a request to an extension. *Why:* effects happen only on a submitted request; effects worth reviewing need a named action.
6. **Address.** A `wicket://` link to the root, an extension, an item, the agent, or Settings; it opens a view and never acts. *Why:* hotkeys, links, and the agent's follow-up rows all point at places the same way.
7. **View.** A program's answer: `items` (native list) and/or `body` (one HTML page in the page language). Agent answers use the same page language. *Why:* native frame for keys and focus, HTML for freely designed content.
8. **Setting.** A persisted value an extension declares: a field or a list of entries. Wicket draws it in Settings, stores it in `config.json`, and sends it with every request. *Why:* the extension declares, Wicket draws and saves.
9. **Hotkey.** Keys bound to an address. *Why:* any item or command, one keystroke away, without a running process.
10. **Permission.** Declared by an extension, held by Wicket. *Why:* macOS grants to the app, so only Wicket can hold one; declaring lets it check before launch.
11. **Agent turn.** One run of the user's `claude` or `codex` per question, resuming the session, with Wicket's instructions. Nothing runs between questions. *Why:* the user's own agent, no custom model loop.

## Boundaries

- **Core ↔ extensions:** core owns what must stay alive between keystrokes, hold a macOS permission, or be the frame (panel, input, voice, Settings, agent harness, extension host, and the apps, files, and clipboard sources). Everything that turns input into a screen is an extension.
- **Wicket ↔ extension:** manifest, request, view, actions, a private data folder; enabled means trusted. Details: [extension contract](../Sources/WicketApp/Resources/extension-contract.md).
- **Wicket ↔ agent:** the agent works only through plain files in the working folder and headless commands; it answers in the page language. Details: [agent instructions](../Sources/WicketApp/Resources/agent-instructions.md).
- **Wicket ↔ the user's files:** `config.json` is the only settings store, with one writer that keeps unknown keys; `theme.css` and `instructions.md` are the user's; histories and runtime records stay private outside the working folder.

## Checking a new feature

1. Which blocks does it use, and does it need a new one?
2. What does typing wait on? (The answer must be nothing.)
3. Can the agent do it through files or headless commands?
4. What does it delete?

## Where the map doesn't fit yet

- **Lists of personal entries.** Quicklinks and saved window moves are stored as raw launcher items in `extensions/<name>/user.json`, inside the extension's folder. Core has a Quicklinks special case to read them, and there is no editor. They should be settings (block 8).
- **Three dialects of fields.** Search-bar fields, page fields, and settings share types but not rules.
- **Small flags on items and actions** (`itemList`, `promptIfEmpty`, `user-item`, `hidden`, `submit`). Each solved a real case; together they are hard to learn. Check each against the blocks above.
