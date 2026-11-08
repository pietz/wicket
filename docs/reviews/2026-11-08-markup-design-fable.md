# Agent UI, round 4: markdown with Wicket components

Design for the owner's "back to the drawing board": agents get real expressive freedom, Wicket keeps every pixel and every action. Read-only review of the repo at 45735ee; nothing here reopens native rendering, untrusted agent output, "Show online content" on by default, choices later, or one vocabulary for agents and extensions.

Two facts from the code shape the recommendation. First, the harness structured-output path is **designed but not wired**: `AgentOutput.decode` and `ReplySchema.project` have no caller in `WicketHost`, no adapter passes a schema, and the agent still replies in prose that `DetailView` renders. Second, Foundation's markdown parser keeps unknown tags verbatim (checked with a script: `<stat …/>` inside a paragraph stays text, a block of `<chart>…</chart>` comes through as one unstyled run with its lines intact). So markup costs no second parser and no dependency, and the switch happens before any structured-output code has to be undone in the adapters.

## 1. The model: a document, not a screen

**A reply is one markdown document in which Wicket component tags are blocks.** Prose, headings, lists, code and tables are markdown as today. Where the agent wants something the user can see at a glance or act on, it writes a tag:

```
Cool and wet until Thursday, **clearing for the weekend**.

<stat value="9°" label="Now" detail="Light rain" icon="cloud.rain"/>
<stat value="11° / 5°" label="Today"/>

<file path="~/Documents/Invoices/Hetzner 2026-10.pdf" accessory="overdue"/>
```

Rules of the syntax, chosen so the model cannot get them half right:

- Tags are HTML-like, lowercase, no prefix. Attributes are `name="value"` (single quotes and no quotes tolerated). A tag either self-closes or wraps content until its closing tag.
- Tags are **block level**: a tag starts at the beginning of a line. Inside a paragraph, `<` is text. Entities referenced inline are markdown links (`[the invoice](~/Documents/Invoices/Hetzner.pdf)`), which already go through Wicket's link policy; entities as blocks are rows. One inline tag, `<badge>`, comes in v2.
- Anything inside a fenced code block is code. This answers round 1's "quoted examples are ambiguous" objection.
- **Repeating a tag makes a group.** Adjacent `<stat>`s form a strip, adjacent rows form a list, adjacent `<event>`s a timeline, adjacent `<image>`s a gallery. Wrapper tags (`<list title>`, `<stats>`, `<timeline>`) are optional and only add a title. This is the single biggest simplification versus a tree format: the agent gets composition without nesting.
- **Containers for layout, bounded:** `<columns>` with `<column>` children, and `<card>`. Nothing else positions anything. No sizes, colours, fonts or classes; the one presentational attribute is a semantic `tone` on stat, badge, callout and progress.
- Unknown tags and unknown attributes are not errors. An unknown tag shows as the text it is; an unknown attribute is dropped. Both are counted in the log.

**Why markup, against the alternatives, honestly.**

A JSON tree (A2UI, Adaptive Cards, Block Kit) gives harness enforcement and typed attributes, and that is where its advantages end. Prose becomes escaped strings in `{"type":"text"}` nodes, which is most of what a launcher answer is. Under OpenAI strict mode every property is required and nullable, so twenty components with five attributes each make replies that are mostly `null` (the spike measured 369 versus 208 output tokens for a tiny list). Streaming needs a partial-JSON parser. And models have seen far more markdown-with-tags (MDX, Markdoc, Claude artifacts, Vercel's streaming UI) than any JSON UI dialect; the first iteration's "underwhelming" is partly the format: fixed slots invite fixed replies.

The hybrid, a schema of `{"markup": string}`, buys one guaranteed field at the cost of everything the spike flagged: Claude writes the answer twice unless told not to, the tool definition changes the prompt-cache prefix, Codex's final message must be held back and unescaped, and streaming is gone. It enforces nothing about the markup itself.

So: **markup in the agent's final message, no harness structured output.** The parser is tolerant, validation lives in Wicket, and if evaluation ever shows a model forgetting the format, the `{markup}` schema is a one-line change in the adapters since the parser is the same. Tinycast renders AI answers as plain markdown (its `ai.md` has no richer vocabulary), so there is nothing to adopt there.

## 2. The catalog, tiered

All components render inside the card at the palette width (600 pt default, 480 to 900) with the page's 18 pt padding; "row" means today's 40 pt selectable row with icon, title, subtitle and accessory. The agent's `textSize` scaling applies throughout.

**Tier 0, markdown.** Headings, paragraphs, emphasis, inline code, links, ordered and bulleted lists, code blocks, quotes, tables, rules: `MarkdownBlock` as built. A markdown image `![alt](src)` is lifted to `<image>`.

**Tier 1, v1.**

| Tag | Attributes | Renders as | Focusable |
|---|---|---|---|
| `answer` | `value`, `detail`, `icon` | The 60 pt hero row, value large, detail under it. One per document; a second becomes a stat. Return copies the value. | yes |
| `stat` | `value`, `label`, `detail`, `icon`, `tone`, `trend` ("12,14,9", a 40×16 sparkline beside the value) | A tile: label 11 pt secondary, value 20 pt semibold, detail 11 pt. Adjacent stats share one strip, up to four per line, equal widths, wrapping. `tone` colours the value with system green, red or orange. | no |
| `fact` | `label`, `value` | Adjacent facts form the two-column label and value table (today's `MetadataTable`). The in-document form of `detail.metadata`. | no |
| `file` | `path`, `title`, `subtitle`, `accessory`, `icon` | A row with the file subject's derivation: Finder icon, folder, modified date, Open, Reveal in Finder, Copy Path. | yes |
| `url` | `href`, `title`, `subtitle`, `accessory`, `icon` | A row with the url subject's derivation: host, path, globe, Open, Copy Link. | yes |
| `item` | `title`, `subtitle`, `accessory`, `icon`, plus one of `href`, `path`, `copy` | A plain row. Its one attribute gives the primary action; `copy` without a target offers Copy only. | yes |
| `list` | `title` | Optional wrapper for rows: a 24 pt section title, arrows skip it. | no |
| `chart` | `kind` (bar, line, area), `title`, `unit`; children `<point x y series/>` | Swift Charts, 120 pt tall, full content width (narrower in a column), x labels from `x`, `unit` on the axis, series by `foregroundStyle(by:)` in the system palette with a legend when there is more than one. At most 200 points. | no |
| `image` | `src` (https or a local path), `alt`, `caption` | Up to 200 pt tall, 8 pt radius, caption and source host under it; fetched by Wicket under the v2 image rules ("Show online content", Load Image when off); local files through `QLThumbnailGenerator`. Adjacent images form a two or three-up gallery. Return opens the source under the link policy. | yes |
| `progress` | `value`, `max`, `label`, `tone` | Label, a 6 pt bar, "3 of 5" at the right. | no |
| `callout` | `tone` (info, positive, warning, negative); markdown content | A tinted inset block with the tone's symbol (info.circle, checkmark.circle, exclamationmark.triangle, xmark.octagon). | no |
| `event` | `time`, `end`, `title`, `detail`, `href` or `path` | Adjacent events form a timeline: a 52 pt time column, a vertical line with dots, title and detail. With a target it is a row with Open. | with target |
| `card` | `title`, `subtitle`, optional `href` or `path`; any content | A grouped inset (secondary fill, 12 pt radius) with a 13 pt semibold title row. With a target the whole card is one row and Return opens it. | with target |
| `columns` / `column` | none | Equal-width columns, 12 pt gap, at most three (a fourth wraps). Each column holds any blocks. Columns inside a column are flattened. | no |

**Tier 2, after v1 lands.** `badge` (inline, `tone`, text content), `choices`/`choice` (the decided Follow Up rows, agent only), `grid` (tiles of images or entities with two-dimensional arrows), `app` row (bundle id or name: icon, Open, Reveal, Quit), `map` (`lat`, `lon`, `label`, a MapKit snapshot, counts as online content), `table` as a typed component only if markdown tables prove insufficient for selectable rows.

**Later, on two use cases.** `contact` (needs Contacts permission), `color`, a `form` for extensions. Still rejected: free HTML, styles, absolute layout, scripts, data binding, patch streams.

A weather card, a comparison or a "what changed" report are compositions of these, not components of their own. That is the test of the catalog: the five examples in section 9 use only tier 1.

## 3. Keyboard and selection

The document scrolls; some of its blocks are rows. This is the piece round 1 avoided and the owner's ask now requires, so it gets one model, not two.

- **Focusable:** answer, rows (file, url, item), images, events and cards with a target, choices later. Prose, stats, facts, charts, callouts and columns are never focused. Links inside prose are clicked, not arrowed; ⌘K's screen group lists them as "Open <host>" in v2 so they stay reachable by keyboard.
- **Arrows** move through focusable blocks in document order, scrolling to keep the focused one visible. In a gallery or grid, ← and → move within the line, ↑ and ↓ across. With nothing focusable, arrows scroll the page, as a page does today.
- **Initial selection:** the first focusable block, if it is inside the initial viewport; otherwise nothing is selected and ↓ selects it and scrolls there. Return on an unseen row would be a trap.
- **Return** runs the selected block's primary action. With no selection it runs the screen's first action, Copy Answer. **⌘↩** stays Follow Up on every agent screen. **⌘K** opens the panel: the selection's actions, then the screen's (Follow Up, Copy Answer, Retry, Review and Enable). **⌘1 to ⌘9** pick the nth focusable block on screen. **Space** is reserved for Quick Look, which still waits on its spike.
- **Escape and ⌘[** keep today's meaning: Escape closes the palette (voice and the panel excepted), ⌘[ pops the frame. The layers are frames, and markup adds none.
- **Typing** on an agent document does not filter: there is nothing meaningful to filter in a document with a chart and three paragraphs. Typing starts a Follow Up with the typed text. Extension lists keep their filter. One sentence in the docs: lists are searched, documents are read.

Selection reuses `ItemList`: the document view registers its focusable blocks in order with a preference key, the frame keeps the selection by id, and `scrollPosition` follows it.

## 4. Control and safety

- **Whitelists.** The tag names in section 2 and the attributes listed per tag. `href` takes https, http and mailto; `path` takes absolute, `~/` and `file:` paths, parsed as `Location` and the file subject do now. Any other scheme makes the attribute text, never a link.
- **Fallback is text.** Unknown or misspelt tags show verbatim, so a mistake is visible instead of silent; a tag never closed closes with its parent. A missing required attribute (a `file` without a path) renders as an `item` without actions. Nothing in the markup can fail a reply; only an empty document falls back to "The agent sent nothing Wicket can show" with Retry and Follow Up.
- **No styling escape hatches.** `tone` on four tags, `icon` as an SF Symbol name that falls back to the tag's default symbol when unknown. This reverses the earlier call that a made-up symbol fails the reply: a tolerant parser makes a bad name harmless, so agent rows may carry icons.
- **Actions stay host-mediated.** Rows decode into `Item` with a `Subject`, so derivation, `Item.Action.merged`, `ActionPolicy` and the dispatcher apply unchanged: under `.agent`, Open of an app or script becomes Reveal, Copy copies, `run` and `paste` have no markup form at all. Images are fetched by Wicket only. Choices, when they come, send text and are never consent.
- **Limits.** 64 KiB of markup per screen (an extension's 1 MiB line holds it), 500 focusable blocks, nesting depth 3 (card in column in document), 200 chart points, 20 images, three columns. Over a limit, the rest renders as text with a logged count, and the agent reply never errors on size.
- **Authority** is stamped on the screen at decode as today and carried by the frame; a page a card opens inherits it. `wicket check` lints an extension's markup strictly (unknown tags and attributes are errors there, since an extension author can be told), while the renderer is tolerant for everyone. Strictness moves to the checker, which is where an extension's contract is enforced anyway.

## 5. Generation

**The agent learns it from `agent.md`**, in a "Your reply" section of about sixty lines: the rule, the catalog as one table (tag, attributes, use when), and three short examples (an answer, a file list with a lead sentence, a stats strip with a chart). The full reference with every attribute lives in `docs/markup.md` in the authoring kit, which extension-building runs already read on demand. Rule text, draft:

> Reply in Markdown. Where the user could open, copy or compare something, use Wicket's components, each on its own line: `<file path>` and `<url href>` for things to open, `<answer value>` for one fact, `<stat>` for numbers worth seeing at a glance, `<chart>` for data over time or categories, `<columns>` to compare side by side. Repeat a tag to make a group. Don't describe the UI, don't put paths in prose when they can be rows, and don't invent tags or attributes: unknown ones show as text.

**Reliability.** Claude and Codex both write HTML in markdown fluently; the failure modes are attribute typos, forgotten closing tags and real HTML from habit (`<b>`, `<br>`, `<img>`). The first two are tolerated. For the third, `<img src>` is accepted as an alias of `image`, `<br>` and `<b>` show as text (and the evaluation counts them), and the prompt says tables are markdown. Evaluation keeps the v2 prompt set and scoring (task success per keystroke), adding a parse score: unknown tags per reply, with the target under one in twenty.

**Streaming.** The document parser is incremental by re-parsing: the whole text so far is parsed on each delta (under a millisecond for 20 KB, measured before shipping), and a block renders once it is closed, so a chart appears when its `</chart>` arrives and a stat strip grows tile by tile. Prose streams as it does now. `ai.streamAnswers` stays off by default, so v1 renders at the end for most users and streaming is a switch that works.

**Structured output: none** (section 1). `ReplySchema.project`, `AgentOutput`, `docs/agent-reply.schema.json` and their tests go, before an adapter ever calls them.

## 6. Parsing and rendering in Swift

**Parser (Core, `Markup.swift`, about four hundred lines, no dependency).** A line scanner first: it tracks fenced code, and a line starting with `<name` where `name` is in the catalog opens a component (attributes parsed by a small quote-aware state machine); it collects until the matching close at the same depth, or the parent's close, or the end. Everything else accumulates into markdown segments, which `MarkdownBlock.parse` handles as today. Containers recurse; data components (chart) read only their child tags. The output is `[Node]`, `Node` being `.markdown(MarkdownBlock)` or `.component(Component)`, and `Component` an enum with typed payloads (`.stat(Stat)`, `.chart(Chart)`, `.columns([[Node]])`, `.card(Card)`, `.row(Item)`, `.answer(Item)`). Rows become `Item` with `Subject`, so iteration 1's derivation, ids and actions are reused as they are. The adjacency rule is a grouping pass over `[Node]`.

swift-markdown would give `HTMLBlock` and `InlineHTML` nodes, but it is a dependency for what a line scanner does, and Foundation's parser is already in use. Apple's `AttributedString` cannot represent custom blocks, which is why the scanner runs first and the markdown parser only sees prose.

**View (app, `DocumentView`).** Replaces `DetailView`'s markdown half: a `VStack` of nodes, `MarkdownView` for prose runs, one SwiftUI view per component, `HStack` for columns, Swift Charts for charts, the v2 image loader for images. Measurement as `DetailView` does it: height by `onGeometryChange` at the card's width, the card grows to the cap and scrolls beyond it. `metadata` from an extension's JSON keeps its sidebar rule; `<fact>` groups in the document are always the full-width table, so no new oscillation. Nodes are `Hashable`, so streaming re-parses diff cheaply.

**Performance.** Parse on the main actor when the final text arrives (target under 2 ms for 20 KB, with a test timing a 64 KiB fixture); Finder icons and images off it as now; charts render in a few milliseconds. Nothing runs at summon, so hotkey-to-visible is untouched. A benchmark fixture with three columns, a chart and forty rows guards reply-to-visible under 50 ms.

## 7. Extensions

**No new field.** `detail.markdown` and `list.summary` accept the markup: the markdown they take today is a subset, so every existing extension is unchanged and a new one can put rows, stats and a chart on a page. The JSON `list` stays what it is, rows for searching and picking (`live` and `root` modes need ids, `run` actions, relevance and typing-to-filter, none of which a document has), and `answer` stays a JSON row for root ranking. The relation in one line for the docs: **a list is rows to search; a page is a document to read, which may contain rows.**

The two forms share names on purpose: `title`, `subtitle`, `accessory`, `icon` are the same attributes as the item fields; the tag name is the subject and `path` or `href` its value. An extension row that needs `run` for drill-down stays JSON in v1; a `run` attribute on markup rows under extension authority is v2, and `ActionPolicy` drops it under agent authority exactly as it refuses `run` today.

What this supersedes on the extension wire: `facts` (0.0.6, only the gallery uses it) becomes `<stat>` or `<fact>` in the `summary`, which stays the one place a live list gets prose above its rows and allows only non-focusable components. The `gallery` sample becomes the markup showcase: one page per component group, which also serves as `wicket check`'s lint fixture.

## 8. Keep and delete

**Keep:** `Item`, `Subject` and all derivation; `Authority`, `ActionPolicy`, the dispatcher and link policy; screen actions (Follow Up on ⌘↩, Copy Answer, Retry, Review and Enable), Read Summary for lists; `MarkdownBlock`; `DetailView`'s measurement and metadata sidebar; `ListTop` and `SummaryLayout` for extension lists; the image rules from the v2 spec; the evaluation method. Copy Answer gains a plain-text rendering of a document: stats as "label: value", rows as lines, chart points as "x y", tags dropped.

**Delete:** `ReplySchema`, `AgentOutput`, `docs/agent-reply.schema.json` and the golden test; the agent profile's field omissions (`id`, `icon` now allowed; `relevance` never was meaningful outside root); the agent screen table in `ActionPolicy` (an agent sends documents only); the "answer, list or detail" rule text and the `{reply}` wrapper plan; `facts` on the wire; the CONCEPT lines on harness structured output and on agent rows without icons, replaced by this decision and its reason.

## 9. Five replies

**"weather in Hamburg this week"**

```
Cool and wet until Thursday, **clearing for the weekend**.

<stat value="9°" label="Now" detail="Light rain, feels like 6°" icon="cloud.rain"/>
<stat value="11° / 5°" label="Today" icon="cloud.sun"/>
<stat value="72 %" label="Rain chance" tone="warning"/>

<chart kind="line" title="Highs and lows" unit="°C">
<point x="Mon" y="11" series="High"/><point x="Mon" y="5" series="Low"/>
<point x="Tue" y="10" series="High"/><point x="Tue" y="4" series="Low"/>
… one pair per day …
<point x="Sun" y="15" series="High"/><point x="Sun" y="9" series="Low"/>
</chart>

<url href="https://www.dwd.de/hamburg" title="Full forecast"/>
```

Renders as one bold line, a strip of three tiles (the third value orange), a 120 pt line chart with two series and a legend, then one row, selected on arrival since it is in view. Return opens the forecast; Copy Answer gives the sentence, three "label: value" lines and fourteen "day value" lines.

**"compare iPhone 17 vs Pixel 11"**

```
Both are excellent; the iPhone wins on video and battery, the Pixel on price and camera software.

<columns>
<column>
<card title="iPhone 17" subtitle="from €949" href="https://www.apple.com/iphone-17/">
<image src="https://www.apple.com/…/iphone17.png" alt="iPhone 17"/>
<stat value="6.3″" label="Display"/>
<stat value="24 h" label="Battery"/>
</card>
</column>
<column>
<card title="Pixel 11" subtitle="from €799" href="https://store.google.com/pixel-11">
<image src="https://store.google.com/…/pixel11.png" alt="Pixel 11"/>
<stat value="6.4″" label="Display"/>
<stat value="22 h" label="Battery"/>
</card>
</column>
</columns>

| | iPhone 17 | Pixel 11 |
|---|---|---|
| Chip | A19 | Tensor G6 |
| Camera | 48 MP, best video | 50 MP, best stills |
| Updates | 6 years | 7 years |

<callout tone="info">Prices are launch prices in Germany; check current offers before buying.</callout>
```

Two cards side by side, each with a product image (fetched by Wicket, host labelled under it), two tiles in a strip and a title row; each card is one focusable block, Return opens its store page. Below, a markdown table and a tinted callout. ← and → move between the cards, ↓ leaves them for nothing else, so the page scrolls.

**"what changed in my repo today"**

```
Three commits today in **wicket**, all on main, nothing uncommitted.

<stat value="3" label="Commits"/>
<stat value="12" label="Files"/>
<stat value="+418 −96" label="Lines" tone="positive"/>

<list title="Commits">
<item title="Agent UI step 2: composed lists, subject rows" subtitle="3ec1bc6 · 14:02" copy="3ec1bc6"/>
<item title="Release 0.0.9" subtitle="45735ee · 16:40" copy="45735ee"/>
</list>

<list title="Files changed">
<file path="~/Private/wicket/Sources/WicketApp/ListTop.swift" accessory="+140 −2"/>
<file path="~/Private/wicket/docs/extensions.md" accessory="+38 −11"/>
</list>
```

A sentence, three tiles, then two titled sections of rows. The commit rows show a document icon and copy their hash on Return; the file rows show Finder icons, folders and Open, Reveal in Finder and Copy Path. Arrows skip the section titles. This is iteration 1's composed list, written in nine lines without a schema.

**"how old is Keanu Reeves"**

```
<answer value="61" detail="Born 2 September 1964 in Beirut"/>

He turns 62 next September.

<url href="https://en.wikipedia.org/wiki/Keanu_Reeves"/>
```

The hero row on top (Return copies "61"), one line of prose, one link row deriving "en.wikipedia.org" and its path. ↓ moves from the answer to the row.

**"my calendar tomorrow"**

```
Four events, a free afternoon after 15:00.

<event time="09:00" end="09:30" title="Standup" detail="Zoom" href="https://zoom.us/j/123"/>
<event time="10:00" end="11:00" title="Design review" detail="Room Elbe"/>
<event time="12:30" end="13:30" title="Lunch with Mara" detail="Café Paris"/>
<event time="14:00" end="15:00" title="1:1 with Sam" detail="Zoom" href="https://zoom.us/j/456"/>

<callout tone="warning">Design review and a dentist reminder overlap at 10:00.</callout>
```

A timeline with a time column, a line with four dots, titles and places. The two events with a link are rows (Return joins the call); the others are not focusable. The callout is orange with a triangle.

## 10. The v1 slice, risks and open questions

**v1, in order:** (1) `Markup` parser and nodes in Core with the fixture folder and the 64 KiB timing test; (2) `DocumentView` with markdown, stat, fact, answer, rows, list, callout, columns, card; (3) selection in a document on `ItemList`, with an on-screen check when the Mac is free; (4) chart and image (the image loader from the v2 spec, local thumbnails first); (5) timeline, progress; (6) adapters: the final text becomes a document, no schema, Copy Answer's text rendering; (7) `agent.md` section and `docs/markup.md`, gallery reworked, `wicket check` lint, `facts` removed; (8) delete the structured-output code; (9) evaluation on both CLIs before the owner sees it. Badge, choices, grid, app, map and `run` on markup rows are v2.

**Risks.** Selection in a scrolling document is the hardest piece; it is built on `ItemList` and spiked on screen before the components pile on. Models writing real HTML from habit; measured by the parse score, mitigated by the `img` alias and the prompt. A richer surface widens what a prompt injection can show, but not what it can do: every action still goes through the policy, and images reveal only what the online-content setting already allows. The card cap (eight rows, 384 pt) may feel tight under a chart and a list; measured before it is changed. Two keyboard surfaces (lists filter, documents follow up) must be one clear sentence in the docs or they will feel like a mode.

**Open questions for the owner, each with a recommendation.**

1. **Drop harness structured output entirely.** Recommend yes: the format the model knows, no double output, no cache cost, streaming for free, and the parser is the same if a `{markup}` schema is ever needed.
2. **Layout freedom: columns and cards.** Recommend yes, bounded as above (three columns, depth three, no sizes or colours). They are what makes a comparison look like one, and Wicket still draws them.
3. **Typing on an agent document starts a Follow Up.** Recommend yes; filtering a document is meaningless and the pill is already the Follow Up composer.
4. **Card height for documents.** Recommend keeping one cap in v1 and measuring real replies; a taller document cap can be a setting later.
5. **`facts` leaves the wire and `summary` accepts markup.** Recommend yes: it shipped days ago, only the gallery uses it, and stats in the summary cover it.
6. **Icons on agent rows.** Recommend allowing them, since an unknown symbol now falls back instead of failing.
7. **No tag prefix.** Recommend none, with `img` as the one HTML alias; a prefix buys collision safety the whitelist already gives and costs tokens on every tag.
