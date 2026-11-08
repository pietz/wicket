# Ideas

The owner's ideas and suggestions from conversations, kept short so they're not lost. Not decisions: when one is decided, record it in CONCEPT.md and strike or remove it here.

## 2026-11-08, walkthrough

- **Four pillars:** light and fast (small memory), native and modern (Apple's way, opinionated only in small portions), AI first, hackable.
- **Hackable like the Pi agent harness:** ask the launcher itself to build an extension, with access to the docs and the extension API, and use it right away without a restart.
- ~~**Ask Wicket what it can do:** a way to ask the launcher about its own capabilities.~~ Done: acting runs are told Wicket's commands (see CONCEPT, AI).
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
- **Automatic intent, no manual choice:** a cheap decision model in the background reads what's typed and decides the intent, e.g. switches to AI for a question or a phrase, stays out of the way for an equation or a file name; maybe a hybrid engine. The user types or speaks and gets the right response without picking Run Agent or Search the Web. (Overnight Sol verdict: only as a suggestion after submit, measure search-phrase misses first, label ~500 queries before building.)
- **Selected text is a nice-to-have, paused (not removed):** don't spend more time on it or its permission flow for now.
- **Wicket must be findable:** the owner saw no Dock or menu bar presence and no way into Settings (done: menu bar icon).
- **A hybrid of launcher and agent harness:** typing finds things instantly like a launcher; anything that needs the AI goes to the agent, without the user choosing. The only routing question is "forward this to the AI or not", decided by a decision model or the local Apple model, quickly, for typed text and for voice.
- ~~**No keyword for making commands:** "build an extension that shows the weather in Wicket" said to the AI should just work.~~ Decided (CONCEPT, AI): Make a Command is gone.
- ~~**Call it Run Agent, not Ask AI.**~~ Done (CONCEPT, AI).
- ~~**Agent settings per provider:** model, reasoning effort (native by default) and speed.~~ Done (CONCEPT, AI); Codex 0.167 has one fast tier, so there is no ultra fast.
- ~~**Permission levels like T3 Code.**~~ Done (CONCEPT, AI).
- **Voice:** summon and just start speaking, no typing: transcribe automatically (Apple on-device), with a simple waveform or, if transcription is live, the text as it comes. Configurable: on/off, and the trigger (listen automatically on summon, or a separate hotkey).
- **Switch features on and off,** so the user can turn off what the app does that they don't want, especially as the agent can do more.
- **Research:** what an AI-first launcher should be in early 2027; minimal yet powerful agent inside a launcher.
- **No harness of our own:** a thin wrapper that maps Wicket's own understanding onto each agent harness, like T3 Code. The harnesses can already do anything on the computer; Wicket adds context on how to do things inside Wicket.
- **Wicket's agent instructions as an editable Markdown file** the user can change.
- **Richer agent replies using Wicket components** instead of text only (later).
- **Settings ▸ AI much simpler:** one provider dropdown (Claude, ChatGPT), only ready ones selectable, one set of fields; real defaults (Claude sonnet, ChatGPT gpt-6.1-terra, effort medium, speed regular, permissions Auto); four permission levels, no "default"; Apple Intelligence out of the picker (done, 0.0.2).
- ~~**Continue a conversation:** a short button under an answer ("Follow Up") returns to the normal input (type or speak), keeping the first question and answer so the agent has the context.~~ Done (CONCEPT, AI).
- **Answer text size as a setting:** today's size is close to the smallest; default bigger (in progress).
- **Remove Search the Web:** with an agent that answers, a native web search row isn't wanted; keep opening typed links (in progress).
