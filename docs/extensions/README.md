# Official extensions

Specs, shared decisions, and status for official extensions. Wicket-wide roadmap lives in [ROADMAP.md](../../ROADMAP.md); extension authoring rules live in the [extension contract](../../Sources/WicketApp/Resources/extension-contract.md). When an extension moves to the catalog, its spec becomes its catalog README and leaves this folder.

## Tier 1 (on by default, each switchable)

| Extension | Spec | Status | Summary |
| --- | --- | --- | --- |
| Calculator | [calculator.md](calculator.md) | Phase 1 shipped | Inline arithmetic with `=` for the full grammar. Programmer, date math, and History are planned. |
| Convert | [convert.md](convert.md) | Phase 1 shipped | Inline unit conversions offline and currency via Frankfurter. Typed arithmetic with units is planned. |
| Weather | [weather.md](weather.md) | Bundled | Current conditions and a five-day forecast by city. |
| Quicklinks | [quicklinks.md](quicklinks.md) | Shipped | Personal bookmarks and site searches with optional keywords and hotkeys. |
| Windows | [window-manager.md](window-manager.md) | Phases 1–3 shipped | Stock moves, verified readback, Capture, and saved moves in Settings; multi-window layouts next. |
| Caffeinate | [caffeinate.md](caffeinate.md) | Bundled | Keeps the Mac awake for a typed duration or until turned off. |
| Calendar | [calendar.md](calendar.md) | Version 1 bundled; owner's permission checks pending | Read-only 7-day EventKit agenda with Join and headless read. |

**Parked:** System ([system.md](system.md))—waiting on Automation and per-action permission design.
**Tier 2 (not yet specified):** Snippets, Capture, Processes & Ports, Monitor. Clipboard stays in core because it polls the pasteboard continuously.

## Decisions every spec follows

- **User data & settings:** Follow the contract’s compatibility rules for saved data and program state. API keys live in Keychain. [Extension contract](../../Sources/WicketApp/Resources/extension-contract.md#contract-evolution)
- **Built-in versions:** Bump `version` in `wicket.json` whenever the extension changes, including changes in a shared source it ships. Keep the version when copying a built-in so it records the base for merging. [Changing a built-in](../../Sources/WicketApp/Resources/extension-contract.md#changing-a-built-in)
- **Existing mechanisms first:** Prefer static items, `run` (`hidden:true` where appropriate), fields, and pages. Add a core mechanism only when two real users need it.
- **Inline answers and hotkeys.** Give an extension a keyword and command page when the page adds to the inline answer. Offer hotkeys for openable commands and items with a distinct action.
- **Compatibility:** Follow the contract’s evolution rules for permanent names, widening accepted values, and keeping existing list entries visible. [Contract evolution policy](../../Sources/WicketApp/Resources/extension-contract.md#contract-evolution)
- **Native frame, HTML pages; enabled means trusted:** Follow [AGENTS.md](../../AGENTS.md). A confirmation step for new extensions was considered and left out; it stays an option if real use shows a need.
- **Permissions: Wicket holds them, extensions declare them, nobody asks twice:**
  - Extensions declare `permissions` and never prompt themselves or build helper apps.
  - Child processes inherit Wicket's Developer ID–signed grant, so updates never re-prompt (unlike ad-hoc helper apps whose cdhash changes on rebuild).
  - Onboarding ([ROADMAP step 4](../../ROADMAP.md#4-onboarding)) offers declared permissions up front; missing grants prompt in place on first use.
  - Three real-Mac checks confirm "nobody asks twice" before Calendar ships in a release: (1) Developer ID update across two releases, (2) agent-written working-folder extension, (3) headless read from inside the agent's sandbox.
- **JavaScript by default for user extensions:** Wicket bundles [`wicket-js`](../wicket-js.md) so the agent can write extensions without Apple developer tools. Official extensions needing macOS APIs stay compiled Swift.

## Shared work

Fixed numbers referenced by the individual specs:

1. **Private data folder per extension:** Shipped (`WICKET_DATA_DIR`).
2. **Tab into an item's fields:** Shipped.
3. **Untrusted text stays inert:** Shipped (unknown tags render literally; `<context>` marked as data).
4. **Patterns compile once:** Shipped.
5. **List settings:** Extensions declare personal lists, Wicket edits them in native Settings, and indexed entries use `?entry=<list>/<id>` hotkeys. Wicket migrates legacy personal items from discovered extensions. Compatible Quicklinks go into their lists, and other items go to My Items. Bindings follow their items and the original files stay on disk. A failed migration can retry when its files change.
6. **Contract recipes:** Shipped, in the [extension contract](../../Sources/WicketApp/Resources/extension-contract.md#recipes).
7. **`wicket-js`:** Shipped ([docs/wicket-js.md](../wicket-js.md)).
8. **Meeting links:** Accept conferencing URL schemes (`zoommtg:`, `msteams:`) in `open` behind an explicit action.
9. **Saving a page's choices to `config.json`:** Design with onboarding ([ROADMAP step 4](../../ROADMAP.md#4-onboarding)).
10. **Extension catalog:** [ROADMAP step 3](../../ROADMAP.md#3-extension-catalog).
11. **Keyword, space, text:** Shipped. The root keyword and argument fill the first editable text field and rank first while keeping Ask agent. A lone editable text field uses the main bar. Multiple editable fields or an editable number use slots.

## Next, in order

1. The catalog ([ROADMAP step 3](../../ROADMAP.md#3-extension-catalog)).
2. Calendar's Phase 0 permission checks on a real Mac, then native meeting links (shared work 8).
