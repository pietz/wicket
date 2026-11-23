# Official extensions

The first official extensions, the decisions they share, and the order to build them in. Each extension has its own spec in this folder: the experience it aims for, how it is built, and the gaps in today's framework. Wicket-wide work is in [ROADMAP.md](../../ROADMAP.md); this file owns only what is specific to official extensions. When an extension ships, its spec becomes its README in the catalog and leaves this folder.

## Tier 1: on by default, each can be switched off

| Extension | Spec | What it is |
|---|---|---|
| Calculator | [calculator.md](calculator.md) | Arithmetic as you type at the root. Deliberately an extension, so its behavior can be changed. |
| Convert | [convert.md](convert.md) | Units and currency, with a rate source the user can replace. Handles single quantities. Typed arithmetic with units and currencies is later work. |
| Links & Search | [links-search.md](links-search.md) | Shipped in the app. Site searches and bookmarks, with a separately switchable Search the Web fallback. |
| Window Manager | [window-manager.md](window-manager.md) | A small engine that moves windows, plus layouts the agent writes ("on ⌃⌥1, Safari left two-thirds"). |
| Calendar | [calendar.md](calendar.md) | Upcoming meetings from macOS Calendar, with details and Join. |

**Parked:** System (macOS actions and settings, [system.md](system.md)). Its permissions need more discussion first: Automation and permission checks per action. Neither is built until System returns.

Tier 2, not yet specified: Snippets, Capture, Processes & Ports, and Monitor. Clipboard History stays in core because it has to watch the clipboard constantly.

## Decisions every spec follows

The user's additions, such as bookmarks, site searches, window layouts or calculator constants, go in `extensions/<name>/user.json` in the working folder. Installed extensions keep `wicket.json` there too. Built-ins use the manifest in the app bundle. Catalog updates replace the extension's own files and never touch `user.json`. Settings stay in Wicket's single `config.json`. An extension that needs a key reads it from the Keychain.

**Existing mechanisms first.** A hotkey, a saved definition or a custom action is a manifest item with a `run` action, `hidden` where its effect is its own feedback. A spec adds a core mechanism only when items, `run`, fields and pages cannot do the job, and only with two real users.

**Native frame, HTML pages.** The search bar, the result list, Settings and the glass shell are native. Every page is an HTML canvas page: agent answers, extension pages, onboarding and the catalog.

**Enabled means trusted.** A new extension is enabled when it appears, with a notice at the root. A confirmation step was considered and left out; it stays an option if real use shows a need.

**Permissions: Wicket holds them, extensions declare them, nobody asks twice.**
- **Declare, don't ask.** An extension lists what it needs in `permissions` and never prompts from its own program or a helper app.
- **Wicket holds every grant.** A child process uses Wicket's grant, so extension updates never re-prompt. A Developer ID–signed Wicket keeps its identity across updates. Ad-hoc–signed helpers re-prompt on every rebuild, which is the likely cause of the repeated Calendar prompts.
- **Ask during onboarding, optionally.** Onboarding (ROADMAP step 4) lists the permissions the picked extensions declare, each with one line on why, and a button: Allow where macOS can ask inline, or open the right System Settings pane and show a check once granted.
- **Ask in place on first use.** A permission still missing shows Wicket's own Allow row where the user already is.
- **Three checks on a real Mac** confirm "nobody asks twice" before Calendar builds on it:
  - a Developer ID release updated to the next release;
  - an extension the agent wrote in the working folder;
  - a headless read run from inside the agent's own sandbox.

**Extensions the agent writes run on every Mac.** Without Apple's developer tools, Swift and Python don't work on a Mac. So Wicket ships `wicket-js`, a JavaScript runner on the system's JavaScriptCore, and the agent writes JavaScript by default. Official extensions stay compiled Swift where they need macOS APIs.

## Shared work

Core and contract changes the specs need. The numbers stay fixed because the specs refer to them.

1. **A private data folder per extension.** Shipped: `WICKET_DATA_DIR`.
2. **Tab into an item's fields.** Shipped.
3. **Untrusted text stays inert.** Shipped: unknown tags show as literal text, and a view sent to the agent as context is marked as data.
4. **Patterns compile once.** Shipped.
5. **`user.json`.** Shipped. Additions are addressed as `?user-item=`, so they never collide with the extension's own items. For a built-in, the file lives in `extensions/<name>/user.json` in the working folder, alone, and the built-in keeps updating.
6. **Contract recipes.** Shipped, in the extension contract.
7. **`wicket-js`.** Step 1 shipped: the runner, `main(request)`, `wicket.read` and `wicket.write`, `console`. Step 2 adds `wicket.fetch` (method, headers, body; never in a root match), `wicket.run` (argv, `input`, catchable timeout; never in a root match), the Keychain recipe for API keys, and JavaScript as the agent's default. Design: [docs/wicket-js.md](../wicket-js.md).
8. **Meeting links.** `open` also accepts a short list of conferencing schemes, such as `zoommtg:` and `msteams:`, behind an explicit action.
9. **Saving a page's choices to `config.json`**, designed once with onboarding (ROADMAP step 4).
10. **The extension catalog** (ROADMAP step 3).
11. **Keyword, space, text.** Shipped. At the root, a command or item keyword followed by a space and text fills the first editable text field. The matching row ranks first and Ask agent stays in the list.

## Where each extension stands

- **Calculator:** phase 1 shipped (exact decimals, root row, `calc`, phone and date screening, locale copy).
- **Convert:** phase 1 shipped (units, ECB rates refreshed only on submitted requests, home currency, Rate details). Typed arithmetic with units is next.
- **Window Manager:** phases 1 to 3 shipped (verified moves, saved moves in `user.json`, Capture). Multi-window layouts are next.
- **Links & Search** ships with site searches and a web fallback. Add personal bookmarks and searches in `extensions/links-search/user.json`.
- **Calendar:** waits for the permission checks.
- **System:** parked.

## Next, in order

1. A documentation pass: every agent-facing and project doc checked against the code and made as short as it can be without losing anything the agent needs.
2. `wicket-js` step 2.
3. The catalog.
4. Calendar, once the owner has run the three permission checks on a real Mac.
