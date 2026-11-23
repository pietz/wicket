# Links & Search

## 1. Summary

`links-search` ships shortcuts for site searches. Type a keyword, Tab to Query and press Return. A hotkey can take you straight to a site's Query field or open a bookmark. `web` is a separate extension for general web search, with its own switch in Settings ▸ Extensions.

## 2. User experience

| Situation | What the user does and sees |
| --- | --- |
| Search a site | Type `yt`, select **Search YouTube**, then Tab, type `cats` and press Return. The root keyword stays in the search bar while the Query slot has focus. Return on the row without a query opens the command with Query ready. Escape returns to the root. |
| Use a hotkey | On the row, choose ⌘K ▸ **Set Hotkey…**. A search hotkey opens a fresh Query field. A bookmark hotkey opens its destination directly. |
| Open a bookmark | Type `mdn` or **MDN Web Docs** and press Return. A static bookmark can also offer **Copy Link**. A link configured for a particular app shows that app in its subtitle. |
| Search the web | When a nonempty root query has no strong match, **Search the Web** appears just below **Ask agent**. Select it and press Return once to search for the root text. For an explicit search, type `web`, Tab to Query, type and press Return. ⌘Return still asks the agent. |
| Add a personal link | Ask the agent to add a bookmark or a keyword for a site search. The agent edits `links-search`'s `user.json` and checks the new row headlessly. To bring bookmarks from a browser export, ask the agent to write them into that file as a one-off task. |

Raycast Quicklinks pairs URL arguments with an app choice. Alfred offers fallback searches. Wicket combines keyword-selected rows, a separate Query slot and one independently switchable official fallback. [Raycast Quicklinks](https://manual.raycast.com/quicklinks) · [Alfred fallback searches](https://www.alfredapp.com/help/features/default-results/fallback-searches/)

## 3. Design

### Commands and items

Both folders use contract 2 and ship Swift executables. `links-search` has the `links` keyword, `submit:true`, `hidden:true` and one `query` text field. With no link selected, its command lists and filters the shipped searches, including `yt`, `wiki` and `gh`. Each starter has a stable item ID and a first action such as the YouTube search below.

```json
{"type":"run","action":"open-link","input":"","fields":{"link":"youtube"},"hidden":true}
```

A search action with an empty query returns a prompt on the command and carries its fixed fields into that visit. In the open command, Return submits the current query and retained fields. A named action applies once, so the program accepts both the named item action and the ordinary Query submission for the selected link. The direct root flow uses [shared work 2, Tab into an item's fields](README.md#shared-work).

`web` has its own folder, the name **Search the Web**, the keyword `web`, one `query` text field, and `fallback:true`, `submit:true` and `hidden:true`. A submitted request with a query opens the configured engine. Its `webEngine` setting belongs to `web` in `config.json`. An empty query opens the command at Query. Use shared work 6, contract recipes, for the fallback authoring recipe. [Shared work](README.md#shared-work)

### Personal links

Follow [Official extensions](README.md#decisions-every-spec-follows). The official `links-search` program and starter searches update together. The user's bookmarks and custom searches are items in `links-search`'s `user.json` (shared work 5), shaped like the items in the [quicklinks example](../../Sources/WicketApp/Resources/examples/quicklinks.json), and updates never touch them. The agent edits that file directly. Static bookmarks use `open`. A custom search's first action runs into the official command with a fixed template:

```json
{"type":"run","extension":"links-search","action":"open-link","input":"","fields":{"template":"https://en.wikipedia.org/w/index.php?search={query}"},"hidden":true}
```

Return on that cross-extension item opens the command's Query field. Inline Tab applies to items that run into their own command. Hotkeys bind stable item IDs through the existing local resolver, for example `wicket://links-search?item=youtube`. Public `wicket://` addresses open views and keep `?input=` unchanged as an unsubmitted text prefill. [Extension contract](../../Sources/WicketApp/Resources/extension-contract.md)

### Opening URLs

Only submitted requests open computed URLs. Templates use a fixed HTTP or HTTPS scheme and host, with `{query}` in a path segment or query value. Encode the raw value once for that component, so a slash stays inside its segment and `&`, `#` and `%` stay inside the value. Reject user info, placeholders in the authority or query keys, dot-only path segments and invalid URLs. A successful hidden run prints nothing. The browser makes the first network request after submission.

For an explicit app target, pass a fixed `bundleID` to `open-link`. The template can be a fixed URL for a bookmark. Resolve the bundle ID with Launch Services and open the URL with that app. A missing app shows a repair message and keeps the submitted query available. [Apple NSWorkspace](https://developer.apple.com/documentation/appkit/nsworkspace/open(_:withapplicationat:configuration:completionhandler:))

## 4. What exists today

- The root command and fallback rows both carry the manifest's `hidden` flag. The fallback carries the full root query as input. The hidden-run path submits it, and the first text field receives that input. The same command row already offers its fields on Tab. Settings switches sources by extension ID. [Composition.swift](../../Sources/WicketApp/Composition.swift#L182) · [Navigator.swift](../../Sources/WicketApp/Navigator.swift#L1176) · [ExtensionHost.swift](../../Sources/WicketApp/ExtensionHost.swift#L230) · [SettingsWindow.swift](../../Sources/WicketApp/SettingsWindow.swift#L416)
- Manifest items are indexed locally by title and keywords. An exact keyword gets the fuzzy matcher's +100 bonus. Item hotkeys activate the first action, including hidden runs. [FuzzyMatcher.swift](../../Sources/WicketApp/FuzzyMatcher.swift#L79) · [LauncherModel.swift](../../Sources/WicketApp/LauncherModel.swift#L84)
- Canvas fields have shipped on `main`. Canvas text fields are listed under **Also agreed**. [Canvas controls example](../../Sources/WicketApp/Resources/examples/canvas-controls.json) · [Roadmap](../../ROADMAP.md#also-agreed)

## 5. Gaps

| Gap | Work |
| --- | --- |
| Root item rows lack command field slots | Apply [shared work 2, Tab into an item's fields](README.md#shared-work), when a manifest item's first action is a `run` into its own command. `returnAction` currently assigns `address.fields = drafted`. Merge the draft and action fields so fixed values such as `{"link":"youtube"}` win. [Navigator.swift](../../Sources/WicketApp/Navigator.swift#L413) |
| App-target routing | Implement the bundle-ID opener in the extension. |
| Several arguments | Defer forms such as GitHub owner and repository until [canvas text fields](../../ROADMAP.md#also-agreed) exist. |
| Distribution | Use [shared work 10, the extension catalog](README.md#shared-work). |

## 6. Implementation plan

1. **Two folders on contract 2.** Build `links-search` and `web` with the current host. The starter rows open the shared Query field on Return. The web fallback opens directly. In a scratch `WICKET_CONFIG_DIR`, test `--extension links-search --submitted --action open-link --fields …` and the submitted `web` query with an inert opener. Cover encoding, empty input and malformed templates. Use `--query` to verify exact aliases and fallback placement for weak, strong and empty input, including with `web` disabled.
2. **Tab into item fields and route to an app.** Land shared work 2. Check that the typed query reaches the right link, fixed fields win, and search and bookmark hotkeys behave as described. Check bundle-ID resolution and missing-app handling behind a fake opener. Measure root query latency and hotkey-to-visible for the changed path.
3. **Catalog.** Publish both folders through the catalog (shared work 10). Verify that `user.json` still opens its bookmarks and runs its searches after an official update.
4. **Optional, each on the owner's go.** Add the root bang pattern and, once canvas text fields exist, multi-argument forms. Live suggestions belong in a separate future spec.

## 7. Open questions

| Decision | Recommendation |
| --- | --- |
| Should `yt cats` ⏎ work at the root alongside `yt` ⇥ `cats` ⏎? | Ship the Tab flow first. If the owner wants the shorter flow, start with shipped keywords. The program rewrites an anchored `match` such as `^(yt\|wiki\|gh) \S` whenever its keyword list changes and returns one strong **Search YouTube for cats** row with a submitted launch action. Regenerate the shipped pattern when packaging updates. Budget about 3 ms per warm pattern run and measure it before enabling the feature. [Roadmap runner trial](../../ROADMAP.md#3-extension-catalog) |
| Which web engine should ship as the default? | Start with DuckDuckGo and let the user choose another supported engine in `web` settings. |
