# Brief: reinvent the macOS launcher for the AI-agent era

You are a senior product thinker and designer. Take this seriously; it is real product strategy for a real indie product, not a brainstorm exercise.

## The situation
A developer is building a native macOS "launcher": the category of Spotlight, Alfred, Raycast, LaunchBar. A global hotkey opens a small floating panel; you type; things happen. The category was designed in the 2005–2020 era around one idea: the fastest path from keyboard to an action (open an app, find a file, do math, run a script, search clipboard history, snippets, window management, extension stores, and lately a bolted-on AI chat).

The owner thinks that framing is out of date. By late 2026 many power users have a coding/computer-use agent (Claude Code, Codex, and similar) installed and signed in on their own subscription, which can run shell commands, read and write files, call APIs, and write programs on demand. MCP servers, on-device models, voice input and generative UI are now normal. The question is what a launcher *is* when an agent that can do almost anything is a keystroke away.

The owner's priorities, in order of what they care about most:
1. **Hackable / adjustable.** The user (and their agent) can reshape the tool itself, not just install plugins someone else wrote.
2. **AI-native first.** Not "a launcher with an AI chat tab" but designed from the ground up assuming an agent is present. Imagine the launcher for the age of AI agents.
3. It must still be a great, instant, keyboard-first, native macOS tool. The AI must never make basic things slow.

## Your task
1. **Research the current landscape online** (web search and fetching pages is encouraged): Raycast (incl. its AI, extensions store, AI Commands, AI Extensions, Notes, etc.), Alfred (including whatever is known about its upcoming new version), LaunchBar, Spotlight in recent macOS versions (Tahoe and later), Apple Intelligence / Siri's direction, and newer AI-first entrants or adjacent tools (agent desktops, computer-use agents, command palettes in AI tools, generative-UI work, MCP-based tools). Build an honest map of which features exist today and *why* they exist.
2. **Challenge each established feature.** For the major launcher features (app launching, file search, calculator/conversions, clipboard history, snippets, quicklinks, window management, extensions/store, scripts, AI chat, hotkeys/aliases, settings/theming, etc.), ask: does this still need to exist in this form if an agent is present? Should it stay as-is (some will, and say so), be absorbed by the agent, or work fundamentally differently? Be specific about the mechanism, not just "AI makes it smarter".
3. **Propose an outside-the-box concept** for what this product could be. It's fine and expected to propose more than one direction, but commit to one as your recommendation. Push past the obvious ("put a chat box in a launcher"). Think about: the unit of interaction, what the panel shows before you type, how results and answers are rendered, how the tool becomes hackable when the agent can write code, what persists between uses (memory, generated tools, workflows), trust/permissions/safety, speed/latency strategy (what must never wait for a model), and where the launcher sits relative to the agent (host, front-end, router, something else).
4. **Be critical of your own ideas.** For each big idea, name the strongest objection and how you'd answer it. Note which ideas a solo developer could build in weeks vs. which need a team.

## Constraints on how you work
- Do NOT read, search, or inspect files on this computer (no browsing the home folder, no looking for existing projects or code). Work only from this brief and from web research. The only file you write is your report (path below).
- Cite sources (URLs) for factual claims about existing products.
- Do not assume anything about an existing implementation; design from first principles.

## Deliverable
Write a single Markdown report to the path given at the end of your task message, structured as:
1. **TL;DR** (5–8 bullets: your recommended concept and the most surprising ideas).
2. **Landscape** (concise map of today's features and products, with sources).
3. **Feature-by-feature challenge** (a table or list: feature → keep / absorb / reinvent → how and why).
4. **The concept** (your recommended direction in depth: core idea, key interactions walked through as concrete scenarios, what's on screen, hackability model, AI architecture, latency strategy, trust model).
5. **Alternative directions** (1–3 other bold directions, briefly, and why you didn't pick them).
6. **Risks and objections**.
7. **Build order** (what a solo developer should build first to test the core bet).

Aim for depth over length: roughly 3,000–6,000 words. When done, reply with only the file path and a 3-line summary.
