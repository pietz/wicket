# How ChatGPT's Intelligent UI works (research, 2026-11-12)

Scope: the format GPT-6 writes, the component catalog, the rules for choosing between components and prose, the design craft, interactivity and state, outside opinions, and lessons for a markdown-plus-tags renderer. Every claim has a URL. The credibility labels are: **[official]** (OpenAI pages or staff), **[leak]** (prompt text that leaked from OpenAI), **[multi]** (reproduced by several independent captures), **[single]** (one source), **[inference]** (my own reading of the evidence).

## 0. Status of the system prompt leaks (task 1)

- **No GPT-6 ChatGPT Chat system prompt has leaked, and neither has any DIL or Intelligent UI instruction text.** I cloned all three leak repos on 2026-11-12 and grepped them for `AppBlock`, `DIL.`, `issueNewTurn`, `AsyncImage`, `model_dil`, and "Intelligent UI":
  - [asgeirtj/system_prompts_leaks](https://github.com/asgeirtj/system_prompts_leaks): last commit 2026-11-10. Its newest ChatGPT prompt is GPT-5.6 Sol, dated 2026-08-22. Its GPT-6 files cover Codex only.
  - [elder-plinius/CL4R1T4S](https://github.com/elder-plinius/CL4R1T4S): last commit 2026-11-09. Its OpenAI material covers Codex Desktop only.
  - [jujumilk3/leaked-system-prompts](https://github.com/jujumilk3/leaked-system-prompts): last commit 2026-09-23.
  - GitHub code search turned up only reverse-engineering projects.
- The best packet-capture analysis says outright: "系统提示词没抓到" (the system prompt was not captured). It explains that the server injects the instructions and that the conversation endpoints never return them ([Disdjj ANALYSIS.md §12](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md)). **[single, consistent with everything else]**
- **Two adjacent leaks are new and useful:**
  1. **OpenAI's own "Visualize" skill**: about 33 KB of design rules for HTML visualizations written by the model ([SKILL.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/OpenAI/Codex/plugins/visualize/skills/visualize/SKILL.md), updated 2026-10-29). **[leak]** This is the open-ended lane. It is a cousin of the `AppBlock` escape hatch in Intelligent UI: both render on `codex-inline-visualization-*.oaiusercontent.com` and use the same `--viz-*` variables ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works), [Buqisir §9](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md)). It is the most detailed design guidance from OpenAI that I found.
  2. **A Work-mode fallback reference** that names the `charts_widget_v2` and `app_block` genui surfaces and gives the exact JSON spec for charts ([native-inline-visualizations.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/OpenAI/Codex/plugins/data-analytics/skills/visualize-data/references/native-inline-visualizations.md)). **[leak]** Captured Intelligent UI responses carry the same `charts_widget_v2` type in `genui_components` metadata ([Disdjj §5.3](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md)). That makes it the strongest evidence for what the `Chart` component's `content` prop looks like. **[multi]**
- **Older prompts show the lineage.** GPT-5.5 Thinking used inline content references such as `【finance|turnXfinanceY】` and the rule "Generally, you should only use one rich UI element per response, as they are visually prominent. Never place rich UI elements within a table, list, or other markdown element." ([gpt-5.5-thinking.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/OpenAI/gpt-5.5-thinking.md)) **[leak]** GPT-5.6 Sol had a `genui.search` / `genui.run` widget tool with the rule "Treat all widgets of any type as purely supplemental visualizations - your textual response must stand on its own" ([gpt-5.6-sol.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/OpenAI/gpt-5.6-sol.md)). **[leak]** GPT-6 still calls `genui.search` before it writes a calculator, presumably to fetch component docs or templates ([Buqisir §4](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md)). **[single]**

## 1. What it is (official)

- **Launch.** Intelligent UI launched on 2026-10-07 with GPT-6 in the Chat tab. Paid plans use GPT-6 Sol and Free and Go use Luna. GPT-6 Astra (the Pro reasoning option) does not support it, and neither do Work, Voice, or Codex ([announcement](https://openai.com/index/gpt-6-for-everyone/), [archived](https://web.archive.org/web/20261027170015/https://openai.com/index/gpt-6-for-everyone/); [help article](https://web.archive.org/web/20261105160628/https://help.openai.com/en/articles/20001598-intelligent-ui-in-chatgpt)). **[official]**
- **How OpenAI describes the mechanism** (verbatim): "We built a library of native, streamable components, along with a compiler that processes the interface as the model generates it. The library gives each response a familiar design foundation while leaving the model room to decide how the pieces fit together. The compiler allows the interface to appear progressively as the model generates it." ([announcement](https://openai.com/index/gpt-6-for-everyone/)) **[official]**
- **Training and evals** (verbatim): "We expanded our training methods to help the model make thoughtful decisions about content, layout, visuals, and interaction. This included evaluating the interfaces it creates for clarity, usefulness, and completeness. GPT-6 learned to use the component library and make good design decisions, including how to organize information clearly, when to use interactivity, and when a simple text response is enough." The same post concedes: "There's still work ahead to improve the model's design judgment." ([announcement](https://openai.com/index/gpt-6-for-everyone/)) **[official]**
  - The [GPT-6 system card](https://cdn.openai.com/pdf/gpt-6-october.pdf) has no UI section; I grepped its extracted text. yage.ai reached the same conclusion ([yage.ai](https://yage.ai/share/ai-design-direction-written-down-en-20261011.html)). **[official absence]**
- **Staff.** Michelle Pokrass (OpenAI): "intelligent ui is a bet on model intelligence ... we had to craft the right tools for gpt-6 to be able to produce interfaces that are token efficient, stream in instantly, match our design language, and are expressive enough for anything you might talk to chatgpt about." ([X](https://x.com/michpokrass/status/2107939609380331811)) **[official, staff]**
  - Aarush Selvan, PM: "the most helpful answers aren't just text" ([TechCrunch](https://techcrunch.com/2026/10/07/chatgpt-is-getting-a-lot-more-visual-with-the-launch-of-a-new-interface/), [SiliconANGLE](https://siliconangle.com/2026/10/07/with-gpt-6-chatgpts-responses-are-much-more-visually-appealing-and-interactive/)). **[official, staff]**
- **User controls.** Custom Instructions apply, and so do per-chat style requests. The help article says: "Personalization → Layout and Visuals → Simple. This reduces visual and interactive elements, though some may still appear." There is no off switch. It also says: "Some components, such as checklists, can retain their state when you refresh the chat thread. State is not retained across chat threads." ([help](https://web.archive.org/web/20261105160628/https://help.openai.com/en/articles/20001598-intelligent-ui-in-chatgpt)) **[official]**
- **OpenAI's own before/after example** (the Sunday lamb roast) shows the target style. Section 5 analyzes it ([announcement](https://openai.com/index/gpt-6-for-everyone/)). **[official]**

## 2. The model-facing format: DIL (with examples)

The internal name is DIL. The bundle names are `model_dil_v2`, `dil_runner`, `dil_sandbox`, and `canonical-dil` ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works), [Disdjj](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md), [Marc0Guo](https://github.com/Marc0Guo/IntelligenceUI/blob/main/FINDINGS.md)). **[multi]**

DIL is Markdown, plus JSX-like tags, plus Svelte-like template blocks, plus inline JavaScript. Several captures independently found the same grammar ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works), [Disdjj §4](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md), [Buqisir §4](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md)). **[multi]**

| Construct | Syntax |
|---|---|
| Prose | ordinary Markdown, including Markdown inside tags (`<text>**{downPct}%**</text>`) |
| Statement | `{@body const [seats,setSeats] = DIL.useState(8)}` (state, derived values, helper functions, even loops) |
| Interpolation | `{price}` |
| Conditional | `{#if x}…{:else if y}…{:else}…{/if}` |
| Loop | `{#each list as item, i}…{/each}` |
| Props | `size="lg"`, `value={seats}`, boolean shorthand `block`, `inline`, `tabularNums` |
| Events | `onChange={setSeats}`, `onClick={()=>GenUI.copy(csv)}` |
| Host actions | `GenUI.issueNewTurn(text)`, `GenUI.copy(text)`, `GenUI.openUrl(url)`, `GenUI.openEntityDetail(ref)`, `GenUI.runPluginTool({tool, arguments})` |

**Minimal example**, captured by OpenUI ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)):

```
## Team plan estimate

Drag the slider to see the **monthly price** for your team.

{@body const [seats,setSeats] = DIL.useState(8)}
{@body const price = seats*29}
<box border padding={3} gap={2}>
  <slider min={1} max={50} value={seats} onChange={setSeats}/>
  <title size="xl">${price}/mo</title>
</box>
```

**A richer real capture**, a 23 KB billing dashboard. It shows the header pattern and the styling vocabulary ([Disdjj artifact](https://github.com/Disdjj/intelligent-ui-demo/blob/main/artifacts/genui-source.dil.md)):

```
<box border radius="2xl" padding={3} gap={4}>
  <row align="center" justify="between" wrap="wrap">
    <row align="center" gap={2}>
      <box background="surface-secondary" padding={2} radius="lg"><icon name="layers-3" size="lg"/></box>
      <box gap={1}><title size="lg">Acme Billing</title><caption>Interactive Control Center · Demo</caption></box>
    </row>
    <badge color={incident?"warning":"success"}>{incident?"…":"…"}</badge>
  </row>
  <segmented-control block size="lg" value={tab} onChange={setTab} options={[{"label":"📊 …","value":"overview"}, …]}/>
  {#if tab==="overview"} <grid columns={2} gap={2}><grid-item><title size="xl" tabularNums>{money(totalRevenue)}</title></grid-item></grid> {/if}
</box>
```

**Server-resolved components.** The model describes the thing it wants and the server fills in the real data ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)). **[single, with partial support elsewhere]**

```
<AsyncImage query="slow roasted rosemary garlic lamb shoulder browned golden roast in baking tray" aspectRatio="5:4" maxWidth="152px"/>
<title size="lg">{turn448791product0.displayed_price}</title>
<caption>{turn448791product0.merchant}</caption>
```

The `turnXproductY` reference IDs are the same scheme the GPT-5.x prompts used ([gpt-5.6-sol.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/OpenAI/gpt-5.6-sol.md)). **[leak]**

**Premade widgets take a type and parameters:**

```
<LearningViz type_id="PROJECTILE_MOTION" initial_values={{"initialSpeedMetersPerSecond":18,"launchAngleDegrees":45}}/>
<Chart content={{"chartType":"line","xKey":"year","series":[...],"data":yearly}}/>
```

Both come from [Buqisir §3–4](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md). **[single]** The `content` shape matches the leaked `charts_widget_v2` spec: `chartType` (bar, line, pie, or scatter), `meta {title, description, footer}`, `xKey`, `series[{dataKey, label, valueFormat, valuePrefix, valueSuffix}]`, `layout: "vertical"` for long labels, and `data` last ([leak](https://github.com/asgeirtj/system_prompts_leaks/blob/main/OpenAI/Codex/plugins/data-analytics/skills/visualize-data/references/native-inline-visualizations.md)). **[multi]**

**AppBlock is the escape hatch:** a raw HTML/CSS/JS app wrapped in a tag. It can bind to outer DIL state ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works), [Buqisir §8](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md)). **[multi]**

```
<AppBlock title="Drum Lab" icon="app-chatgpt" variant="inline" app_block_id="drum-lab-01" bind={{value: settings, setValue: setSettings}}>
  <div id="dl">…<style>#dl{color:var(--viz-text)} #dl .panel{background:var(--viz-panel);border:1px solid var(--viz-border)}</style>…<script>…</script></div>
</AppBlock>
```

**Why the format looks like this.** OpenUI's reading: it is built from notation the model already knows well, and it keeps working while half-written ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)). Statements sit on their own lines, and any open element can be closed automatically, so the server can cut a partial response at the last complete construct. **[single, credible]** Pokrass's "token efficient, stream in instantly" fits this ([X](https://x.com/michpokrass/status/2107939609380331811)). **[official]**

**Every answer goes through DIL, plain text included.** A one-paragraph reply compiles to a 232-byte program that renders a single `<text>` ([Disdjj §5.1](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md)). **[single, credible]** So Intelligent UI is not a separate mode. The model always writes the same language and chooses how much structure to use.

**Pipeline.** The server recompiles the whole response every ~120–300 ms into three things: a JS program (`__dil.jsx` calls), a `constants` string table, and a `fallbackMarkdown` ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works), [Disdjj §3, §5](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md)). **[multi]**
- Each expression is wrapped in `__dilSafe(() => expr, fallback)`, so an error removes one element instead of breaking the page.
- Props are validated against the catalog. Unknown ones are dropped and logged as `unknown_prop` / `invalid_literal`.
- Unfinished tags are dropped and open elements are auto-closed. These repairs are logged as `recoveryDiagnostics` (`unterminated_tag`, `unclosed_block`, `unterminated_braced_value`).
- A hidden iframe runs the code in a locked-down Worker (`runner.html`, protocol v14, no network, frozen globals, watchdog). It emits CREATE/SET/PLACE operations that the page applies to native components. The page accepts only known component types.

## 3. Component catalog

The catalog has three layers ([Buqisir](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md), [OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works), [Disdjj §7](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md)). **[multi]**

1. **Lowercase primitives**, which the model composes freely. OpenUI counts about 70 in the client registry, 39 of which appear in captures. Names seen across captures:
   - Layout: `box`, `row`, `col`, `card`, `grid`, `grid-item`, `divider`, `form`, `list-item`, `carousel-item`, `swipe-stack`, `popover`, `pressable`, `html-view`, `loading-block`, `shimmer-text`
   - Text: `title`, `text`, `label`, `caption`, `bold`, `icon`, `badge`
   - Inputs: `button`, `input`, `slider`, `select`, `checkbox`, `radio-group`, `radio`, `segmented-control`, `date-picker`
   - Data: `table`, `table-row`, `table-cell`, `pie-chart`, `chart`
   - Raw `svg` elements are allowed, with any colors inside them.

   Sources: [Disdjj §7.1](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md), [Buqisir §4, §8](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md), [Marc0Guo](https://github.com/Marc0Guo/IntelligenceUI/blob/main/FINDINGS.md). **[multi]**
2. **Capitalized host and composite components**, which the model calls with parameters. 30 load eagerly:
   - `AsyncImage`, `AsyncImageGroup`, `AsyncVideo`, `Cite`, `Citation`, `CodeBlock`, `Entity`, `FileCite`, `FlightCard`, `FlightCarousel`, `FollowUp`, `FollowUpActionBar`, `GenImage`, `LearningVizDil`, `Link`, `LinkCard`, `MemoryCite`, `NewsCarousel`, `PersonalityQuizWidget`, `ProductCard`, `SpeechSynthesizer`, `WritingBlock`, …

   283 load lazily. They include roughly every legacy ChatGPT widget (weather, stocks, sports, `UnitConverterWidget`, `ChecklistWidget`, `DigitalTimerWidget`, `LearningQuiz`, `LearningFlashcards`) plus about 50 medical calculators ([Disdjj §7.2](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md)). **[single, consistent with Marc0Guo's string dump]** OpenAI writes some of these composites in DIL itself; the bundle contains compiled `state.translationPairs.map(...)` code ([Marc0Guo dil-terms](https://github.com/Marc0Guo/IntelligenceUI/blob/main/capture/dil-terms.txt)). **[single]** Per RuntimeWire, the Codex client lists 467 "Learning Block" types and versions; the paywalled article does not say how many the model can reach ([RuntimeWire](https://runtimewire.com/article/openai-is-building-an-interface-platform-inside-chatgpt), [Buqisir §3](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md)). **[single]**
3. **`AppBlock`**, the open-ended HTML lane described in §2.

**Design tokens, which are the only styling the model writes** ([Buqisir §4](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md), [Disdjj](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md), [OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)). **[multi]**
- **Spacing** is an integer scale on a 4 px base: `padding={3}` is 12 px and `gap={2}` is 8 px. Some code also uses half steps (`gap: 1.5`).
- **Radius:** `radius="lg"`, `"xl"`, `"2xl"`.
- **Color:** `color="secondary"`, `background="surface-secondary"`, and badge colors `success` and `warning`.
- **Text:** `size="xs…xl"`, `weight="medium"`, `tabularNums`.
- **Variants:** `variant="outline"`, `block`, `pill`, `uniform`.
- Raw px and hex values are accepted in some places but tokens are preferred. One capture lost `gap="1"`, which was a string where a number was expected.

**Type scale from the client CSS** ([Marc0Guo components-slice](https://github.com/Marc0Guo/IntelligenceUI/blob/main/capture/components-slice.txt)). **[single, raw bundle]**
- Headings: sm and md 1 rem / 1.625, lg 1.125 rem, xl 1.25 rem, 2xl 1.5 rem, 3xl 3 rem, 4xl 3.75 rem, 5xl 4.5 rem.
- Text: xs 0.75 rem, sm 0.875 rem, md 1 rem / 1.625.
- "Strong" weights are medium for small sizes and semibold from md up.

Note what this means: **headings inside answers are small**. An `lg` title is only 1.125 rem. Hierarchy comes from weight and spacing, not size.

**Icons** come from a sprite of 834 symbols, referenced by name (`<icon name="arrow-right" inline/>`) ([Disdjj §1](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md)). **[single]**

**Relation to ChatKit** **[inference]**. The primitives and props match the public [ChatKit widgets](https://developers.openai.com/api/docs/guides/chatkit-widgets) almost one for one:
- Box, Row, Col, Title, Caption, Badge, Button, Select, DatePicker, Divider, Icon, Form
- radius tokens from `2xs` to `4xl`
- badge colors `success`, `warning`, `danger`, `info`, `discovery`
- button props `pill`, `uniform`, `block`, `variant`

The DIL carousel button code uses the same `pill:!0,size:"sm",uniform:!0,variant:"outline"` ([Marc0Guo snapshot](https://github.com/Marc0Guo/IntelligenceUI/blob/main/capture/snapshot-kebab.txt)). So DIL looks like ChatKit's design system, lowercased, with logic added. ChatKit itself is developer JSON, not a model format.

## 4. Rules for components versus prose

The actual GPT-6 rules are trained in and not public. What exists:

**Official stance:** "The format depends on what you're asking. A comparison might work best side by side. An explanation might be easier to understand through an interactive diagram. And when a simple text answer is the most useful response, ChatGPT can give you that." ([help](https://web.archive.org/web/20261105160628/https://help.openai.com/en/articles/20001598-intelligent-ui-in-chatgpt)) **[official]**

**The official ladder of simplest format** for Visualize, from the help docs: diagram for labeled relationships or a process; chart for named numbers; map for geography; interactive only "when inputs, time, motion or spatial relationships should change"; a hosted Site for anything persistent. The page is the German AI translation of the English original ([learn.chatgpt.com](https://learn.chatgpt.com/de-DE/docs/visualizations)). **[official]**

**Leaked OpenAI rules** (verbatim, from the [Visualize SKILL.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/OpenAI/Codex/plugins/visualize/skills/visualize/SKILL.md) unless noted). **[leak]**
- "Create a visual only when the user needs to see or explore it in the conversation and it materially improves the explanation. Do not create an inline visual merely because the request involves data, charts, or an interactive page."
- "Use a normal Markdown table when the user asks for a table" and "Use Mermaid when labeled nodes and edges fully explain a static structure".
- "Choose the smallest composition that fits."
- "never invent search, filter, or reset controls."
- "Never invent qualitative scores, status cards, or secondary fact grids to fill space."
- "In user-facing prose, describe only what the visual helps the user see or decide ... do not repeat information already clear from the visual. Never announce this skill, a visualization surface, widgets, HTML..."
- The GPT-6 Sol Codex prompt adds ([CL4R1T4S, 2026-09-22](https://github.com/elder-plinius/CL4R1T4S/blob/main/OPENAI/Codex_Desktop/GPT-6-Sol_Prompts.txt)): "Prefer interactive visuals when explaining how something works, exploring cause and effect, comparing options, or showing how things change across scenarios ... Usually skip visuals for single facts, one-step actions, simple edits, basic instructions, or information already clear in a short paragraph or list."
- The GPT-5.6 Codex prompt's criteria ([CL4R1T4S](https://github.com/elder-plinius/CL4R1T4S/blob/main/OPENAI/Codex_Desktop/5.6-Sol_SystemPrompt.md)): use a visual for "several exact mappings", "one source ... affecting three or more downstream consumers", "three or more dependent steps", "hierarchy, ownership, nesting, or layout". The prompt then says: "Prefer the smallest useful visual: a table for mappings or comparisons, a flow or timeline for sequence or change, a tree for hierarchy or branching, and a wireframe for layout."
- The older ChatGPT rules for the 5.x widgets: one rich element per response; never put one inside a table or list; the text must stand on its own ([gpt-5.5-thinking.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/OpenAI/gpt-5.5-thinking.md), [gpt-5.6-sol.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/OpenAI/gpt-5.6-sol.md)). GPT-6 visibly relaxed the "one element" rule; the lamb roast uses a summary card, menu cards, a stepper, and a checklist.

**Observed GPT-6 behavior** across 26+ physics captures ([Buqisir §8](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md)). **[single, large sample]**
- Static geometry, even when draggable, is composed from primitives and hand-written SVG.
- Anything that has to play (motion over time) goes to AppBlock.
- When a premade component cannot express the problem, the model switches routes instead of forcing it. `PROJECTILE_MOTION` has no launch height, so it wrote a simulator.
- The slider is chosen to be the variable the question asks about, or the one it leaves out. Quick-jump buttons go to key states. Every scale compression is labeled ("not to scale").
- The answer structure was stable: worked solution, then an interactive demo seeded with the problem's numbers, then observations, then a summary.

**Unverified:** a search summary claimed that Selvan said the team spent a lot of time deciding when visuals add value versus clutter. The page it cited contains no such passage ([under30ceo](https://www.under30ceo.com/chatgpt-interface-intelligent-ui/)), so treat it as unsupported.

## 5. Design craft: what makes it look good

**1. It is the product's own design system, not generated CSS.** "Generated interfaces look like the rest of ChatGPT on every platform" because the page draws only native components ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)). **[multi]** Buqisir's main point: the whole mortgage-calculator output contained no line of CSS, and "这是模型能写复杂逻辑、外观又始终统一的关键" (this is why it can write complex logic and still look uniform) ([Buqisir §4](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md)). **[single, consistent]**

**2. Markdown is compiled into the same tree as the components.** A heading becomes `title`, a paragraph becomes `text`, and `**bold**` becomes `bold`. Prose and widgets therefore share one type scale and spacing rhythm instead of a card dropped into a document ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)). **[multi]**

**3. Restraint is written down.** The leaked Visualize rules ([SKILL.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/OpenAI/Codex/plugins/visualize/skills/visualize/SKILL.md)) **[leak]** read like a style guide for a quiet UI:
- **Surfaces.** "`.card`: The only card-like HTML surface ... Keep charts, maps, diagrams, tables, controls, and the whole visualization unframed. Never nest cards; show 2-4 summaries near the top only when useful." "Keep the top-level surface transparent and unframed."
- **Charts.** "Frame only the SVG plot area; never wrap charts in `.card`, rounded panels, filled backgrounds, or shadowed containers." "For named numeric data ... start with the plot. Put values and takeaways on its marks, axes, or annotations. Never add a KPI row, controls, cards, or panels unless ... explicitly requested."
- **Color.** "Use `--viz-series-1` for one measure or active state ... never give every peer a different color by default." "Use series colors only for chart lines, marks, and legend swatches. Keep values, axis text, and direct labels in `--foreground` or `--muted-foreground`." "Never add decorative borders ... to progress tracks, meters, bars." "Keep chart grids and inactive structure thin and neutral."
- **Type.** "Use only weights `400` and `500`. Never set custom font sizes or line heights." "Use `.tabular-nums` on changing or aligned numbers." "use one concise visible heading ... Do not restate the prompt or add a redundant title."
- **Legends and tables.** Legends are "transparent, borderless, and indistinguishable from inline text; never use `.btn`, pills, badges". "Add a legend only when multiple series cannot be labeled directly." Tables are "quiet, unframed ... subtle horizontal dividers without vertical gridlines. Use sentence case for headers."
- **Explainers.** "one compact dominant visual, and at most one single-line selected-state detail. Default to no summary cards".
- **Theme.** "Make every fill, stroke, text, border, shadow, chart, and canvas color theme-aware. Never hardcode light or dark palettes".
- **Icons.** "Never author inline icon SVG ... Use only supplied Lucide names".
- **Motion.** "Animate transitions between chart states so lines and marks move to their new values ... Do not animate initial appearance or use fade-only effects; never loop motion, and honor `prefers-reduced-motion`."
- **Layout.** "Design for 736px ... support widths down to 320px." "avoid fixed outer widths ... internal scrolling".

**4. The official example shows the answer structure.** The GPT-6 Sunday roast ([announcement](https://openai.com/index/gpt-6-for-everyone/)) **[official]** has:
- a short warm lead paragraph;
- a compact plan summary (title "Sunday roast with friends") with key-value rows (Style, Prep, Cooking, Serving);
- numbered section headings (1. The menu, 2. How much should you buy?, 3. Your Sunday cooking timeline, 4. Three hosting tips);
- menu items as label-plus-name cards ("The centerpiece:", "The essential:");
- one interactive stepper ("−5 People +") that drives a computed shopping list, with a "Copy shopping list" button;
- a timeline checklist with progress ("1 of 8");
- one closing personal recommendation.

The GPT-5.6 version of the same answer is the same content as Markdown headings, bullets, and a table. The difference lies in the summary card, one control tied to computed values, the checklist, and images from `AsyncImage` ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)).

**5. Real imagery without hallucinated URLs.** The model writes an image search query with an aspect ratio and max width (`aspectRatio="5:4" maxWidth="152px"`). The server runs the search, checks the URLs, and patches in the result a second or two later ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)). **[single]** Small fixed-ratio thumbnails beside text are a big part of why answers look "designed".

**6. Streaming choreography** ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works), [Marc0Guo](https://github.com/Marc0Guo/IntelligenceUI/blob/main/FINDINGS.md)). **[multi]**
- Text streams word by word. Each component appears only once its tag is complete; it never renders half-built.
- Text fades in over 0.7 s, new rows and grid items slide in over 0.42 s, charts draw over 1.8 s, and container heights transition instead of jumping.
- The client marks these with `data-d-stream-word`, `data-d-stream-chart-reveal`, `data-d-stream-media`, `data-d-streaming-height`, and `data-d-streaming-table-motion`.
- Static text sits in a constants table, so growing text changes data, not structure.
- If a new program fails, the worker keeps the last one that worked.

**7. Tolerance for errors is part of the look.** Invalid props are dropped silently. A throwing expression removes one element. The `Chart` shim renders empty data rather than an error ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works), [Disdjj §5.2](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md)). **[multi]** Users never see a broken widget, only a smaller one.

**8. The escape hatch is themed.** AppBlock gets:
- Tailwind base styles;
- `--viz-text`, `--viz-panel`, `--viz-border`, `--viz-card`, `--viz-muted`, and `--viz-accent` variables;
- an iframe sized to its content, so it reads as part of the response ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works), [Buqisir §8](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md)). **[multi]**

This is also where the look breaks most: see §7.

## 6. Interactivity and state

- **Local first.** Sliders, checkboxes, and tabs update state inside the sandbox worker and re-render without a model call ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works), [Buqisir §5](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md)). **[multi]**
- **One way back to the model.** `GenUI.issueNewTurn(text)` sends an ordinary user message that the program builds from state, for example `<button block onClick={()=>GenUI.issueNewTurn("Develop a detailed dog vest design concept ... Style: "+style+". Main color: "+color+...)}>Develop this direction <icon name="arrow-right" inline/></button>`. Nothing marks it as coming from the UI. Forms (`<form onSubmit>` + `<button submit>`) work the same way ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)). **[single, credible]** Multiple-choice clarifying questions in the launch demos follow this pattern ([Latent Space](https://latent.space/p/claude-mods/)).
- **Persistence.** The `useState` keys are semantic (`{key:"tab"}`). The client POSTs all state to `/backend-api/conversation/{cid}/message/{mid}/dil/view_state` ([Disdjj §8](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md)). **[single]** The help article confirms that some components keep state on refresh ([help](https://web.archive.org/web/20261105160628/https://help.openai.com/en/articles/20001598-intelligent-ui-in-chatgpt)). **[official]**
- **Does the model see UI state? The sources conflict.**
  - Disdjj found a `genui_state_snapshots` field in the conversation request and infers that state is fed back. Their only sample is a first turn with an empty array ([Disdjj §8, §12](https://github.com/Disdjj/intelligent-ui-demo/blob/main/ANALYSIS.md)).
  - OpenUI found that state resets on reload and that the model "could not report values the user had changed" ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)).
  - In the Visualize lane, OpenAI's skill says `setWidgetState({modelContent, privateContent})` and that "Only `modelContent` may reach the model: delivery is best-effort" ([SKILL.md](https://github.com/asgeirtj/system_prompts_leaks/blob/main/OpenAI/Codex/plugins/visualize/skills/visualize/SKILL.md)). **[leak]**

  Treat model-visible state as unreliable.
- **Follow-ups regenerate rather than edit.** Each follow-up writes a new program; the existing interface is never patched ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works); the official Visualize docs say the same, [learn.chatgpt.com](https://learn.chatgpt.com/de-DE/docs/visualizations)). **[official + single]**

## 7. People's experiments and opinions

**Named people and outlets**
- **Ethan Mollick:** "a nice change from walls of text. It also suggests that, increasingly, we are going to see interfaces built on demand for the problem that you have." ([X](https://x.com/emollick/status/2107938889004396561))
- **Latent Space** (Dan McAteer): "the model picks the interface, answer by answer, from a component library that OpenAI built ... Zero setup, but little control"; "I don't believe the target user is engineers." ([Latent Space](https://latent.space/p/claude-mods/))
- **Simon Willison** has not written about Intelligent UI. His GPT-6 game tests say ChatGPT-built games "look great" but don't "play nearly as well" ([simonwillison.net](https://simonwillison.net/2026/Oct/28/vibe-game-development/)).
- I found nothing from Karpathy, Nathan Lambert, Every, or Stratechery.
- **Bestfolios** (AI UX Playground, design-focused): "Lead with text that stands alone"; "Use generated UI where prose cannot do the job"; reserve space so "the page does not jump"; "A closed kit has a ceiling you cannot see." Weak spots: unpredictable format, long mixed replies with no way to collapse them, hidden assumptions behind clean results, and a settings toggle with two bare words. Verdict: strong inside the components, weak around them ([Substack](https://aiuxplayground.substack.com/p/chatgpt-puts-the-interface-in-the)).
- **Lisa Demchenko** (Process to Pixels): "the component library is the design system, just not ours"; "a tidy interactive comparison can make an answer feel more trustworthy than it has earned"; "A nicer-looking answer isn't a more correct one." ([Substack](https://processtopixels.substack.com/p/answers-are-turning-into-interfaces))
- **Gizmodo:** token cost, and "visual elements introduce a whole new layer of opportunity for hallucinations." ([Gizmodo](https://gizmodo.com/openai-wants-chatgpt-to-stop-looking-like-a-chatbot-2000823211))

**Hacker News launch thread** (761 points, 459 comments; [HN](https://news.ycombinator.com/item?id=49996425))
- "GPT-6's design sense is kind of ridiculous imo. I have explicit instructions to tone it down. Less taglines, eyebrow text, subheadings, decorative spacing, pills, cards." ([comment](https://news.ycombinator.com/item?id=49996909))
- "almost repulsed by all the images, so much needless whitespace, checklist ... Feels like I'm being condescended to" ([comment](https://news.ycombinator.com/item?id=49997016))
- The "disposable UI" / "paper plate UI" framing, with worries about overzealousness and latency ([comment](https://news.ycombinator.com/item?id=49997066))
- "How would a user know whether a generated visualization ... is accurate" ([comment](https://news.ycombinator.com/item?id=49996896))
- The roast shopping list lost detail the text version had, such as what kind of potatoes ([comment](https://news.ycombinator.com/item?id=49998315))
- "why not just stream html?" ([comment](https://news.ycombinator.com/item?id=49996848))
- A positive one on explainers à la Bartosz Ciechanowski ([comment](https://news.ycombinator.com/item?id=49996963))

**OpenAI forum:** users want text by default with visuals on request. OpenAI Support passed the feedback on but made no commitment ([community](https://community.openai.com/t/intelligent-ui-not-a-fan/1406196)).

**Failure modes from reverse engineering**
- **OpenUI** ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)):
  - Logic errors are silent; switching one chart metric moved revenue from $6,930 to $256,410.
  - The model repeats invalid props across responses, so diagnostics probably never reach it.
  - Image search can miss, and the model never sees the result.
  - Layouts use fixed column counts and px widths, and no captured response used breakpoint hooks.
  - 83% of a 275 KB stream was resent program code.
  - One click produced 158 operations, only 4 of them meaningful.
- **Buqisir's 26-problem physics study** ([Buqisir §8](https://github.com/Buqisir/genui/blob/main/genui-capture-findings.md)):
  - All answers were correct, but visual bugs kept recurring: label overlap, SVG arrowheads blown up because `markerUnits` was left at its default, reversed arc sweep flags, a progress slider that would not drag, circuit symbols drawn wrong.
  - In AppBlocks the model hardcoded light or dark backgrounds, so dark mode broke in four of five high-effort samples.
  - Extra-high reasoning did not fix visual bugs and made theming worse.
  - The author's conclusion: anything high-frequency and error-prone (vectors, circuits, function plots, dimension lines) should be a premade component.

## 8. Credibility of the main claims

| Claim | Level | Basis |
|---|---|---|
| GPT-6 was trained and evaluated for layout decisions, uses a native streamable component library and a compiler, and can give plain text | official | [announcement](https://openai.com/index/gpt-6-for-everyone/), [help](https://web.archive.org/web/20261105160628/https://help.openai.com/en/articles/20001598-intelligent-ui-in-chatgpt) |
| The design goals were token efficiency, instant streaming, and matching the design language | official (staff) | [Pokrass](https://x.com/michpokrass/status/2107939609380331811) |
| The format is DIL (Markdown + JSX-like tags + `{@body}` JS + `{#if}`/`{#each}`), compiled server-side into `model_dil_v2` | multi | OpenUI, Disdjj, Buqisir, Marc0Guo (independent captures and bundles) |
| Props are validated against the catalog and unknown ones dropped; `__dilSafe` isolates errors | multi | OpenUI, Disdjj |
| About 70 primitives (39 seen); 30 eager + 283 lazy host components | single each, consistent | OpenUI; Disdjj |
| Token props (padding 4 px scale, radius, surface/secondary colors) and no CSS from the model | multi | Buqisir, Disdjj, OpenUI |
| Streaming animation timings (0.7 s, 0.42 s, 1.8 s) | single + bundle attributes | OpenUI, Marc0Guo |
| Server-resolved `AsyncImage` and tool-result binding by ID | single (OpenUI), lineage in leaked 5.x prompts | OpenUI, gpt-5.6-sol.md |
| `issueNewTurn` is the only path back to the model | single, credible | OpenUI; Disdjj lists the same facade |
| The model sees UI state on the next turn | conflicting | Disdjj (inferred) vs OpenUI (tested, negative) |
| The `charts_widget_v2` JSON spec shape | leak + multi | leaked reference + Disdjj metadata + Buqisir `Chart` capture |
| The Visualize design rules (cards, color, type, motion) | leak | asgeirtj SKILL.md; matches the official Visualize docs and `--viz-*` vars seen in captures |
| A GPT-6 ChatGPT system prompt with DIL instructions exists publicly | **no** | 3 repos + GitHub code search checked 2026-11-12 |
| Lowercase DIL primitives are ChatKit's design system | inference | prop-name overlap with [ChatKit widgets](https://developers.openai.com/api/docs/guides/chatkit-widgets) |

**Developer products (task 4).** No public API exposes DIL or Intelligent UI. I searched the Responses API docs and changelog and found nothing ([migrate guide](https://developers.openai.com/api/docs/guides/migrate-to-responses)). The related public pieces are:
- **ChatKit widgets:** developer-authored JSON trees, with actions sent to your backend ([docs](https://developers.openai.com/api/docs/guides/chatkit-widgets)).
- **Apps SDK / MCP Apps:** iframe widgets. AppBlock reuses its "Skybridge" host ([OpenUI](https://www.openui.com/blog/how-chatgpt-intelligent-ui-works)), and `window.openai.widgetState` appears in the Visualize skill.
- **The Visualize plugin and Sites** ([learn.chatgpt.com](https://learn.chatgpt.com/de-DE/docs/visualizations)).

OpenUI argues that DIL, A2UI, OpenUI Lang, and json-render are converging "interface inference languages" ([OpenUI](https://www.openui.com/blog/intelligent-ui-needs-a-new-html)). OpenUI sells a competing framework, so treat that framing as interested.

## 9. Lessons for a markdown-plus-tags renderer (Wicket)

Ordered by how much each one would improve how answers look and feel.

1. **Make tags pick from tokens, never from CSS.** Every attribute should be an enum or an integer step: `gap`/`padding` on a 4 px scale, `size` xs–xl, `tone` default/secondary/success/warning/danger, `radius` sm/lg/2xl. The model then cannot produce off-theme output. This is the core reason ChatGPT's answers look native.
2. **Render Markdown and tags in one typographic system.** Headings, paragraphs, and tags should share one type scale and spacing rhythm in the CSS theme. Keep heading sizes small (ChatGPT's `lg` title is 1.125 rem) and build hierarchy from weight (two weights: 400/500, or semibold for strong) and spacing. Use tabular numerals for any changing or aligned number.
3. **Put restraint in the contract.** Copy the leaked rules almost word for word into the agent instructions:
   - one framed surface type and no nested cards;
   - charts, tables, and the answer itself unframed;
   - one accent color for the primary measure, with series colors only on marks;
   - no KPI rows, filters, or status cards unless asked;
   - "choose the smallest composition that fits";
   - prose says only what the visual can't.

   HN's complaint list (taglines, eyebrow text, pills, cards, decorative spacing) is the anti-pattern list to write down too.
4. **Keep a small ladder of tags with a one-sentence purpose each:** a stat or summary block, a key-value list, a comparison or table, a chart (bar/line/pie only, with a JSON shape like `charts_widget_v2` and `data` last), steps or a checklist, an image by query, and a button that sends a follow-up. The model only uses what is described well. ChatGPT's `matched_text` for each widget is that one-sentence purpose, and it doubles as the fallback text.
5. **Pass data by reference, not by retyping it.** Let tags point at provider results by ID (as with `turn0product1`) and let the renderer fill in the exact values, images, and URLs. For images, have the model write a search query plus aspect ratio and let the host resolve it; never let it write URLs.
6. **Stream components only once they are complete.** Hide a tag until its closing `>` or `/>`. Auto-close unclosed containers at the end of the stream, and drop unknown tags or attributes silently, but log them. Animate entry: text fades in, blocks slide in briefly, charts draw, heights transition. Reserve space where you can, so the page doesn't jump.
7. **Fail per element.** Any tag that cannot render degrades to its Markdown text, not an error box. Keep a plain-Markdown fallback for copying and export (ChatGPT stores `fallbackMarkdown` for every answer).
8. **Keep interaction local, with one explicit path back.** Controls change local values. The only way to reach the agent is a button that sends a normal user message built from those values ("Develop this direction →"). Don't pretend the agent sees widget state.
9. **Prefer prebuilt components over model-drawn ones.** A prompted model, with no training on your format, does well at choosing and parameterizing components and badly at drawing (SVG arrows, overlapping labels, hardcoded colors). Buqisir skipped free composition without post-training for the same reason. Logic in tags (`{#if}`, state) is what made ChatGPT's tools possible, but it needs a sandbox. For a launcher, a handful of parameterized components probably beats a mini-language.
10. **If you add an HTML escape hatch, theme it from outside.** Inject the theme's CSS variables and base styles, size the frame to its content, and forbid hardcoded colors in the instructions. Expect that rule to be broken anyway.
11. **Give users the "Simple" lever.** ChatGPT's most common complaint is visuals nobody asked for, with no off switch. A config setting that limits the agent to prose plus tables costs little, and so does honoring "plain text" in the request.
12. **Don't let polish outrun truth.** Show assumptions next to computed results, and keep the key facts in text, as the old OpenAI rule required: the text must stand on its own.

## Appendix: Claude's own "Imagine" prompt (leak)

asgeirtj/system_prompts_leaks also holds claude.ai's visual tool prompt (`Anthropic/visualize.md`, about 770 lines, unverified). It is the same HTML-lane idea as OpenAI's Visualize skill and agrees with it on almost every design rule:
- Seamless, flat, compact: "Users shouldn't notice where claude.ai ends and your widget begins." No gradients, shadows, blur or emoji; transparent outer containers.
- Text stays in the reply, the tool holds only the visual; no titles or prose inside it.
- Two weights only (400, 500), headings 22/18/16 px, sentence case everywhere, no mid-sentence bold, nothing under 11 px.
- Colour encodes meaning, not sequence: 2-3 ramps per diagram, gray for structure; text on a coloured fill uses the 800/900 stop of the same ramp.
- Hard complexity budget (box subtitles of at most 5 words, at most 4 boxes per row), a viewBox checklist against clipping, and streaming order (short style, content, script last; no hidden tabs while streaming).
- `sendPrompt(text)` is the one path back to the model, as with OpenAI's `issueNewTurn`.
