# A launcher that leaves you with better tools

Research and recommendation, 14 November 2026.

## 1. TL;DR

- **Build a personal workbench with a launcher-sized entrance.** Its defining loop is: select something, ask for a change, inspect the result, and optionally turn the successful operation into an editable tool. The agent helps build the interface you will use next time.
- **The durable unit is an operation, not a conversation.** An operation has inputs, a result, execution status, permissions, and a reusable definition. Chat is available for clarification; it does not own every interaction.
- **Separate invention from execution.** Agents discover how to solve unfamiliar problems. Saved tools execute stable logic directly where possible. Repeated use should often require less inference, not progressively longer conversations.
- **The competitive opening is narrower than the premise suggests.** Raycast already documents contextual AI, tools, memory, skills, and subscription connections; Alfred 6 previews native custom interfaces. “AI plus hackability” is not enough. Make ownership, inspection, modification, and dependable reuse the whole product.
- **Keep the boring fast paths.** Opening apps, arithmetic, exact snippets, aliases, and window commands should never wait for a model. Local execution and cloud-free execution are related but different promises.
- **Treat context and authorization as visible objects.** Show exactly which selection, files, or account are involved. A preview should describe concrete effects. Generated code must not gain the launcher's full privileges by default.
- **Start alongside existing launchers.** Test the select–transform–save–reuse loop on local text and files before trying to replace anyone's daily command bar. A solo developer can test this in weeks; a secure general agent platform is a much larger undertaking.

## 2. Landscape

### Scope and evidence

This is web research, not hands-on benchmarking. Product documentation establishes what vendors describe as available; it does not establish quality, reliability, adoption, or unrestricted availability. Research is dated because this category is moving quickly. The interpretations of *why* features exist below are product analysis, not claims about vendors' internal intentions. Upcoming features are explicitly separated from documented current ones.

### Raycast: an integrated productivity environment

Raycast's v2 manual describes unified file results, Quick AI in root search, screen and selection context, automatic AI extension selection, persistent profile and memory, agents, skills, and dictation. Its proposition has moved considerably beyond a separate chat tab. These features reduce the effort of supplying context and choosing integrations; they also make Raycast a destination for continuing work. [Raycast v2 overview](https://manual.raycast.com/new-in-v2)

AI Commands package frequently used prompts into commands. AI Extensions expose actions, including operations on Raycast Notes, while tool permissions govern whether actions need approval. The permission documentation distinguishes Ask, Auto, and Always Allow and lets users inspect shell commands. Reusable prompting and action execution are therefore existing competition, not proposed differentiators. [AI Commands](https://manual.raycast.com/ai/ai-commands), [AI Extensions](https://manual.raycast.com/ai/ai-extensions)

Notes provides a formatted writing surface with Markdown-style input and keyboard actions. Its strategic role is to keep lightweight capture and intermediate work within reach of the command interface. [Notes](https://manual.raycast.com/notes)

Raycast already has two extensibility levels: scripts for straightforward execution and TypeScript extensions for richer native views. Its React interface is rendered through native AppKit-backed views, rather than ordinary HTML. The store packages discovery and installation for people who do not want to manage scripts themselves. An agent can already help someone write these extensions; “the AI writes plugins” alone is weak positioning. [Extension API FAQ](https://developers.raycast.com/misc/faq), [Script Commands](https://manual.raycast.com/script-commands)

Crucially, Raycast documents using signed-in local Claude Code and Codex tools to access existing subscriptions, with prompts traveling through the provider's local tool. Bringing an existing subscription is already a competitive feature. It should be a compatibility requirement, not the headline of the new product. [Bring Your Own Subscription](https://manual.raycast.com/ai/bring-your-own-subscription)

### Alfred: user-programmable productivity, with a stronger UI coming

Alfred's current offering includes app and file discovery, calculator, clipboard, snippets, and workflows. Its workflow model connects triggers, transformations, scripts, and outputs. The reason it persists is simple: users encode personal procedures once and summon them cheaply. [Features](https://www.alfredapp.com/help/features/), [Workflows](https://www.alfredapp.com/help/workflows/)

Universal Actions already starts from an object: select text, a URL, or a file, then choose a relevant action. This is an important ancestor of the proposed concept. Selection-first interaction is neither new nor intrinsically AI-native. [Universal Actions](https://www.alfredapp.com/help/features/universal-actions/)

**Alfred 6 is still presented as upcoming in the sources reviewed.** Its autumn announcement and expanded preview describe a native UI toolkit for workflows, interfaces inside or outside Alfred, optional AI using a chosen model and API key, refreshed preferences, and query history. Examples include a text transformation workflow and an app browser. The current changelog lists Alfred 5.8.1. Do not assert that Alfred 6 has shipped or that its full API is known. [Announcement](https://www.alfredapp.com/blog/announcements/alfred-6-coming-soon/), [Expanded preview](https://www.alfredapp.com/v6/?sneak2=), [Changelog](https://www.alfredapp.com/changelog/)

The implication is substantial: a native toolkit for custom tools is about to become a more direct incumbent strength. The new product needs a superior lifecycle for creating and maintaining those tools, not merely a nicer list renderer.

### LaunchBar: compositional interaction deserves another look

LaunchBar documents adaptive abbreviations, app and document access, Instant Send, Send To, browsing, clipboard history and ClipMerge, scriptable actions, and a calculator. Instant Send passes selected content into the launcher; subsequent actions operate on that content. [LaunchBar features](https://www.obdev.at/products/launchbar/features.html)

The lasting insight is a lightweight grammar: **object → operation → destination**. It makes composition possible without prose. AI should fill gaps in this grammar and help author new operations, rather than discard the grammar. The clipboard is also a temporary collection surface, not just a searchable log.

### Spotlight and Siri: the default baseline has risen

Tahoe expanded Spotlight with actions, quick keys, browse views, clipboard history, and access to shortcuts. Apple's feature document also describes menu-bar search and intelligent Shortcuts actions. These cover much of the traditional launcher checklist and connect system actions with model assistance. [Tahoe announcement](https://www.apple.com/newsroom/2025/06/macos-tahoe-26-makes-the-mac-more-capable-productive-and-intelligent-than-ever/), [Tahoe feature document](https://www.apple.com/os/pdf/All_New_Features_macOS_Tahoe_Sept_2025.pdf)

For the later version, Apple's current macOS 27 Golden Gate page describes Siri AI, an Ask Siri option in Spotlight, personal-context retrieval, actions in supported apps, screen-based questions, and a dedicated conversation app. It states English availability and possible usage limits. These are Apple's published capabilities, not evidence that Siri reliably completes arbitrary cross-app work. [macOS 27](https://www.apple.com/os/macos/)

The strategic pressure is nevertheless clear: basic launching, natural-language help, and context-aware system actions face a bundled competitor. An indie product needs to serve users who want more control over their tools and execution rules than the system provides.

### Adjacent products: the agent desktop is already crowded

**Claude Cowork:** documentation describes computer use in Cowork and Claude Code, including navigating apps when a connector or suitable tool is unavailable. Current safety documentation says Cowork sessions run on Anthropic's servers and reach local resources through the desktop app. Avoid the outdated assumption that “desktop agent” necessarily means local inference or entirely local execution. The product threatens generic task delegation as a standalone proposition. [Computer use](https://support.claude.com/en/articles/14128542-let-claude-use-your-computer-in-cowork), [Safety and architecture](https://support.claude.com/en/articles/13364135-use-claude-cowork-safely)

**Accomplish:** its official repository presents an open-source desktop agent for local file, document, and browser work. Openness and desktop automation are therefore also occupied territory. The opportunity is not merely to make a hackable agent application. [Accomplish repository](https://github.com/assia-ai/accomplish)

**BoltAI:** documents a native SwiftUI/AppKit AI client, alongside inline AI and customization. It competes for the convenient Mac-native AI access position. A native floating interface is valuable, but insufficient differentiation. [BoltAI features](https://help.boltai.com/articles/2306606-features)

**Warp:** its command palette finds workflows, prompts, notebooks, settings, and sessions. Its workflow documentation explicitly supports saving parameterized commands from agent results. This is direct precedent for turning agent output into reusable actions. Our differentiation must go beyond Save as Workflow: native result inspection, typed object handling, versioned behavior, and changes to the workbench itself. [Command palette](https://docs.warp.dev/terminal/command-palette), [Workflows](https://docs.warp.dev/knowledge-and-collaboration/warp-drive/workflows)

**MCP Apps:** the official extension lets tools return interactive interfaces rather than only text. Its overview describes charts, forms, and dashboards rendered in iframes inside compatible hosts. This makes shared interactive tooling more feasible, but does not make those interfaces native or guarantee that tool code is trustworthy. [Announcement](https://blog.modelcontextprotocol.io/posts/2026-01-26-mcp-apps/), [Technical overview](https://github.com/modelcontextprotocol/ext-apps/blob/main/docs/overview.md)

Taken together, these products occupy retrieval, automation, conversation, context capture, and custom UI. The proposed opening is a deliberately integrated transition from **one-off work to owned, dependable capability**. That is a product hypothesis, not a claim of unprecedented invention.

## 3. Feature-by-feature challenge

These are proposed design decisions, not descriptions of existing implementations.

| Feature | Decision | Mechanism and rationale |
|---|---|---|
| App launching | Keep | Local index, fuzzy matching, stable aliases, usage ranking. Launch without inference. A known app name needs execution, not interpretation. |
| File search | Keep + reinvent | Immediate filename/path search; optional semantic discovery runs separately. Results are actual file objects with path, date, and preview. An agent may explain a match but cannot invent a file result. |
| Calculator and conversions | Keep | Parse arithmetic and supported units deterministically. Label exchange-rate source and freshness. Let AI translate unusual prose into a visible expression that the calculator evaluates. |
| Clipboard history | Keep + reinvent | Preserve local retrieval and exclusions. Add an explicit tray of selected clips as operation inputs. Do not automatically send history to a model or mistake copied text for instructions. |
| Snippets | Keep | Exact expansion stays exact. Add separately labeled generated drafts when variability is desired. Users should never discover that a legal clause or address was creatively rewritten. |
| Quicklinks | Keep + reinvent | Store typed URL templates and validated arguments. An agent can create or edit the template once; opening it should be direct. Show destination before external submission. |
| Window management | Keep | Stable shortcuts call deterministic operations. AI can help create a named layout from a description; restoring it should not require another conversation. |
| Extensions and store | Reinvent | User-owned tool packages first; curated connectors and templates later. Stores still matter for maintained integrations, updates, and discovery. Generated personal tools do not eliminate that work. |
| Scripts | Reinvent | Add declared inputs, capabilities, structured outputs, preview mode, fixtures, and version history around scripts. Raw shell remains an explicit advanced capability, not the default runtime. |
| AI chat | Absorb | Keep conversational clarification inside operations and optional expansion into a larger window. The result is the document, transformation, answer, or pending decision—not merely the last message. |
| Hotkeys and aliases | Keep | Stable bindings to command IDs and versions. Agent suggestions may propose changes but cannot silently break muscle memory. |
| Settings and theming | Reinvent | Human-editable configuration with schemas, live preview, and rollback. A request like “make file rows denser” edits a visible setting patch. Preserve a conventional settings UI. |
| Notes | Absorb initially | Capture small pieces of working context and save to ordinary files or an existing notes destination. Avoid building a second full notes application before the central loop works. |
| Memory | Reinvent | Explicit project facts, preferences, and reusable tools with provenance, scope, and delete controls. Successful execution is not automatic permission to remember every input forever. |
| Voice | Keep as input | Push-to-talk produces editable intent. It submits through the same operation and permission system as typing. No distinct voice-only agent architecture. |
| Search results | Reinvent | Use typed objects and matching views: file list, diff, form, answer with sources. Renderers are predictable components rather than fresh UI inventions on every invocation. |
| Scheduled automation | Defer, then reinvent | Schedule an already tested tool with explicit scope and expiry. A schedule should not convert a vaguely phrased conversation into unlimited ongoing authority. |
| Menu-bar search/system commands | Keep | Prefer platform actions and exact commands. Model assistance can help discover the correct action, while execution stays visible and direct. |

The governing distinction is not “old feature versus AI feature.” It is **does this interaction require judgment now, or did the user already settle it?** Only the first category benefits from inference on every run.

## 4. The concept

### A personal workbench, entered through a hotkey

Working name: **Workbench**. Positioning: *Your Mac gains tools as you work.*

The panel hosts three related things: objects you want to act on, operations currently happening, and tools you have chosen to keep. A successful operation may become a new tool, and the agent can also propose changes to how the workbench presents or routes those tools.

This is more ambitious than a command catalog but narrower than replacing the desktop. Existing apps remain excellent places for sustained editing, domain-specific work, and complex documents. The workbench handles the seams between them and the recurring small procedures that do not deserve another application.

### What appears before typing

A compact panel opens with the input focused. If invoked normally, it shows pinned tools and a restrained recent list. If invoked using a selection shortcut, the header identifies the captured object: “3 files from Finder” or “Selected text from Mail.” Capturing context should be an explicit interaction, not an excuse to inspect everything on screen.

A small status strip can show “2 running · 1 needs review.” It does not replace the command list with a feed of speculative suggestions. Users can pin one project context; it remains visible until changed.

The body uses a stable hierarchy. Exact local matches come first. Suggestions that require an agent occupy a distinct row. Nothing reorders under the user's cursor because a slower model response arrived. Enter performs the selected action; a separate, discoverable shortcut submits free-form work to the agent. Unknown text is not automatically permission to run a shell command.

### Scenario A: the familiar interaction must remain familiar

Type an app abbreviation and press Enter. The app opens. Type `18*24`; the panel shows `432` immediately, with copy and paste actions. The agent process can be unavailable, rate-limited, or signed out without affecting these operations.

This is not a concession to legacy design. It is the performance foundation that makes a global hotkey trustworthy enough to use dozens of times a day.

### Scenario B: an agent operation becomes a tool

Select several exported images and ask: “Make web copies, maximum 1600 pixels wide, preserve originals.”

The panel first shows selected inputs and the proposed output folder. The agent constructs a transformation using approved image operations. A native preview shows original and proposed dimensions, output names, and estimated storage where determinable. The user can change the maximum width directly in a numeric field.

After execution, the result is a file collection with Open Folder, Copy Files, and Save Tool. Save Tool proposes a small form: name, width parameter, output rule, input type. It does not save the entire conversation as an opaque prompt.

Next time, invoking “Web copies” on images runs the saved transformation without asking the agent to rediscover it. If the user asks, “Also add a suffix,” the agent proposes a new version and previews its effects. The previous version remains usable.

The crucial promise is limited: deterministic steps can become direct execution; ambiguous tasks cannot always be compiled away. A tool that selects the best photograph still needs judgment and must remain labeled as model-dependent.

### Scenario C: a result is an interface, not prose

Select a block of rough text and request “Turn this into a checklist, keep all dates verbatim.” The result is a native diff with selectable changes and a checklist preview. Dates are checked against the input mechanically where possible. The user accepts or edits the output and explicitly pastes it back into the source app.

If the source selection has changed while the agent worked, the tool offers Copy instead of blindly replacing current text. There is no universal Undo claim across arbitrary applications.

The user can save a reusable drafting instruction, but it remains an AI tool. The interface makes the distinction between a verified transformation and a variable generation visible through text labels, not merely colors.

### Scenario D: the tool itself is adjustable

The user says: “When I invoke this on PDFs, show my extraction tool first, use a wider preview, and hide web suggestions.”

The agent edits declarative configuration: a matching rule, an ordering preference, and a view setting. The panel displays the resulting behavior in a preview. Applying it creates a versioned configuration change. The user can open the file, edit it manually, or revert through settings.

This is real hackability at the product surface. The agent is not restricted to authoring a plugin that must fit immutable defaults. Equally, it cannot rewrite the permission broker or disable audit records through an ordinary personalization request.

### Scenario E: longer work can leave the panel

Ask for a comparison of several selected documents. The operation becomes a durable task with attached inputs and an output destination. Dismissing the panel does not cancel it. Reopening shows its status; expanding opens a normal resizable window for detailed inspection.

Completion produces a document or structured result, plus a short receipt of sources and actions. Clarifications appear as specific pending decisions. Do not expose token streaming or every tool call as the primary progress UI. The user needs to know whether work is running, blocked, ready to inspect, or failed.

### Hackability model

A tool is an ordinary directory containing a manifest, implementation or declarative pipeline, optional instructions, fixtures, and display preferences. Required metadata includes an ID, accepted input types, parameter schema, output type, requested capabilities, and execution class: deterministic, model-assisted, or unrestricted advanced script.

The host renders a small vocabulary of native components: lists, forms, text, diffs, file collections, and progress. Most generated tools should be assembled from these components. A future web view escape hatch can support richer interactive content, including compatible MCP Apps, but it should be visibly separate from native controls and isolated from host authority.

The agent can create or patch packages using a documented authoring interface. Promotion follows a lifecycle: draft, preview, fixture checks, user acceptance, activation. Tests are evidence about stated cases, not proof that arbitrary generated code is safe. New capabilities require separate approval even when the tool name has not changed.

Expose user configuration, sorting rules, context adapters, tool definitions, and renderer preferences. Keep the small trusted core stable. Make package formats documented and exportable; ideally publish the SDK and runtime components. Full source availability would strengthen the ownership proposition, but the immediate requirement is that tools remain inspectable and portable rather than trapped in a proprietary database.

### AI architecture: host and adapter, not a new foundation agent

The native host owns input handling, local search, rendering, task state, capability checks, and the tool registry. An execution service owns direct operations. Provider adapters connect to supported installed agents or APIs for planning, tool authoring, and judgment.

Do not assume that a signed-in CLI exposes every session, tool, or approval event through a stable interface. Begin with one documented integration and a contract for task start, progress, cancellation, result, and failure. If an adapter cannot enforce restricted execution, label its runs as delegated to the external agent and preserve that agent's approval boundary. Do not present them as sandboxed workbench operations.

Use APIs, platform actions, or connector tools where they provide reliable operations. Computer use is a fallback for interfaces that lack them; it belongs in a later phase because it is harder to inspect, replay, and constrain. MCP provides interoperability, not a replacement for permission enforcement or integration maintenance.

On-device models may help with optional query classification or private text transformation. They are not needed for exact app matching, and local inference must not compete with the foreground UI for resources. Ship model choice only when it solves a measured problem.

### Latency strategy

Set engineering targets, not marketing claims: warm panel presentation within roughly 50 milliseconds, local results within roughly 100 milliseconds at the 95th percentile on declared reference hardware. Measure cold starts, large indexes, and indexing contention separately.

Keep the native fast path independent of model startup and network access. Search indexes refresh in the background. Show cached remote results with timestamps, never as silently current data. Start inference after explicit submission, not on every keystroke. A queued operation immediately gets a persistent status, even when the actual work takes minutes.

Saved tools remove planning latency only where their inputs and operations are stable. API latency and model calls inside a saved tool still exist; disclose them rather than calling all saved tools “instant.”

### Trust and persistence

Store four distinct things: user-approved preferences, tool definitions, operation receipts, and temporary task context. Give each separate retention and deletion controls. Avoid an undifferentiated memory pool that quietly mixes private documents with reusable behavior.

For constrained tools, use brokered capabilities such as selected-file reads, creation in a chosen directory, or a named connector action. A manifest declaration alone is not enforcement. The runtime must prevent direct bypass; arbitrary shell execution cannot honestly inherit the same guarantee.

The preview and execution should consume the same immutable plan, with input fingerprints checked before applying changes. Otherwise “preview” can describe one thing while the agent later does another. Writes should preserve originals or record rollback information when possible. External sends and irreversible effects need concrete approval showing destination and payload; many have no reliable undo.

Treat retrieved content as data, not instructions. Limit secrets to brokered services and avoid returning credentials to generated code. Keep an inspectable receipt of what actually ran and a stop control with honest semantics: stopping prevents future steps but cannot unsend a message already delivered.

These boundaries are part of the interaction design, not an appendix of warnings. The product's central claim is that users can own increasingly powerful tools without losing the ability to understand their behavior.

## 5. Alternative directions

### An agent dispatch desk

Make the hotkey a universal inbox for agent tasks, approvals, and results across providers. The strongest benefit is reducing scattered ongoing work. A narrow single-provider version is feasible in weeks; reliable cross-provider session control is substantially harder.

Why not lead here: it is a weaker expression of hackability and easily becomes a miniature project-management dashboard. Keep task receipts as supporting infrastructure, not the main product identity.

### A living desktop that predicts the next action

Continuously interpret active apps, documents, and calendar context, then present likely actions before the user asks. The appealing idea is eliminating both command recall and prompt writing.

The objection is strongest precisely where the idea is boldest: continuous access and unstable suggestions can cost more attention than they save. Meaningful prediction requires deep integrations and evaluation across many workflows. A solo developer should not stake the first release on it. Use explicit selection and pinned context instead.

### A generative micro-app factory

Every request produces a custom miniature application. This could unlock personal software for users who never write code, with a launcher as the distribution surface.

Why not lead here: arbitrary interfaces create keyboard inconsistency, maintenance burden, and security complexity. Prototype one or two generated native forms in weeks; a general application factory is a team-scale product. Workbench adopts constrained tool creation while keeping interaction components predictable.

## 6. Risks and objections

**“This is Alfred workflows plus an agent.”** Much of the machinery does have precedent. The differentiation must be observed in the complete loop: less authoring friction, understandable previews, reliable reuse, and cheap modification. If users can achieve the same result as comfortably with an incumbent and their existing agent, stop building a standalone launcher and consider an authoring companion instead.

**“Raycast can copy this.”** Yes. There is no defensible moat in a Save Tool button. The plausible advantage is consistent product focus, an open package ecosystem, and better handling of personal modifications and maintenance. That can support a focused indie business without creating a winner-take-all platform.

**“Generated tools become abandoned software.”** This is the central operational risk. Pin versions, constrain dependencies, bundle stable primitives, and keep representative fixtures. Fail with a clear repair action rather than silently letting the agent rewrite and retry with broader privileges. Someone must still own connector maintenance.

**“Users do not want to build tools.”** Then do not ask them to start with a blank editor. Complete a useful task first. Offer saving only when the result has reusable structure or when the user asks. Measure subsequent reuse, not the number of tools generated during onboarding.

**“The safety system is too much for one developer.”** A general secure plugin runtime is. The early version should use declarative compositions over a small set of host operations. Defer arbitrary privileged code and broad computer control. Native presentation and a handful of constrained transforms are achievable; comprehensive isolation and enterprise policy need specialized work.

**“The panel is too small.”** Correct for complex review. Start compact, expand for structured results, and move to a regular window for extended work. Keeping everything tiny is not a virtue if it hides information needed to make a decision.

**“Bring-your-own-agent will be brittle.”** Provider integration and subscription behavior can change. Use supported interfaces, keep adapters modular, and make local functions useful when an adapter fails. Never promise universal subscription compatibility merely because two CLIs are installed.

**“Customization will destroy consistency.”** Reserve keyboard and accessibility invariants in the host. Let users change content, ordering, parameters, and components while keeping navigation and approval controls recognizable. Offer safe mode that disables user packages and restores the default shell.

## 7. Build order

### First: test the interaction bet, not the category checklist

Target technical Mac users who already use an agent and repeatedly transform text or files. Recruit a small pilot whose real recurring tasks can be observed with consent. The question is whether they return to tools created through the workbench when the original agent could also do the task again.

**Weeks 1–2: a narrow native shell.** Implement a global hotkey, explicit selection capture, a local command list, and predictable dismissal. Support text plus a small set of file objects. Add native forms, diffs, and result lists. Ship three hand-authored operations to establish quality. Measure latency with inference disabled.

**Weeks 3–4: authoring and reuse.** Connect one supported agent adapter. Let it assemble tools from a restricted catalog of operations, save a manifest, and produce sample cases. Implement preview, activation, direct replay, and visible model-dependent labels. Demonstrate one transformation becoming a command that can be reused while the agent is disconnected.

**Weeks 5–6: modification and recovery.** Add tool versioning, configuration patches, rollback, task receipts, failure states, and safe mode. Test the full loop with pilot users on their own tasks. This is a constrained prototype estimate, not a promise of a production-grade automation platform.

Measure: time to first useful result; time and effort to save a tool; successful reuse a week later; modification success; repair burden; local interaction latency; and whether users voluntarily invoke the workbench instead of re-prompting their agent. Record incidents where previews misrepresent effects as failures, regardless of eventual task completion.

A reasonable initial decision rule is that several pilot users independently reuse multiple personal tools and can modify one without developer help. Set the numerical threshold before the pilot; do not optimize it afterward to declare success. If reuse is weak, investigate whether tasks are too variable, tool discovery is poor, or the agent is already the better interface.

Only after that evidence, expand file discovery, clipboard, exact snippets, and window commands enough to earn the primary launcher hotkey. Add maintained connectors next. Broad MCP hosting, arbitrary code execution, computer use, sync, scheduling, and a public marketplace each bring separate product and security obligations; none is necessary to test the central bet.

The release should demonstrate one memorable fact: **a task the agent helped solve yesterday is a small, understandable tool the user can operate and reshape today.**
