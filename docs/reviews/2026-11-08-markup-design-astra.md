# Wicket: composed native answers

**Recommendation: let agents compose a document, using Markdown and a small catalog of native component tags. Deliver that document through harness structured output.** The agent chooses hierarchy, juxtaposition and emphasis; Wicket owns drawing, adaptation, selection and actions.

Iteration 1's problem is its composition ceiling. A summary, four facts and one collection cannot express a forecast, a useful comparison or a visual explanation. Replacing JSON punctuation alone changes nothing. The consequential change is allowing multiple components, in a chosen order, with limited horizontal composition.

The product should feel like an answer designed for this question. It should not feel like a miniature website, nor require the user to choose between answer, list and detail modes.

## 1. Model and syntax

Call the format **Wicket Markup**. Ordinary Markdown remains ordinary Markdown. Components use lowercase, prefixed tags:

```text
The migration is mostly complete.

<w-columns>
<w-metric label="Converted" value="18" />
<w-progress label="Coverage" value="18" total="24" />
</w-columns>

## Still needs attention

<w-file path="~/Project/README.md" />
```

Tags occupy their own lines, including closing tags. Attributes are double-quoted strings, converted into typed values by the catalog. Support XML's five character escapes; no expressions, variables, imports, interpolation, event handlers or arbitrary HTML. Fenced and indented code are opaque. Components cannot start inside a paragraph, Markdown list or blockquote. Markdown constructs cannot cross component boundaries. This is a deliberately small language, not an HTML parser.

The document is an implicit vertical stack. `w-stack` groups children when a column needs several blocks. `w-columns` puts exactly two children beside each other; `ratio="equal|leading|trailing"` requests 1:1, 2:1 or 1:2. `w-grid columns="2|3"` repeats compact tiles in row-major order. `w-card` groups a subject on a quiet inset surface. Headings provide sections; a separate section component adds nothing yet.

At 640 pt, after 20 pt side insets and a 12 pt gap, equal columns have 294 pt each. They collapse to a stack when their content's minimum readable widths do not fit, especially at larger text settings. No absolute widths, positions, spans, nested columns or nested cards. Grids contain compact cards, images or metrics, never long prose or lists. Three columns are for brief values, not miniature articles.

This grants real editorial freedom: put a verdict before evidence, contrast two products, place a portrait beside a fact, alternate explanation and charts, or collect related files after each finding. Typography, gaps, corners and chart colors remain one Wicket design system. Only the outer palette uses glass; inner cards use restrained surfaces.

### Why markup, honestly

| Approach | Strength | Cost | Decision |
|---|---|---|---|
| Markdown with tags | Natural prose interleaving; readable examples; compact authoring | Syntax and component validity are not schema-enforced | Preferred document language |
| Rich JSON tree | Stronger shape constraints; explicit data; equally expressive layouts | Verbose prose wrappers; recursive schemas; more tokens | Credible fallback if generation tests favor it |
| Structured envelope containing markup | Keeps established harness delivery and failure handling | JSON guarantees the string, not its contents; escaping overhead | Preferred transport |

[Markdoc](https://markdoc.dev/docs/syntax) is the closest conceptual reference: Markdown plus declared tags and attributes. Its [validation model](https://markdoc.dev/docs/validation) also checks child structure. Borrow those boundaries, without its variables or functions. [MDX](https://mdxjs.com/docs/what-is-mdx/) includes JSX, JavaScript expressions and imports; borrow its authoring familiarity, never its execution model. An [A2UI catalog](https://a2ui.org/concepts/catalogs/) usefully makes supported components explicit. Wicket needs that principle, not a general surface negotiation and state-binding protocol. Vercel's [streamUI](https://ai-sdk.dev/docs/reference/ai-sdk-rsc/stream-ui) illustrates selecting host-provided components; its [RSC package is experimental](https://ai-sdk.dev/docs/reference/ai-sdk-rsc), not an architecture to transplant into Swift.

Tinycast's local extension documentation describes native rendering and a flattened selection order, useful precedents. Its AI documentation also identifies SwiftUI's limitation on selecting text across separate views. Keep Copy Answer and acknowledge that limitation; do not promise browser-like cross-component selection. No reference code is needed.

## 2. Catalog, by delivery tier

Attributes below are exhaustive unless marked optional with `?`. All tags allow an optional `id` for stable identity, never styling or authority. Children are content, not attributes.

### Tier A: the first useful composition release

| Component | Syntax / attributes | Native presentation |
|---|---|---|
| Text | Markdown headings, paragraphs, emphasis, lists, quotes, code, links | Existing native Markdown blocks, respecting page text size; paragraphs wrap |
| Grouping | `w-stack`; `w-columns ratio?`; `w-grid columns`; `w-card title?` | VStack, adaptive two-column layout, adaptive grid, quiet rounded group |
| Metric | `w-metric label value unit? note? tone?` | Prominent value, small label, optional explanatory line; no automatic trend inference |
| Badge | `w-badge text tone?` | Compact status capsule; wraps in flow, not a clickable chip |
| Progress | `w-progress label value total` | Native progress bar and visible numeric fraction; finite values, total positive |
| Image | `w-image src alt aspect? caption?` | ImageIO/Quick Look image, aspect `square|portrait|wide|original`; fitted, not cropped; reserved height |
| Gallery | `w-gallery`, children `w-image` only | Adaptive two-column thumbnails; maximum eight; host viewer on activation |
| Chart | `w-chart kind title x unit? summary` | Swift Charts bar, line or sparkline; one fenced JSON data body; details below |
| File | `w-file path title? subtitle? accessory?` | Existing subject row, Finder icon, derived Open/Reveal/Copy Path |
| Link | `w-link href title? subtitle? accessory?` | Existing URL subject row; host icon and destination visible in action panel |
| Collection | `w-list title?`, children file/link/row | Existing row treatment, one global selection order, no nested scrolling |
| Plain row | `w-row title subtitle? accessory?` | Selectable text row; Return copies its text |
| Facts | `w-facts`, children `w-fact label value` | Aligned label/value pairs; two columns if readable, stacked otherwise |
| Table | Markdown pipe table; `w-table caption?` optionally wraps it | Same native table node either way; header and aligned cells, no editable spreadsheet |

Charts use `kind="bar|line|sparkline"`, `x="category|date|number"`, a shared y-unit and JSON rows shaped as `{"x":...,"y":...,"series":"optional label"}`. A date is ISO 8601; numeric coordinates must be finite. Bar charts include zero; lines mark gaps rather than inventing values. Wicket chooses scales, ticks and a fixed accessible palette. `summary` is mandatory accessible prose; the host exposes the data table through ⌘K. Sparklines retain visible start/end values and the summary, so they do not become decorative claims. No arbitrary chart grammar or dual axes.

Tables allow six columns. If columns cannot remain readable, each row becomes a labelled vertical record. Limit cell content to inline Markdown. A weather card is already a card containing metrics, a line chart and facts: no weather-specific component or weather API in Core.

### Tier B: after composition works

| Component | Syntax / attributes | Native presentation |
|---|---|---|
| Timeline | `w-timeline timezone`, children `w-event start end? title subtitle? href?` | Localized time rail, text on the right; all-day entries use dates; links become selectable events |
| App | `w-app bundle-id title?` | Installed app name and icon; authority determines Reveal versus Launch |
| Button | `w-button label`, exactly one of `copy`, `href`, `action-ref` | Native button; copy/open via dispatcher, or reference to extension binding |
| Choices | `w-choices`, children `w-choice text description?` | Native reply buttons/rows; activation sends visible text as Follow Up |

`action-ref` resolves only against an extension's envelope `bindings` map of names to existing `Item.Action` values. It never names a global command. Agent envelopes have no bindings. This is a later extension affordance, not a prerequisite for native entity actions. Choices never preselect or imply consent; approvals remain host chrome.

### Tier C: wait for demonstrated demand

`w-map latitude longitude label` would render one noninteractive MapKit snapshot with one pin and host-derived Open in Maps. Network access follows Show online content. Defer zoom, routes and multiple pins. `w-contact identifier` would require a host-issued contact reference and existing Contacts permission; never search Contacts from model-supplied names or prompt for permission while drawing. Until then, names and explicit mail links suffice.

## 3. Keyboard and selection

There is **one document scroll and one ordered set of action targets**, not a focus system inside each card.

Selectable targets are entity/plain rows, image previews, inline links, and later buttons, choices and linked events. Headings, cards, metrics, chart points, table cells and progress bars are not extra Tab stops. A chart's table is available as a screen action; VoiceOver still reads chart data and every static block.

On a mixed document, start with no target selected. Return executes the screen's primary action, normally Copy Answer. Down selects the first target; Up/Down traverse targets in source order, skipping decoration. Tab/Shift-Tab use that same order. Columns read the first child completely, then the second; grids are row-major. Left/Right do not invent a spatial navigation mode. Pure list screens retain first-row selection and current arrow behavior.

Page Up/Down and trackpad scrolling move through prose. With no targets, Up/Down scroll too. Scrolling a selected target completely out of view clears its action selection, preventing invisible Return activation. Text selection keeps native copy behavior and takes precedence over document shortcuts while active.

Return activates the selected target; ⌘K shows its resolved actions followed by screen actions. With no target it shows screen actions only. ⌘↩ remains Follow Up. The footer always names what Return will do. Space uses the existing preview policy when available; Quick Look remains gated on its pending non-activating-panel spike.

The brief requests Escape-up-a-layer, but the owner's newer decision in CONCEPT explicitly changed this: **Escape dismisses the palette; ⌘[ goes back.** Escape first closes an action panel or preview, or handles the existing listening exception. Preserve that decision. Containers never add navigation layers.

## 4. Control and safety

Validation precedes rendering and all resource loads. The catalog specifies attributes, allowed child kinds and limits. Reject duplicate attributes, invalid enum values, malformed data and unknown attributes. Unknown tags or malformed components become escaped literal text for agent replies, with one quiet “Some content shown as text” notice. Never recursively activate known tags inside an unknown or rejected subtree. Extension checking reports these errors strictly.

`tone="neutral|positive|negative|warning"` is the only color-like input, allowed on metrics and badges. It denotes the author's status claim, not verification by Wicket. No font, size, CSS, symbol names, alignment hacks, hidden content or accessibility overrides. Host status, permission prompts and enable controls are outside the document.

Keep `Authority`, `ScreenContext` and `ActionPolicy`. Every nested action inherits the producer's authority, including derived subjects, image viewers and pushed data tables. Validate on decode and again on activation. Agent apps/scripts reveal instead of execute; agent content cannot run commands or paste. Extension run actions retain revision checks. Markdown links retain today's restrictive link policy even inside extension documents.

Proposed limits: 128 KiB decoded markup, 256 component nodes, depth six, 100 document rows, six charts, 200 points per chart, three series, 50 table rows, eight images, eight choices. Legacy standalone lists keep their existing 500-row limit. Limits apply before allocation where possible. Show explicit truncation for display overflow; malformed/truncated transport never becomes a clickable partial action.

Online content remains on by default, with the existing planned off switch and per-screen Load Image. Use bounded HTTPS fetching, no cookies/referrer, redirect validation, blocked loopback/private/link-local destinations, ImageIO decoding off-main, byte and decoded-pixel limits. No SVG, executable formats or image fetches merely to derive link icons. Reserve image space; cancellation follows the frame lifetime. Logs contain counts and timings only.

## 5. Generation and streaming

Use this common harness envelope:

```json
{"markup":"<w-metric label=\"Answer\" value=\"4\" />"}
```

Its schema is an object with one required string and `additionalProperties:false`. Pass it every turn, including Follow Up, as the local spike requires. Preserve Claude's StructuredOutput handling and Codex's final-answer separation. An outer schema cannot validate the markup string. Wicket's parser is the semantic gate; this is the principal tradeoff against a JSON tree.

The bundled `agent.md` gets a compact grammar, supported tags, three worked examples and five instructions: answer first; use components when they improve comprehension; cite factual sources; never invent data to fill a component; prefer ordinary Markdown when uncertain. Generate the catalog fragment from shipped definitions, so unsupported future tags are never advertised. Keep the user's editable instructions separate from the host's current capability description.

Run the same prompts three times on each configured Claude/Codex model, with follow-ups, escaped paths, non-Latin text and injected tags in retrieved content. Measure semantic validity, action correctness, readable layout, latency and tokens. Do not assume familiarity with HTML makes either model reliable.

Keep answers nonstreaming by default, consistent with the owner's choice. Later, if streaming is enabled, incrementally decode the envelope's JSON string and publish only closed, validated top-level blocks. A closed child inside unfinished columns is not committed. Preserve node identities and scroll position; actions remain unavailable until final validation and the existing process-completion gate. Never refetch an image on each delta. Avoid speculative repair turns, especially after an acting run: no task replay to fix presentation.

## 6. Swift architecture and measurement

Start with a small, linear scanner for the restricted tag grammar, tracking fences, quotes and a bounded component stack. Feed intervening Markdown spans to existing `MarkdownBlock.parse`, which already uses Foundation's presentation intents. Do not use regex substitution or ask Foundation to recover custom HTML blocks.

[swift-markdown](https://github.com/swiftlang/swift-markdown) offers a cmark-gfm-backed syntax tree. It becomes justified if the restricted scanner cannot correctly preserve required Markdown boundaries; it would replace the Markdown parsing path rather than introduce a second renderer. It does not eliminate the custom component grammar. Prove the simpler scanner against fixtures first.

In Core, one immutable `DocumentNode` tree holds Markdown, layout, data and existing `Item` leaves. One traversal produces action order and Copy Answer text, including chart rows, image alt text and destinations. Host extracts provider output. App resolves subjects/images asynchronously and draws nodes with SwiftUI and Swift Charts. `PaletteController` continues to own the window frame.

Measure natural height at the actual width, clamp to the existing available screen-height budget, then use one vertical scroll view. Long tables and code cannot introduce horizontal layout overflow. Cache parsed documents by response revision, not on SwiftUI body evaluation. No loading, parsing or chart construction on summon.

Acceptance budgets, to measure rather than claim: typical 20 KiB parse/validate under 5 ms off-main; representative 256-node document under 16 ms main-thread layout; unchanged hotkey latency within benchmark noise. Record peak/settled memory for repeated image/chart navigation and confirm decoded resources release on dismissal. Test large text, dark mode, VoiceOver, broken tags, code containing tags, malformed nesting and adversarial resource sizes. Screen-bound tests wait until the owner frees the Mac.

## 7. Extensions, migration and deletion

Add `detail.markup`, mutually exclusive with `detail.markdown`. Existing list/answer/detail wire results remain accepted. They are useful compact transports, particularly root results; they must not become competing rich UI catalogs.

Normalize legacy detail text/metadata, answers, and composed-list slots into shared document/leaf types. A pure list retains its efficient selection and sizing path; a rich document embeds the same `Item` renderer. Legacy metadata's sidebar rule can remain a boundary adapter for existing replies. New content expresses placement with columns/facts.

One catalog governs markup validation, native nodes, documentation and extension checks. No second JSON component tree in v1. Extensions can generate markup with ordinary escaping; executable behavior stays in the existing action model. Keep protocol 1 for the additive field and document the required Wicket version; older hosts reject it as they do other unknown fields.

Keep subjects, canonical identity, missing-target behavior, authority checks, action groups, Copy Answer and screen-level Follow Up. Keep list/answer wire support. Delete the agent's three-screen chooser, recursive agent screen-schema projection, fixed summary/facts/collection restriction and duplicate agent fallback paths. Remove Read Summary from new documents because their prose already scrolls; retain its legacy-list behavior until those callers migrate. Replace, rather than extend, gallery examples and stale design rules. The lead should record the composition decision and audit superseded code before another feature tier.

## 8. Five concrete replies

These are UI fixtures, not fetched forecasts, product specifications, repository changes or calendar records. Production replies must use actual evidence. Examples show the markup field before JSON escaping.

**Weather in Hamburg this week**

````text
# Hamburg · 2–8 November
Illustrative forecast. A cooler weekend follows a mild start.

<w-columns>
<w-metric label="Today's high" value="8" unit="°C" />
<w-metric label="Wet days" value="4" unit="of 7" />
</w-columns>

<w-chart kind="line" title="Daily high" x="category" unit="°C" summary="Highs fall from 12 to 8 degrees across the week.">
```json
[{"x":"Mon","y":12},{"x":"Tue","y":13},{"x":"Wed","y":11},{"x":"Thu","y":10},{"x":"Fri","y":9},{"x":"Sat","y":8},{"x":"Sun","y":8}]
```
</w-chart>

Bring a raincoat for the weekend.
````

Two prominent values sit above a full-width, roughly 150 pt chart; prose stays unboxed. Approximately 320 pt tall at medium text. No bespoke weather widget. Actual output adds a dated forecast-source link.

**Compare iPhone 17 vs Pixel 11**

```text
# iPhone 17 or Pixel 11?
Illustrative comparison layout; specifications are not verified.

<w-columns>
<w-card title="iPhone 17">
### Best fit
Someone already invested in Apple's devices.
</w-card>
<w-card title="Pixel 11">
### Best fit
Someone who prefers Android.
</w-card>
</w-columns>

| Check before choosing | iPhone 17 | Pixel 11 |
|---|---|---|
| Local price | Verify | Verify |
| Battery test | Same test method | Same test method |
| Camera | Compare original samples | Compare original samples |

Your current phone and priorities matter more than a spec winner.
```

Two equal cards establish contrast; the full-width comparison table aligns evidence beneath them. Large text stacks the cards. In real use, replace placeholders with sourced findings or explicitly retain uncertainty; never invent specifications to complete the design.

**What changed in my repo today?**

```text
# Today's changes
Fixture: two commits, plus one uncommitted file.

<w-columns>
<w-metric label="Commits" value="2" />
<w-metric label="Files touched" value="3" />
</w-columns>

## Committed
Added composed documents and kept existing subject actions.

<w-list>
<w-file path="/Users/pietz/Private/wicket/Sources/WicketCore/Content.swift" accessory="Modified" />
<w-file path="/Users/pietz/Private/wicket/docs/extensions.md" accessory="Modified" />
</w-list>

## Still uncommitted
<w-file path="/Users/pietz/Private/wicket/ROADMAP.md" />
```

Metrics, explanation and two separate file groups coexist. Three ordinary file targets share one arrow order. The first two rows are not trapped in their own list viewport. No model-authored Execute or Commit button appears.

**How old is Keanu Reeves?**

```text
<w-metric label="Keanu Reeves" value="62" unit="years old" note="As of 8 November 2026" />

Born 2 September 1964.

[Biography](https://www.biography.com/actors/keanu-reeves)
```

A roughly 160 pt answer with one large number, date and source. No obligatory portrait, card or grid. The age follows from the published [birth date](https://www.biography.com/actors/keanu-reeves). Return initially copies the answer; Down selects the source. Richness includes knowing when one number is enough.

**My calendar tomorrow**

```text
# Monday, 9 November
Fixture: two meetings, with a long break after 09:30.

<w-timeline timezone="Europe/Berlin">
<w-event start="2026-11-09T09:00:00+01:00" end="2026-11-09T09:30:00+01:00" title="Team check-in" subtitle="Video call" />
<w-event start="2026-11-09T14:00:00+01:00" end="2026-11-09T15:00:00+01:00" title="Design review" subtitle="Office · Room 2" />
</w-timeline>

You have 4½ hours between meetings.
```

Tier B's timeline shows a narrow time rail and two readable event blocks, about 240 pt total. No links means no artificial event actions. A real HTTPS meeting URL can add a host-mediated Join action. Tier A expresses the same information as a time/title table; a dedicated calendar subject is unnecessary.

## 9. Slice, risks and owner calls

Build the scanner, shared tree and keyboard flow first; then columns/cards, metrics, files/links and tables; then images and one-series bar/line charts. Update the gallery to demonstrate these five questions. Gallery, sparkline polish and remaining Tier A extras follow only after the core compositions pass. Timeline, buttons and choices remain Tier B. Do not present another text-only increment as the expressive redesign.

Main risks are malformed nested markup, selection skipping over explanation, card proliferation and attractive misinformation. Address them with literal fallback, explicit reading/selection tests, restrained examples, and visible dates/sources. Compare a small JSON-tree prototype against markup on identical prompts before committing the transport decision. If markup's semantic validity falls below 95% or requires repeated repair, recommend JSON trees with Markdown leaves instead. No invalid action may activate, regardless of the validity rate.

Owner decisions:

1. **Allow limited layout composition? Recommend yes.** This explicitly supersedes the earlier prohibition on columns and block trees; otherwise the gallery's ceiling remains.
2. **Choose markup as the authored language? Recommend yes, subject to the generation comparison.** Keep structured delivery, with honest acknowledgment that its inner language needs validation.
3. **Accept one scrolling document with explicit target navigation? Recommend yes.** Keep pure lists fast and familiar; do not make every static component focusable.
4. **Require images and charts in the first owner review? Recommend yes.** They prove the visual gain. Delay custom widgets, map/contact access and executable interactions.

This memo proposes decisions; it does not change the repository or claim a new owner approval.
