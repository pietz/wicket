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
- **Permissions like agent harnesses, not a plan-and-Run gate every time:** reads allowed by default; writes under explicit user control, per write operation or for the whole task, with a setting for how strict. Avoid the overhead of always accepting something; agents are good now.
- **Lean on Claude Code and Codex:** use their permission systems and auto mode (hook their permission prompts and ask the user in Wicket), and their subscriptions instead of API billing. Speech to text through Apple's on-device transcription, so the harness doesn't need it.
- **Keep macOS 27.3's coming AI options in mind**, and the on-device transcription model.
- **The AI is what has to be new.** Launcher basics can borrow freely from Raycast, Alfred and the others we watch; the AI part is where to think outside the box: AI native, future proof, making people more capable. This is the thing to get right.
