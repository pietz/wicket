# How Raycast 2 draws its UI

Checked 16 Nov 2026 from Raycast's own [technical deep dive](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast) (May 2026) and the Raycast 2.12.1.0 bundle (`brew fetch`, mounted read-only, never run).

- **Almost everything is web.** One React + TypeScript frontend in a `WKWebView`: the root search list (`RootSearchView`, `ResultListItem`), the input bar, the footer, extension views, AI chat and settings. About 985 frontend files, a bundled Node 26 backend and Rust libraries.
- **Native is only the shell.** Swift with AppKit: windows, popovers, the action panel window, HUDs and tooltips as separate native windows whose content is still React. SwiftUI is used only for a tiny window-placement grid. No native table, list or search field is imported.
- **The glass is real system Liquid Glass, drawn by WebKit.** The CSS uses WebKit's private property `-apple-visual-effect: -apple-system-glass-material` (also `-subdued`, `-media-controls`), enabled through the private `WKPreferences` setting `useSystemAppearance`, both present in the bundle. Buttons are DOM elements with that class; the window background is an `NSGlassEffectView` with a private `_adaptiveAppearance` setter. Minimum macOS 26.0, built with the macOS 26.5 SDK.

For Wicket: it shows an all-web launcher can look native on macOS 27, at the price of private WebKit API. It does not change the native-frame, HTML-content rule (SPEC Decisions), whose reasons are memory, code and no private API. The same private property could give answer cards real glass; weigh it in the glass roadmap item.
