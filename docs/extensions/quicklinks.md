# Quicklinks

Quicklinks lists the bookmarks and site searches you save in `extensions/links-search/user.json`. The bundled extension keeps the `links-search` ID and existing `?user-item=` hotkey addresses. To keep a former starter search, save its URL and bind the new item's `?user-item=` address.

Type a saved title or keyword at the root, or type `links` to browse and filter your list. For a search link, type the keyword and query together, or select the link and enter a query when prompted. A bookmark hotkey opens the link directly. A search hotkey opens at the query prompt.

The [Quicklinks recipe](../../Sources/WicketApp/Resources/extension-contract.md#quicklinks) shows the file format and a hotkey binding. Existing items with explicit `actions` can share the file with the short form. For a saved action that uses `fields.link`, use `fields.template` with the site's actual URL instead.
