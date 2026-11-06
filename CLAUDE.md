# Wicket

A small, fast, native macOS launcher whose extensions are written by agents. Read [CONCEPT.md](CONCEPT.md) first: it holds the thesis, principles, architecture sketch, PoC plan and open decisions.

- Stack: Swift 6, AppKit + SwiftUI, macOS 26+. No WebViews, no third-party dependencies without a concrete need.
- Keep the core small; anything that can be an extension should be one.
- Measure performance (hotkey-to-visible, query latency, idle memory) when touching hot paths.
- Tinycast and Vicinae are references only (see "Reference policy" in CONCEPT.md). Never copy their code.
- Update CONCEPT.md when a decision is made or a plan changes, so it stays the source of truth.
