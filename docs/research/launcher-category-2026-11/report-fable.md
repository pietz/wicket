# The launcher after the agent: a product concept

Research date: 14 November 2026. Web research only; nothing here assumes an existing implementation. Where a claim rests on a secondary source or could not be confirmed, it says so.

## 1. TL;DR

- **Recommended concept: the compiling launcher.** The agent is treated as a slow, general-purpose *compiler*, and the launcher as the fast *cache* of what it has compiled. The first time you ask for something new, your own agent does it in seconds or minutes. If it is worth keeping, the agent distills the run into a small, readable, deterministic command file. From then on it runs instantly with no model in the loop. The tool gets faster and more personal the more you use it.
- **The launcher does not own an agent. It borrows yours, and lends itself back.** It dispatches work to the agent the user already pays for (Claude Code, Codex, anything speaking ACP). It is also an MCP server, so that same agent, running anywhere, can use the launcher as its eyes (selection, frontmost app, clipboard, file index), hands (run a command, move a window) and face (ask the user a question, show a result).
- **The whole product is a folder.** Every feature, including the built-in ones (clipboard history, snippets, window management), is a plain file in one git-tracked directory, in the same format the agent writes. "Hackable" then means: tell the agent what you want changed, review a diff, and it hot-reloads. Undo is `git revert`.
- **There is no extension store.** A store exists because writing an extension used to be expensive. When the agent writes a working integration in two minutes against your actual accounts, the thing worth sharing is a one-paragraph *intent* that each user's agent re-forges locally, not a binary package.
- **Enter never waits for a model.** There are three strict latency lanes: deterministic results per keystroke; an optional on-device model that may only add a row and never reorder what is under your finger; and the agent, which is always an explicit, detached handoff. The panel closes and the result comes back to an inbox.
- **Before you type, the panel shows what you are holding and what is waiting for you.** That is the current selection, frontmost document and clipboard as explicit context chips, plus finished and blocked agent jobs. It is LaunchBar's object-first idea, revived because agents need a noun to act on.
- **Most surprising position: chat is removed, not improved.** Answers are typed objects with actions (paste, save, keep as command), rendered in native views. A job has a log; there is no conversation tab.
- **Honest weak point:** the bet depends on distillation working often enough. My guess is that a minority of agent runs compile into good deterministic tools. The build order tests exactly that in the first six weeks, before anything else is built.

## 2. Landscape

### What exists and why

**Raycast** is the category leader and has moved furthest toward agents. In 2026 it shipped a full rewrite (v2, out of beta around 21–25 August) that runs on macOS and Windows.

- **Architecture:** a native shell (Swift/AppKit or C#/WPF) hosts a React/TypeScript frontend in the system web view. A long-lived Node backend holds business logic and the extension runtime, and a Rust core handles the data layer and file indexer.
- **Cost:** Raycast's own figures put memory at roughly 350–450 MB against 200–300 MB for v1.
- **Stated reasons:** cross-platform reach, AppKit friction and hiring.

Sources: [technical deep dive](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast), [v2.0 changelog](https://www.raycast.com/changelog/windows/2-0), [AlternativeTo](https://alternativeto.net/news/2026/8/raycast-2-0-is-officially-out-of-beta-with-a-new-interface-and-cross-platform-support/).

On AI, the sequence this year was:

- **May:** AI Extensions, AI Skills and MCP servers became usable in Quick AI and AI Chat, loaded automatically per request ([v0.56](https://www.raycast.com/changelog/macos/0-56)).
- **September:** an "agentic" AI Chat that "works out a plan, uses your extensions, writes and runs code, checks the results, and keeps going until it's finished". It came with approval prompts, an Auto mode with review rules, Projects with their own memory and working directory, scheduled automations, bring-your-own Claude or ChatGPT subscription, and a move to usage-based pricing ([v2.3](https://www.raycast.com/changelog/macos/2-3)).
- **October:** AI Chat, Notes and Settings were moved into their own processes "so a busy chat no longer slows Root Search" ([v2.7](https://raycast.com/changelog/macos/2-7), as summarised by search).
- **Glaze (separate product):** an app builder that produces desktop apps from prompts using Claude Code and Codex, with a public and team store and forking. A cofounder described Glaze apps auto-generating companion Raycast extensions; I found no confirmation that shipped ([Implicator](https://www.implicator.ai/raycast-launches-glaze-a-platform-for-building-desktop-apps-through-ai-prompts/), [Raycast blog](https://raycast.com/blog/introducing-glaze)).

My reading: Raycast's agent lives in a chat window, runs on Raycast's harness, and is sold through Raycast's plans. The launcher root and the agent are deliberately separated, down to the process level. The extension model is still React packages published to a store. That is a coherent business, and it is the opening.

**Alfred** announced version 6 for "this Autumn" on 10 September 2026, in beta with a small group, with seamless preference migration. The announcement page names no features ([Alfred blog](https://www.alfredapp.com/blog/announcements/alfred-6-coming-soon/)). Two sneak-peek posts exist that I could not retrieve. A forum reader reports a "Text Transformer" feature and "no tie to AI at all unless you want to use a workflow that does that" ([MPU thread](https://talk.macpowerusers.com/t/alfred-6-ui-sneakpeak/47171)); treat that as hearsay. Alfred's enduring ideas are the visual workflow canvas, local-first data, a one-time licence, and (since 5.5) workflow views for grid, text, image and PDF ([5.5 release](https://www.alfredapp.com/blog/releases/alfred-5-5-released-exciting-workflow-views/)).

**LaunchBar** is in maintenance: 6.x point releases through 2026 with Tahoe compatibility and small actions ([Wikipedia](https://en.wikipedia.org/wiki/LaunchBar), [TidBITS](https://talk.tidbits.com/t/launchbar-6-24/33370)). Its ideas matter more than its momentum: abbreviation search that learns, and Instant Send / Send To, where you select an object first and then choose what to do with it.

**Spotlight** has become a real launcher over two releases.

- **macOS 26 Tahoe:** actions through App Intents that run without opening the app, user-assigned "quick keys" (`sm` to send a message), and a built-in clipboard history with retention settings ([MacRumors](https://www.macrumors.com/2025/06/09/apple-supercharges-spotlight-in-macos-tahoe-with-quick-keys-and-more/), [TechCrunch](https://techcrunch.com/2025/06/09/apple-updates-spotlight-to-take-actions-on-your-mac/)).
- **macOS 27 "Golden Gate":** Spotlight is the front door to the new Siri. It has a "Search or Ask" field, expandable answers with follow-ups, a shortcut that captures the active window as context, and a region-capture shortcut ([MacRumors](https://macrumors.com/2026/06/08/siri-conversations-macos-27-spotlight), [TechCrunch](https://techcrunch.com/2026/09/14/macos-27-new-siri-takes-on-ai-productivity-apps/), [MacStories overview](https://www.macstories.net/news/macos-27-golden-gate-the-macstories-overview/)).
- **Models:** reports say they were built with Google Gemini and split between on-device and Private Cloud Compute, and that the Ask target can be switched to ChatGPT ([The Next Web](https://thenextweb.com/news/apple-wwdc-2026-siri-ai-gemini-ios-27)). Sources disagree on details and rollout.

The consequence: **the free baseline now covers apps, files, actions, clipboard and a context-aware assistant.** A third-party launcher can no longer win on those. Apple's version will not be user-reshapeable, will not run your coding agent, and will not let you read its source.

**Agent desktops** already have hotkeys of their own and already expose protocols a front-end can drive.

- **Claude desktop app:** a quick-entry box on a double-tap of Option, plus Cowork and computer use on Mac ([Claude tutorial](https://claude.com/resources/tutorials/navigating-the-claude-desktop-app); other details from third-party guides).
- **Codex:** an app-server, a JSON-RPC interface over stdio or WebSocket that powers its CLI, IDE and desktop surfaces and is documented for client integrations ([OpenAI docs](https://developers.openai.com/codex/app-server), [OpenAI write-up](https://openai.com/index/unlocking-the-codex-harness)).
- **Agent Client Protocol:** started by Zed in 2025 and modelled on LSP, it standardises client-to-agent communication and is supported by several agents and editors ([agentclientprotocol.com](https://agentclientprotocol.com/)).

**Generative UI.** MCP Apps, announced 26 January 2026 as the first official MCP extension and built by merging MCP-UI with OpenAI's Apps SDK design, lets a server return interactive UI. It is reported as shipping in Claude, ChatGPT, VS Code and others ([MCP blog](https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/), [AAIF](https://aaif.io/blog/mcp-apps-extending-the-frontier)). It is HTML in a sandboxed frame, which is portable but not native.

**On-device models.** Apple's Foundation Models framework gives third-party apps a small on-device model with typed ("guided") generation and tool calling ([Apple docs](https://developer.apple.com/documentation/foundationmodels)). Third-party write-ups put it around 3B parameters. I found no trustworthy latency figures.

**New AI-first launchers** are mostly Raycast clones with a different stack or licence: SuperCmd (open source, Raycast-extension compatible, rewritten in Swift, [AlternativeTo](https://alternativeto.net/news/2026/7/supercmd-v2-launches-with-native-swift-build-and-lower-resource-use/)), Asyar and Tinycast. The one with a different idea is **Ainto**, a tiny solo project whose AI commands run through the agent CLI already installed on the Mac, on the user's own plan, with no key stored ([Product Hunt](https://www.producthunt.com/products/ainto)). It applies that only to selected-text commands. Nobody appears to have taken "bring your own agent" as the organising principle of the whole product.

**A dependency to watch: subscription terms.** Anthropic's rules on using a Claude plan from third-party tools changed several times in 2026. A help-centre article describes a separate monthly Agent SDK credit covering the SDK, `claude -p` and third-party apps built on it, from 15 June ([Anthropic support](https://support.claude.com/en/articles/15036540-use-the-claude-agent-sdk-with-your-claude-plan)). One outlet reported that change paused ([The New Stack](https://thenewstack.io/anthropic-pauses-claude-agent-sdk-subscription-change-)). I could not establish the current state. This must be checked against primary docs before building.

### The pattern underneath

Every classic launcher feature is a **cached answer to a question the computer could not answer by itself**. Snippets cache text you would retype. Quicklinks cache URLs. Extensions cache someone else's API integration. Workflows cache a sequence. The store exists because producing a cached answer took a programmer hours.

An agent changes one variable: producing a new answer now costs minutes and no skill. It does not change the other: *replaying* a cached answer is still thousands of times faster and far more predictable than asking again. The incumbents responded by adding the agent next to the cache. The opportunity is to connect them.

## 3. Feature-by-feature challenge

| Feature | Verdict | How and why |
|---|---|---|
| App launching, switching | **Keep as-is** | Pure recall with a learned abbreviation ranker. A model adds latency and nothing else. This is the reflex the whole product's credibility rests on. |
| File search | **Keep, plus a handoff** | Name and metadata search stays local and instant. "The contract Anna sent in spring" is an agent job: it greps, reads and returns typed file results. The same row type, a different lane. |
| Calculator, units, dates | **Keep** | Deterministic parser, answers per keystroke. Anything the parser cannot handle becomes the bottom "hand to agent" row, never a silent model call. |
| Clipboard history | **Keep and promote** | It becomes more important: it is the user's short-term working memory and the best source of context for an agent. Items are typed (text, image, file, URL, colour, secret). Concealed pasteboard items are never recorded or sent. |
| Snippets | **Split** | Static expansion stays, because it must fire in milliseconds inside any app. Dynamic snippets ("reply declining politely") are recipes: a stored prompt plus context, run by the agent. |
| Quicklinks, web searches | **Absorb into forging** | Nobody should fill in a URL template form. "Make `gh` search our org's repos" is one sentence; the agent writes the three-line file. |
| Window management | **Keep the engine, generate the layouts** | Moving windows is an Accessibility call and must be instant. The layouts themselves ("coding", "call") are forged commands the agent writes from a description or from a snapshot of the current arrangement. |
| Extensions and store | **Reinvent** | Replace packages with forged commands. Replace the store with shareable intents: a paragraph plus example inputs and outputs, which the recipient's agent forges against their own accounts and reviews as a diff. This removes the supply-chain problem of running a stranger's code, and the maintenance problem of extensions that rot when the author leaves. |
| Script commands | **Promote to the only primitive** | A command is an executable file with a small header (name, arguments, capabilities, view). Built-ins use the same format. The agent's output and the user's hand-written scripts are indistinguishable. |
| Visual workflow editor (Alfred) | **Drop** | It existed to let non-programmers compose steps. The agent composes steps from a sentence; a canvas is now slower than describing. Keep a readable step list for review. |
| AI chat tab | **Remove** | Users with an agent already have a better chat elsewhere. The launcher keeps single-shot asks with typed answers and a job log. Follow-ups reuse the job's context; a long conversation hands off to the agent's own app. |
| AI Commands (prompt presets) | **Reinvent as recipes** | A recipe is a stored intent with pinned context sources and a capability budget. It is the middle rung between a one-off ask and a compiled tool. |
| Hotkeys, aliases | **Keep, agent-editable** | One keymap file. The local ranker proposes aliases from usage ("you ran this 14 times; bind it?"). No model involved. |
| Settings UI | **Shrink** | A small native pane for permissions, the hotkey and agent connection. Everything else is the folder. "Make the panel wider and use my terminal font" is an agent edit with a preview. |
| Theming | **Absorb** | One token file; the agent edits it. Not worth a designer UI. |
| Notes | **Drop** | The user has a notes app and the agent can write to it. A launcher note is a forged command away. |
| Fallback search rows | **Reinvent** | The fallback is the agent row. It shows the exact context that will be sent before you press the key. |
| Dictation | **Keep as input, system-provided** | Voice is a second way to fill the same field, most useful for long intents. Use the OS speech stack; do not build one. |
| Menu-bar item search, system toggles | **Keep** | Deterministic, instant, and widely loved. |

The line that falls out: **anything you do by reflex stays deterministic and local; anything you would have configured is now described; anything you would have installed is now forged.**

## 4. The concept: the compiling launcher

### Core idea

Three kinds of thing can answer a query, and the product's job is to move work down the list over time:

1. **A job.** A one-off request the agent carries out. Slow, flexible, costs tokens.
2. **A recipe.** A saved intent with named inputs and pinned context. Still runs the agent, but with a fixed capability budget and a known shape of result.
3. **A tool.** A deterministic command file. Runs in milliseconds, offline, with no model.

A job that succeeds offers one quiet affordance: **Keep**. Pressing it asks the agent to distill what it just did.

- If the task is mechanical (call this API with these arguments, transform this text, arrange these windows), it becomes a tool.
- If it needs judgement each time (summarise, draft, triage), it becomes a recipe.

The agent writes the file, plus one or two recorded examples of input and expected output taken from the run that just succeeded. The user sees a diff and the declared capabilities, accepts, and the command is in the index on the next keystroke.

The loop is the product. Usage produces tools; tools make usage faster; the folder becomes a portrait of how this one person works.

### Where the launcher sits

It is neither a host for its own agent nor a chat client. It has two roles, facing opposite directions.

**Dispatcher (launcher → agent).** A thin adapter layer starts and streams sessions with whatever agent is installed: Codex through its app-server, any ACP-speaking agent through ACP, Claude Code through its headless interface or SDK subject to the plan terms noted above. The launcher supplies the intent, the context chips, and the folder's contract document. It owns no model, no prompt stack worth mentioning, and no billing.

**Surface (agent → launcher).** The launcher runs a local MCP server. Any agent session, including one the user started in a terminal an hour ago, can call it:

- `context.get`: selection, frontmost app and document, clipboard history, open windows.
- `index.search`: apps, files, commands.
- `command.run`: any forged or built-in command, subject to its capabilities.
- `ui.ask`: put a question in front of the user as a native form or confirmation and wait for the answer.
- `ui.show`: deliver a typed result to the inbox.
- `forge.propose`: submit a new or changed command file for review.

`ui.ask` is the sleeper. Today a long-running agent that needs a decision blocks in a terminal tab nobody is watching. With this, it raises a small native prompt on the global hotkey layer, and the launcher becomes the one place where every agent on the machine reaches the human. That is a role no incumbent occupies.

### What is on screen

**Before typing.** One compact panel with three zones, most of which are usually empty:

- *Holding*: chips for what would be acted on. Selected text (first words), the frontmost document or URL, the top clipboard item. Each chip can be dismissed with a key; dismissed means not sent.
- *Waiting*: agent jobs that finished or are blocked on a question. Usually zero to two rows.
- *Next*: up to three commands predicted from local frequency and context (app in front, time of day). No model.

If nothing is held or waiting, the panel is just the field. It should feel calm, not like a dashboard.

**While typing.** Deterministic rows, ranked locally, rendered every keystroke. The last row is always the agent row: `Ask agent: "<your text>"` with the chips it would send. It is never the top row unless nothing else matches. Tab completes into a command's arguments. A dedicated key (not Enter) sends to the agent, so muscle memory can never trigger a slow, costly action by accident.

**Results.** Commands declare a view from a small native set: list, detail, form, table, grid, diff, confirm, progress. Agent answers arrive as the same typed objects, not as markdown bubbles: a file result has Open, Reveal and Send To; a text result has Paste, Copy and Keep. The agent emits a compact view description and the launcher renders it natively. HTML through MCP Apps is supported as an escape hatch in a sandboxed web view for third-party servers. It is not the default, because native rows are faster and stay consistent.

### Scenarios

**1. A reflex.** Hotkey, `saf`, Enter. Safari is in front in under 50 ms from keypress to activation. Nothing in this path knows a model exists. This must be indistinguishable from the best classic launcher, or nothing else matters.

**2. A first-time job.** You are reading a pull request. Hotkey; the *Holding* zone shows the PR URL. You type `which of my open PRs are waiting on me` and press the agent key. The panel closes immediately. Twenty seconds later a notification says the job is done; the hotkey shows a table of five PRs under *Waiting*. Each row opens the PR. At the bottom: **Keep**.

**3. Forging.** You press Keep. The agent rewrites what it did as a twelve-line script calling `gh` with a JSON query. It declares `network: api.github.com`, `exec: gh` and view `table`, and attaches the result it just produced as a recorded example. You see the file and its capabilities in a diff view and press Enter. Tomorrow, `prs` returns the table in 300 ms, the time of one API call, with no model and no tokens.

**4. Reshaping the tool.** Hotkey: `make clipboard history show image previews twice as large and put pinned items first`, agent key. The agent reads the contract document, edits two files in the folder, and proposes the change through `forge.propose`. You see a diff and a live preview. Accept; it hot-reloads. It is one commit, so reverting is one command. There was no settings screen for this and there never needs to be.

**5. A tool breaks.** GitHub changes a field. `prs` fails. The error row offers **Repair**: the agent receives the file, the error, the original intent and the recorded example, fixes it, and re-runs the example to prove it. The user accepts a diff. Extensions that rot when their author loses interest become commands that are repaired by the person who uses them.

**6. The agent reaches you.** A Claude Code session you started before lunch is migrating a database and needs to know whether to drop a legacy table. It calls `ui.ask`. A native confirmation appears over whatever you are doing, with the question, the session's name, and two choices. You answer with one key. You never switched to the terminal.

**7. Sharing.** A colleague wants your `prs` command. You send the intent card: one paragraph, the argument list, a redacted example. Their agent forges it against their own `gh` login and their org. They review their own diff. Nobody ran anyone else's code.

### Hackability model

The user folder is the product. A possible layout:

```
launcher/
  AGENTS.md          the contract: file formats, view types, capability names, examples
  commands/          one file or directory per command, any language, header declares metadata
  recipes/           stored intents with context sources and capability budgets
  views/             optional custom view descriptions
  keymap.toml        hotkeys and aliases
  theme.toml         design tokens
  rank.toml          ranking weights and pinned results
  memory/            plain-text facts the user or agent has recorded
  examples/          recorded input/output pairs per command
  .git/
```

Four rules make this work:

- **Built-ins live here too.** Clipboard history, snippets and window layouts ship as commands in this format, calling a small stable native API (pasteboard store, accessibility, index, views). The native core is small and fast; everything a user might want to change is in userland. This is the Emacs and Neovim bargain, with an agent in place of Lisp fluency.
- **The contract is a document, not an SDK.** `AGENTS.md` and a handful of exemplary commands are what make any agent competent at extending the tool. This file is the most important design artefact in the product and should be tested like code: give a fresh agent the contract and ten intents, and count how many forge correctly.
- **Every change is a commit with provenance.** The commit records the intent text and which agent made it. History is the audit log and the undo stack.
- **Hot reload is instant and safe.** A file that fails to parse is ignored with a visible error row; the previous version keeps working.

Memory deserves a plain statement: **the best memory is a tool.** A forged command remembers how you do something more reliably than an embedding of a past chat. The `memory/` directory holds a few facts in plain text ("my work GitHub org is X") that are passed to forges and jobs. There is no vector store in the first version.

### AI architecture

- **Lane 0, no model.** Index, ranker, parser, command execution. Native code.
- **Lane 1, on-device model, optional.** It uses the system's on-device model with typed output to do exactly two things. It extracts arguments for a known command from loose phrasing ("resize this to half left" → `layout left-half`). It decides whether the agent row deserves to be promoted when nothing else matches. It may add or annotate one row after deterministic results have rendered. It may never reorder rows above the cursor or delay them. If it is unavailable, nothing breaks.
- **Lane 2, the user's agent.** All open-ended work, all forging, all repair. It runs out of process and detached from the panel. The launcher passes intent, chips, the contract, relevant memory, and the launcher MCP endpoint.

The launcher's own "intelligence" is deliberately near zero. Its value is in context capture, the contract, the review step and the cache.

### Latency strategy

Budgets, treated as release-blocking tests:

| Path | Budget | May touch |
|---|---|---|
| Hotkey to panel visible | under 50 ms | Nothing. Panel is pre-built and kept warm. |
| Keystroke to results | under 16 ms | In-memory index only. |
| Enter on a tool | process start plus the tool's own work | No model. |
| Lane 1 annotation | arrives within about 300 ms or is discarded | On-device model. |
| Agent handoff | panel closes in one frame; work continues elsewhere | Agent. |

Rules that follow:

- Enter never invokes a model unless the selected row says so in words.
- Results never move after they render.
- The agent process is never in the launcher's address space. Raycast's October change to isolate AI Chat from Root Search is evidence of what happens otherwise.
- Context capture (selection via Accessibility) is done lazily and time-boxed, so a hung frontmost app cannot delay the panel.

### Trust model

The danger is specific: an agent that writes code which then runs on a hotkey, forever, with the user's credentials.

- **Capabilities are declared and enforced.** Each command header lists file paths, network hosts, executables, apps it may script, and whether it can read the clipboard or selection. Tools run in a child process under a generated macOS sandbox profile matching that list. A tool that tries something undeclared fails loudly.
- **Review is the forge step, and it is designed to be read.** The diff view shows capabilities first, in plain words ("can contact api.github.com, can run gh, cannot read files"), then the code. Widening capabilities later requires a new review.
- **Effects are classified.** Read-only commands run freely. Commands that send, delete, pay or post carry a tag that forces a confirm view on every run unless the user explicitly relaxes it for that command.
- **Recorded examples act as tests.** Repair and any agent edit must re-pass them before the diff is offered.
- **Context is visible before it leaves.** The chips are the complete list of what is sent with a job. Concealed pasteboard types are excluded from history. Content fetched from the web or clipboard is passed to the agent as marked data. Jobs launched from the launcher get a narrow default capability budget, so injected instructions have little to work with.
- **The agent cannot approve its own changes.** `forge.propose` only ever queues a diff. Acceptance is a physical keypress in the launcher's own UI, which no MCP call can synthesise.
- **A journal** records every command run with its arguments and effect class, so "what did that do?" has an answer.

## 5. Alternative directions

**A. Mission control for agents.** Make the launcher primarily the place to start, watch, steer and approve many agent sessions: an inbox and switchboard, with classic launching as a side feature. It is a real need and no one owns it. I did not choose it as the centre for two reasons. It competes directly with the agent vendors' own desktop apps, which will always have better access to their own sessions. It also abandons the instant-reflex identity. Its best part, `ui.ask` and the *Waiting* zone, is folded into the recommendation.

**B. The ambient launcher.** No hotkey as the main entry. The tool watches context and proposes the next action at the right moment: a meeting link five minutes before the call, "file this receipt" when a PDF lands in Downloads. It is attractive in demos. I rejected it because wrong suggestions are costly, it needs constant observation that many power users will refuse, Apple can do it with deeper system access, and it is the opposite of keyboard-first intent. A restrained version survives as the three *Next* rows, driven by local statistics.

**C. Generate everything, keep nothing.** No commands at all; every query produces a freshly generated interface and plan. This is the purest reading of "AI-native". It fails the third priority outright: every action waits for a model, results are inconsistent between runs, and nothing can be learned by muscle memory. The compiling launcher is the answer to this direction: generate once, then keep.

## 6. Risks and objections

**"Most agent runs will not distill into good tools."** This is the strongest objection, and I think it is partly true. Tasks that need judgement do not become scripts, and a naive distillation produces brittle code fitted to one example. That is why there are three rungs: recipes are a legitimate resting place. Keep is never automatic, examples guard regressions, and Repair makes brittleness cheap. But if in dogfooding fewer than roughly one in five kept commands is reused several times, the central bet is wrong and the product should pivot toward direction A.

**"Raycast will do this."** They have the agent, the code execution, BYO subscriptions and Glaze. What they lack is the incentive: their store is a moat, their AI plans are revenue, and their architecture puts AI in a separate window by design. A userland-everything, no-store, no-AI-billing product undercuts their model. They could still copy the Keep loop. The defence is being smaller, native, and trusted by the minority who want to own their tool. That is a good indie business, not a category takeover.

**"Apple will absorb it."** Spotlight already has actions, clipboard and a context-aware assistant. Apple will not ship a launcher whose features are editable files, that runs a third-party coding agent, or that exposes itself over MCP. The risk is narrower: Apple makes the default good enough that fewer people look for an alternative. Target the people who already have an agent installed; they are the ones the default will not satisfy.

**"Agent-written code on a hotkey is a security hole."** Without the trust model, it is. With enforced capabilities, mandatory human review, effect classes and no self-approval, it is arguably safer than installing a store extension that updates silently. Sandbox profiles on macOS are underdocumented and fiddly. Expect this to take real time, and ship read-only and network-scoped tools first.

**"Depending on someone else's agent is fragile."** Plan terms for third-party use shifted repeatedly this year, and headless interfaces change. The adapter layer should support at least two agents from the start and prefer open protocols (ACP, Codex app-server). Crucially, lanes 0 and 1 and every forged tool work with no agent at all. If the agent disappears, the user keeps everything they have compiled. Check current vendor terms before committing to any one integration.

**"Normal users will not review diffs."** Correct, and they are not the audience. The audience is people who already run a coding agent. For them a diff is a comfortable unit of trust. The plain-words capability summary is there for the days they do not read the code.

**"Removing chat is a mistake; people expect it."** Possibly. The bet is that an agent owner has a better chat one keystroke away, and that a launcher with a chat tab drifts into being a worse version of that app. Follow-ups on a job cover the common case. If dogfooding shows frequent hand-offs to the agent's own app mid-task, add a deeper thread view, not a tab.

**"A folder of scripts is a 2010 idea."** The format is old on purpose: plain files are what agents are best at editing and what users can inspect, diff and back up. What is new is who writes them and how they come into being.

## 7. Build order

The sequence is arranged so the central bet is tested by week six, using the cheapest possible versions of everything else.

**Weeks 1–2: the reflex core.** *Solo: yes.*
- Native panel on a global hotkey, kept warm.
- App index with a learned abbreviation ranker, file-name search over the system metadata index, a calculator.
- The command file format, the folder, hot reload, and three or four built-ins written in that format.
- Automated latency tests against the budgets above.
- Exit test: the developer uninstalls their current launcher and does not miss it for app launching.

**Weeks 3–4: dispatch and the inbox.** *Solo: yes.*
- One agent adapter (whichever agent the developer uses daily, after checking its terms), streaming, detached from the panel.
- Context chips for selection, frontmost document and clipboard.
- The agent row and its dedicated key.
- The *Waiting* zone with typed results in list, detail and table views.

**Weeks 5–6: Keep.** *Solo: yes, and this is the experiment that decides the product.*
- The contract document, the forge prompt, recorded examples, the diff review view, git commits with provenance, and Repair.
- No sandbox yet: restrict forged tools to a reviewed allowlist of executables and show capabilities as declarations.
- Then stop building and use it for two weeks. Measure how many jobs were kept, how many kept commands ran three or more times, what fraction of all invocations were served by forged tools, and how often Repair was needed.

**Weeks 7–9: the surface.** *Solo: yes.*
- The launcher MCP server with `context.get`, `command.run`, `ui.ask`, `ui.show` and `forge.propose`.
- Self-modification of built-ins through the same review path.
- A second agent adapter to prove the layer is real.

**Weeks 10–14: trust and the classics.** *Solo: feasible but slow; sandboxing is the part most likely to overrun.*
- Sandbox enforcement of capabilities, effect classes and confirmations, the journal.
- Clipboard history, static snippets and window layouts as userland commands on the native API.

**Later, or with help.**
- The on-device lane 1.
- Intent cards and any sharing mechanism.
- MCP Apps rendering.
- Voice.
- A polished onboarding that detects installed agents.
- Sync.

The sharing ecosystem and a hardened security story are where a team, or at least an outside security review, becomes necessary.

What not to build, at least for a year: a store, a chat tab, a visual workflow editor, notes, a theme designer, a Windows version. Each is a reason the incumbents are heavy, and none of them tests the bet.