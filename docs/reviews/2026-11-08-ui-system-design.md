# Wicket's native UI system: design

Grounded in CONCEPT.md, the 2026-11-08 advisor review, `Content.swift`, `Item.swift`, `Frame.swift`, `PaletteView.swift` and `DetailView.swift`. Nothing here reopens the four decided points.

## 1. Principles

1. **Semantic, never visual.** A component names what the content *is* (a list of things, a page, a fact with a label, a file), never how to draw it. No colours, fonts, sizes, column counts or layout containers in the vocabulary. Wicket owns the look, so agent output and search results can't drift apart.
2. **Two surfaces, already there.** The palette has rows (selection, Return, ⌘K, whole-row sizing) and pages (measured, scrolling, title in the pill). Every component is a row, a page, or a slot inside one. Anything that would need a third keyboard model doesn't belong.
3. **Entities over presentation.** When Wicket can derive icon, actions and preview from an identifier with OS APIs the core already has, the producer sends the identifier and nothing else.
4. **Markdown is the escape hatch, not a component factory.** Headings, tables, code, quotes and links are already in `detail`. A new component must do something markdown can't: be selectable, be acted on, or be derived from an entity. Status, progress, charts fail this test today.
5. **One vocabulary, two authorities.** Agents and extensions share every type; what differs is a profile stamped at decode (section 5), not a second format.
6. **The schema is the advertisement.** The agent only ever sees the subset the running build can draw. New components appear in the schema the version they ship.
7. **Two producers or it waits.** A component ships when a built-in and an extension (or the agent) both need it. One hypothetical use isn't enough.

## 2. The vocabulary

A reply or result is exactly one **screen**. The screen kind is the only top-level choice a producer makes.

### v1 (ship first)

**answer**: one fact that fits a line. `{"answer":{"title":"12","subtitle":"15% of 80"}}`. Shown as the 60-pt prominent row; Return copies the title. Producers: extensions (today), agent (short facts), calculator (built-in, already).

**list**, gaining two optional slots:

```json
{"list":{
  "intro":"Four files changed today, all under Sources/.",
  "sections":[{"title":"Modified","items":[{"file":"~/Private/wicket/Sources/WicketCore/Frame.swift"}]},
              {"title":"Added","items":[{"file":"~/Private/wicket/Tests/FrameTests.swift","accessory":"new"}]}]}}
```

`intro` is short markdown pinned above the rows (inline styles and links; clipped at four lines; not selectable, the rows start the selection). `sections` are titled groups; a list has `items` or `sections`, never both. Section headers are small secondary labels like Spotlight's "Documents", not selectable, skipped by the arrows. Sizing: intro and headers are measured like a page, rows stay whole, so the eight-row rule holds. Producers: extensions, agent, built-ins (Extensions screen gains sections for free).

**detail**: markdown plus `metadata` plus `actions`, as today, with one renderer rule: a detail whose markdown is empty or one line lays the metadata out full-width as a two-column table instead of a 180-pt sidebar. "Tell me about this file" then looks right without a new component.

**Item subjects** (section 3): `file` and `url` on any item, in lists, grids and answers.

**Actions**: `open`, `copy`, `paste`, `detail` (push a page), `run`, plus host-derived `reveal` and Quick Look. Nothing new.

### v2

**grid**: `{"grid":{"items":[...]}}`, same items as a list. Wicket picks columns from the width; the arrows move in two dimensions; Return and ⌘K unchanged. Tiles show a Quick Look thumbnail for `file` items, a swatch for `color` subjects, a symbol otherwise. Images come only from local paths (an `image` icon kind); never fetched over the network for any producer. Producers: extensions (emoji, colours, screenshots), agent ("my screenshots from today" is a grid of file subjects with no extra fields).

**show**: generalises the `detail` action to push any screen already in hand: `{"show":{"list":{...}}}`. `detail` stays forever as its alias. This gives agents drill-down (a row opens a sub-list or a page) with no execution, and extensions a push without a hidden command.

**reply** (agent profile only): `{"reply":{"text":"Yes, move them to the Trash"}}` on a row. Its title is its text, exactly, and Return sends it as a Follow Up to the same session. This is the agent's form: it replaces the declined AskUserQuestion with a list of options, no new screen.

**Typed metadata values and accessories**: a metadata entry or accessory may be `{"date":"2026-11-08T10:00:00Z"}` (shown relative, in the user's locale) or a `file`/`url` (opens, Quick Looks). Say what, Wicket formats.

**form** (extension profile only): `{"form":{"fields":[{"id":"title","kind":"text","label":"Title"}],"submit":{"run":{"command":"add"}}}}`, fields text, secure, toggle, choice; values arrive in `args`. Tab moves between fields; Return in the last field submits. The pill holds the title; the card holds the fields.

### Later, only on a concrete need

`app` subject (bundle id: icon, Open, Reveal, Quit); `color` subject; `progress` as a metadata value; a `sparkline` metadata value drawn with Swift Charts. Rejected outright: layout containers, free-form block stacks, custom colours, streaming patches, remote images, charts as screens (there is no answer to "what does Return do on a chart" in a 600-pt card).

### Composition

A screen is one kind. Composition exists only in fixed slots: `list.intro`, `list.sections`, `detail.metadata`, an item's subject, and actions. No screen inside a screen, no list inside a page, no block trees. Depth comes from navigation (`detail`, later `show`), which the frame stack already handles. Reason: selection and card sizing stay computable, the keyboard model stays one per screen, and the agent faces one decision at the top instead of a layout problem.

## 3. Entities versus presentation

An item may carry one **subject**: `"file": "<path or file URL>"` or `"url": "<web, mail or app URL>"`. Wicket derives what the subject implies and the producer's explicit fields win:

| Subject | Title | Subtitle | Icon | Derived actions | Preview |
|---|---|---|---|---|---|
| `file` | last path component | parent folder, `~`-relative | Finder icon | Open, Reveal in Finder, Copy Path | Quick Look on Space |
| `url` | host, or the URL | the path | `globe`, `envelope` for mailto | Open, Copy Link | none |

Derived actions come after the producer's own, deduplicated by kind and target, so an extension can put "Mark as Read" first and still get Reveal. Under the agent profile, Open goes through `Item.Action.following`, so an app or script is revealed, never launched.

How far: `file` and `url` in v1, `app` and `color` when a producer appears, and stop there. The test for an entity belonging in the core: Wicket can derive everything from the identifier alone with APIs it already links (file system, Launch Services, URL parsing). Contacts, events and messages fail it; they need data access, which is an extension's job.

## 4. How the agent chooses

Proposed text for `agent.md`, under "Your reply":

> Reply with one screen in the shape Wicket gives you. Pick by what the user should see, not by how you worked:
>
> - **answer**: one fact that fits a line: a number, a date, a name. Return copies it.
> - **list**: several things the user may open, pick or copy: files, links, results, options. One row per thing. Say what a row is (`file`, `url`) instead of describing it; Wicket adds the icon and the actions. A sentence of context goes in `intro`. Never a list of one.
> - **detail**: anything that is prose: an explanation, steps, code, a comparison, what you did. Markdown. Facts with labels go in `metadata`, not in the text.
>
> Don't narrate the UI ("here is a list"), don't put paths in prose when they can be rows, and don't invent fields: Wicket draws only what the schema names.

Keeping the schema legible as it grows: one source, `extension.schema.json`, with a one-sentence `description` and one inline example on every component and slot, and a `since` note per addition. A Core function, `ReplySchema.make(for: .agent)`, derives the provider schema from the same `$defs` by selecting the profile's allowed components and actions, inlining refs, and rewriting for strictness: an object root (`{"screen": …}`, which Wicket unwraps), `oneOf` to `anyOf`, every property required with `null` allowed where optional (Codex and OpenAI strict mode), and unsupported keywords (`format`, `if`/`then`, length limits) dropped. Claude Code's `--json-schema` takes the same output. Tests validate a fixture folder of replies against the generated schema and the Core decoder together, so the schema can never advertise what the decoder rejects.

## 5. Authority profiles

An `Authority` is stamped at decode: `.host`, `.extension(revision)`, `.agent`. One table in Core answers "may this authority send this screen or action", and three things read it: the decoder (a disallowed action fails the reply, which falls back to prose with a notice, or fails the checker), the schema generator (the agent never sees `run`), and the action panel (which names the real target).

| | Extension | Agent (v1) |
|---|---|---|
| Screens | answer, list, detail, later grid and form | answer, list, detail, later grid |
| open | any URL, apps included | through `following`: web, mail, files; apps and scripts revealed |
| copy, detail / show | yes | yes |
| paste | yes | no (text could differ from what the row shows) |
| run | own commands, revision-bound | never |
| reply | no | yes (v2) |
| Derived file actions, Quick Look | yes | yes |

Agent rows take the origin `builtin:run-agent`, ids namespaced per run, and no frecency: they are ephemeral.

## 6. Compatibility and versioning

Protocol stays 1. Every change here is additive: new optional fields (`intro`, `sections`, `file`, `url`), new result keys (`grid`, `form`) and new action keys (`show`, `reply`). No field changes meaning and no default moves, so every existing extension and fixture decodes unchanged. Strict decoding stays: an extension using `intro` on an older Wicket fails loudly, which is the documented contract. The docs page gets a "since" column; the checker warns when a manifest's commands use a field newer than the version the extension declares it was tested with, only if that proves necessary. Protocol 2 is reserved for a change of meaning, never for additions. The agent schema needs no version at all: it is generated by the build that draws it.

## 7. Comparison

**Raycast.** Take: the small fixed set (List, Grid, Detail, Form); the first action as primary with the rest in a panel; a metadata column of labelled values; sections in lists. Reject: UI as React code in the extension process (ours is data); accessory arrays of icons, tags, dates and tint colours (agents over-decorate, and colour is "how"); split-view detail beside a list (no room at 600 pt, push instead); `EmptyView` and loading customisation (the frame owns those); Form's dozen field types (four).

**A2UI.** Take: a declared catalog the agent fills, validated strictly, nothing outside it. Reject: generic Row, Column and Card containers (layout is "how"), data-binding paths and incremental patch streams (deferred by all three advisors).

**Apple.** Spotlight: one-line rows, sections by kind, the top hit large, Quick Look on Space; adopted as is. App Intents and Shortcuts: an intent returns a typed entity and the system draws it; this is the subject model, and the strongest precedent for "say what, not how". Widgets: fixed families, system-drawn, no custom controls; the same discipline as our fixed screens. Rejected: Shortcuts' nested value trees.

**Vicinae.** Raycast API compatibility pulls the whole React surface into a Qt renderer; a warning about compatibility layers, not a model. Per the design-first rule, check Tinycast's extension detail rendering before building, for pitfalls only.

## 8. The v1 slice and how to judge it

Build, in order: (1) `Authority` and the agent schema generator from the shared schema; (2) `list.intro` and `list.sections` in `Screen`, decoding and `ResultsView`, with the sizing rule; (3) `file` and `url` subjects with derived defaults and actions, Quick Look on Space for file rows (first thing cut if `QLPreviewPanel` fights the non-activating panel); (4) the agent reply through structured output into `Screen`, prose with a notice on failure, the full-width metadata rule; (5) the `agent.md` text. Not in v1: grid, form, show, reply, typed values.

Evaluate with real replies from both CLIs, each prompt three times, scored on: valid structured output, the right screen kind, paths as `file` rows rather than prose, no UI narration, intro at most two sentences, sensible actions. Target: 90% valid, 80% right kind before the owner sees it.

| Prompt | Good looks like |
|---|---|
| what did I change today in this repo | list, `file` rows, one-line intro |
| five largest files in Downloads | list, `file` rows, sizes as accessories |
| find the October PDF invoices | list, `file` rows, no prose |
| capital of Peru | answer |
| what time is it in Tokyo | answer |
| explain TCP versus UDP | detail |
| summarize README.md | detail, metadata with the file, Open action |
| three good links on Liquid Glass | list, `url` rows |
| how do I rebase onto main | detail with code |
| list my git branches | list, Copy actions, no subjects |
| which apps use the most memory | list, accessories, no subject (app comes later) |
| compare these two files (Finder selection) | detail, metadata, both files as actions |
| which of these files are duplicates (selection) | list with sections Duplicates and Unique |
| what does this error mean: … | detail |
| where is PaletteMetrics defined | list, `file` rows with subtitle overridden to the line |
| write a haiku about launchers | detail, not answer |
| open my Downloads folder | acts, then detail saying so; never a list of one |
| delete the .DS_Store files here | acts, then list of removed files or a detail; no `run` attempted |
| latest Swift version | answer, or detail with a `url` action |
| what can you do in Wicket | detail (reads the command list) |

Two adversarial checks: a prompt whose natural reply is prose full of paths (does it choose a list?), and a reply with a disallowed action (does the decoder fall back to prose with the notice?).

## 9. Open questions, with recommendations

1. **Agent `paste` in v1?** No. Copy covers it, and shown text equalling pasted text is a guarantee worth keeping until someone asks.
2. **Quick Look in v1?** Yes if `QLPreviewPanel` works with the non-activating panel in under a day; it is the proof that subjects pay off. Otherwise first in v2.
3. **Intro cap.** Clip at four lines and tell the agent "one or two sentences". Letting the intro grow turns lists back into pages.
4. **`show` now or later?** v2, keeping `detail` as a permanent alias. Nothing in v1 needs it and renaming churns extensions.
5. **Remote images.** Never, for any producer. An extension downloads into `WICKET_DATA_DIR` and names the path.
6. **Lists after acting runs.** Allow them. A list of renamed files is a result, not an action, and present-only still holds.
7. **Root wrapper.** `{"screen": …}` for provider strictness, unwrapped by Wicket. Flat exactly-one-key roots don't survive strict mode.
8. **Sections in the root search.** Not now. The ranker's tiers are deliberate and Spotlight-style grouping would reopen ranking; revisit when the Extensions screen and agent lists have proven sections.
