# Links & Search

Wicket ships two extensions for browser shortcuts. **Links & Search** (`links-search`) holds site searches and personal bookmarks. **Search the Web** (`web`) is an independently switchable fallback.

| Situation | What to do |
| --- | --- |
| Search a site | Type `yt cats`, `wiki new york` or `gh swift` and press Return. Type just the keyword and Tab to fill Query in the root row, or press Return on the bare keyword to open the command at Query. |
| Browse the starters | Type `links` and press Return. Enter text and press Return to filter the starter list. |
| Use a hotkey | Choose ⌘K ▸ **Set Hotkey…** on a row. A search hotkey opens Query with no text when pressed from another screen. A bookmark hotkey opens its destination directly. |
| Search the web | With a nonempty query and no strong match, choose **Search the Web** just below **Ask agent**. For an explicit search, type `web` followed by the query. ⌘Return asks the agent. |
| Add a bookmark or site search | Ask the agent to add it to `extensions/links-search/user.json`, or edit that file yourself. You can also ask the agent to turn a browser bookmark export into items. |

Both are contract 2 extensions with a single Query field. The starter searches are manifest items and the root matches them with [keyword arguments](README.md#shared-work) before running any program. The web fallback carries the whole root query. Its `webEngine` setting in `config.json` defaults to DuckDuckGo and also offers Google.

Personal items live in `extensions/links-search/user.json` in the working folder. Create the folder if needed. Wicket uses the bundled manifest and program with those items. Use `open` for ordinary bookmarks and `open-link` with a fixed template for site searches or bookmarks that target an app. Hotkeys use stable addresses such as `wicket://links-search?item=youtube` and `wicket://links-search?user-item=mdn`. See the [extension contract recipes](../../Sources/WicketApp/Resources/extension-contract.md#recipes).

The Swift programs open URLs only after submission. A template fixes the HTTP or HTTPS scheme and host, and can place `{query}` in a path segment or query value. Query text is percent-encoded once. Links & Search rejects user info, invalid URLs, dot-only path segments and placeholders in the authority, query keys or fragment. An optional fixed `bundleID` routes through Launch Services. If the app is missing, Wicket shows how to repair the item and keeps the query. A successful hidden run prints nothing.

Catalog distribution and update verification remain [shared work](README.md#shared-work). Several arguments, such as GitHub owner and repository, await [canvas text fields](../../ROADMAP.md#also-agreed).
