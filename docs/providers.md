# Provider contract

The Swift values in `Sources/WicketApp/Provider.swift` and the shipped [extension contract](../Sources/WicketApp/Resources/extension-contract.md) describe the same boundary. The latter contains the complete manifest, request, view, action and trigger formats for an agent authoring an extension.

```swift
ProviderRequest(input: String, arguments: [String: String] = [:], chosen: Bool = false)
ProviderView(body: String?, items: [Row], actions: [RowAction])
Row(id: String, title: String, subtitle: String?, icon: String?,
    actions: [RowAction], keywords: [String]?, prominent: Bool?)
RowAction(kind: Kind, title: String?)
RowAction.open(URL), .reveal(URL), .copy(String), .paste(String)
RowAction.run(Address), .agent(String)   // each with an optional title:
```

`chosen` is true only on the one request the user's activation caused (a command or fallback row, a run action, Return in a `submit` command), never on reruns, refreshes or links.

A compiled provider implements `view(for:) async throws -> ProviderView`. The extension adapter sends the request as one JSON value on stdin, closes stdin, reads one JSON value from stdout, and waits for successful exit. Extra keys are tolerated; missing required fields, wrong types, a view with neither body nor items, unknown action types, invalid open schemes, duplicate or empty item IDs, multiple JSON values and failed processes are errors. Errors preserve the coding path and stderr tail.

Name and keyword matching only offers an entry. Patterns are checked in Wicket and start only matching extensions; each completed response appears inline, ordered by `Ranking.compose`. A later input cancels old invocations and rejects their results. Fallbacks are offered only without a strong match and run when chosen. A provider is on when its source is on: built-ins and discovered extensions are switched in Settings, Sources, and nothing writes config on discovery. Rows use exact and word-start prefix matches over title and keywords, then query-specific usage at the root, then extension order; inside a chosen command, usage plays no part. Compiled apps keep their own fuzzy index.

`keywords` supplies aliases. `prominent:true` lets an extension's first row use the same calculator presentation as built-in math. A pattern matching empty input lets an app-index extension supply the initial list. File open and reveal actions resolve native file/application icons, and the host records usage under stable provider/row identities. These close the contract gaps needed to express the built-in app and math providers. A subprocess still has startup cost and cannot retain an in-memory index across requests; long-running extensions are intentionally deferred.

The same executable exposes this composition without a window, hotkey or status item: `Wicket --query TEXT`. Its JSON includes ordered `{provider,row}` entries under `items` and `askAgent:{onTop,reason}`; it uses enabled sources only. `Wicket --extension ID --input TEXT [--arguments JSON_OBJECT] [--chosen]` prints a decoded view or `{error}` and runs any discovered extension, even a switched-off one, because naming it is the consent. `WICKET_CONFIG_DIR` selects the working folder for both. See the shipped contract for examples and limits.
