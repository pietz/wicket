# Ideas

The owner's ideas and suggestions from conversations, kept short so they're not lost. Not decisions: when one is decided, record it in CONCEPT.md and strike or remove it here.

## 2026-11-08, walkthrough

- **Four pillars:** light and fast (small memory), native and modern (Apple's way, opinionated only in small portions), AI first, hackable.
- **Hackable like the Pi agent harness:** ask the launcher itself to build an extension, with access to the docs and the extension API, and use it right away without a restart.
- ~~**Ask Wicket what it can do:** a way to ask the launcher about its own capabilities.~~ Done: acting runs are told Wicket's commands (see CONCEPT, AI and native replies).
- **Everything is an extension (direction, not a rewrite):** each functionality, even the calculator, a unit you can switch on or off in settings. A per-source switch pane (Settings ▸ Features) was tried and removed in the 2026-11-08 scope audit.
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
- ~~**Selected text as context.**~~ Removed with the scope cut (CONCEPT); Finder files stay.
- **Wicket must be findable:** the owner saw no Dock or menu bar presence and no way into Settings (done: menu bar icon).
- **A hybrid of launcher and agent harness:** typing finds things instantly like a launcher; anything that needs the AI goes to the agent, without the user choosing. The only routing question is "forward this to the AI or not", decided by a decision model or the local Apple model, quickly, for typed text and for voice.
- ~~**No keyword for making commands:** "build an extension that shows the weather in Wicket" said to the AI should just work.~~ Decided (CONCEPT, AI and native replies): Make a Command is gone.
- ~~**Call it Run Agent, not Ask AI.**~~ Done (CONCEPT, AI and native replies).
- ~~**Agent settings per provider:** model, reasoning effort and speed.~~ Done (CONCEPT, AI and native replies); Codex 0.167 has one fast tier, so there is no ultra fast.
- ~~**Permission levels like T3 Code.**~~ Built, then removed: the permission policy is the agent's own, and Wicket shows what it asks (CONCEPT, AI and native replies).
- **Voice:** summon and just start speaking, no typing: transcribe automatically (Apple on-device), with a simple waveform or, if transcription is live, the text as it comes. Configurable on/off (done: arms quietly on open; the separate hotkey was removed with the scope cut).
- **Switch features on and off** (built, then removed with the scope cut; only Use AI remains, in Settings ▸ AI).
- **Research:** what an AI-first launcher should be in early 2027; minimal yet powerful agent inside a launcher.
- **No harness of our own:** a thin wrapper that maps Wicket's own understanding onto each agent harness, like T3 Code. The harnesses can already do anything on the computer; Wicket adds context on how to do things inside Wicket.
- **Wicket's agent instructions as an editable Markdown file** the user can change.
- ~~**Richer agent replies using Wicket components.**~~ Done: markdown plus the component catalog (CONCEPT).
- **Settings ▸ AI much simpler:** one provider dropdown (Claude, ChatGPT), only ready ones selectable, one set of fields; real defaults (Claude sonnet, ChatGPT gpt-6.1-terra, effort medium, speed regular); Apple Intelligence out of the picker (done; the permission levels it once had were removed for the harness's own policy).
- ~~**Continue a conversation:** a short button under an answer ("Follow Up") returns to the normal input (type or speak), keeping the first question and answer so the agent has the context.~~ Done (CONCEPT, AI and native replies).
- **Answer text size as a setting:** today's size is close to the smallest; default bigger (done: Settings ▸ General, default Medium).
- **Remove Search the Web:** with an agent that answers, a native web search row isn't wanted; keep opening typed links (done: removed; typed addresses are the Links feature).
- **Provider picker without a second checkmark:** unavailable providers greyed out instead (done).
- **Voice when Wicket opens should stay quiet:** arm the mic without showing the voice UI; typing stops it, and the live transcript appears only once speech is heard. In Start Listening mode, make it obvious what to press (done).
- ~~**Streaming answers as a setting.**~~ Removed: whole messages only (CONCEPT).
- **Answers that list things use Wicket's native list:** when the agent lists files or links, show them as real rows (icon, Return opens, the usual actions) instead of text. Maybe later, a small structured format the agent can answer in, which Wicket draws natively. Done: `<file>` and `<url>` rows in the markup catalog.
- **Escape should close, not go back:** a different key for back (done with ⌘[, then reversed: with no visible way back from a pushed page, Escape goes up one layer like Raycast).
- **Delete an extension, not only disable it** (done: Move to Trash).
- **One well-designed vocabulary for agent output and extensions:** flexible for rich UI, Wicket in control, unambiguous for the agent; consider the harnesses' structured-output (JSON schema) features (in research, high priority).
