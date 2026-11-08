# Ideas

The owner's ideas and suggestions from conversations, kept short so they're not lost. Not decisions: when one is decided, record it in CONCEPT.md and strike or remove it here.

## 2026-11-08, walkthrough

- **Four pillars:** light and fast (small memory), native and modern (Apple's way, opinionated only in small portions), AI first, hackable.
- **Hackable like the Pi agent harness:** ask the launcher itself to build an extension, with access to the docs and the extension API, and use it right away without a restart.
- **Ask Wicket what it can do:** a way to ask the launcher about its own capabilities. Not built yet; cheap.
- **Everything is an extension (direction, not a rewrite):** each functionality, even the calculator, a unit you can switch on or off in settings. Cheap step: list the built-ins in Settings ▸ Features.
- **Our own extension repository** can still exist, but asking for what you need is the main path.
- **Compact results mode:** maybe show fewer rows (no files under a strong app match) as an option; a full mode fills the space.
- **Highlight is always the top row** (done, e0d3b93).
- **Calculator result layout:** big result, interpretation below is good; maybe clean up a little.
- **One AI instead of Ask, Web search and Do rows (confidence 8/10):** a model with search covers web search; asking it to do something covers Do.
- **Permissions, two alternatives (not combined):** avoid the overhead of always accepting something; agents are good now.
  - **A, Wicket's own rule:** reads allowed by default; every write needs explicit permission, per write operation or for the whole task.
  - **B, the harness decides (preferred):** run actions through Claude Code or Codex and let the permission mode the user set there (including auto mode) govern; Wicket's read/write rule doesn't apply. When the harness asks, Wicket shows the question in its own UI. Bonus: their subscriptions instead of API billing. Speech to text through Apple's on-device transcription, so the harness doesn't need it.
- **Keep macOS 27.3's coming AI options in mind**, and the on-device transcription model.
- **The AI is what has to be new.** Launcher basics can borrow freely from Raycast, Alfred and the others we watch; the AI part is where to think outside the box: AI native, future proof, making people more capable. This is the thing to get right.
- **Automatic intent, no manual choice:** a cheap decision model in the background reads what's typed and decides the intent, e.g. switches to AI for a question or a phrase, stays out of the way for an equation or a file name; maybe a hybrid engine. The user types or speaks and gets the right response without picking Ask AI or Search the Web. (Overnight Sol verdict: only as a suggestion after submit, measure search-phrase misses first, label ~500 queries before building.)
- **Selected text is a nice-to-have, paused (not removed):** don't spend more time on it or its permission flow for now.
- **Wicket must be findable:** the owner saw no Dock or menu bar presence and no way into Settings (menu bar icon in progress).
