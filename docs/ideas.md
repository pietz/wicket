# Ideas

Undecided ideas and suggestions from conversations, kept short so they're not lost. Accepted or rejected calls live in [CONCEPT.md](../CONCEPT.md), and committed work in [ROADMAP.md](../ROADMAP.md); settled entries have been removed here.

## 2026-11-08, walkthrough

- **Our own extension repository** can still exist, but asking for what you need is the main path.
- **Compact results mode:** maybe show fewer rows (no files under a strong app match) as an option; a full mode fills the space.
- **Calculator result layout:** big result, interpretation below is good; maybe clean up a little.
- **Keep macOS 27.3's coming AI options in mind**, and the on-device transcription model.
- **Automatic intent, no manual choice:** a cheap decision model in the background reads what's typed and decides the intent, e.g. switches to AI for a question or a phrase, stays out of the way for an equation or a file name; maybe a hybrid engine. The user types or speaks and gets the right response without picking Run Agent or Search the Web. (Overnight Sol verdict: only as a suggestion after submit, measure search-phrase misses first, label ~500 queries before building.)
- **Research:** what an AI-first launcher should be in early 2027; minimal yet powerful agent inside a launcher.

## Maintenance ideas from the architecture review

Uncommitted refactors, only if a concrete need appears: a `Settings` field-decoding helper; splitting `PaletteController` into geometry and coordination; moving `Diagnostics` beside `Messages` in Core; moving settings and usage file I/O out of Core; empty-query sources and content-driven compactness if favourites are built (measure the keystroke path). These were previously mixed into architecture.md's mechanism guide.
