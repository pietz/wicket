# View languages across launchers and model-driven interfaces

Research date: 17 November 2026. Primary documentation and source repositories unless marked otherwise. This extends [raycast-2-ui-stack.md](raycast-2-ui-stack.md), [openai-intelligent-ui.md](openai-intelligent-ui.md) and [t3code-visual-replies.md](t3code-visual-replies.md). Examples below are newly written illustrations, not captured outputs. No recommendation for Wicket is made.

## A. Launchers

Unless specified, developers write these interfaces. Updating an existing view is not the same as accepting an unfinished model response. “Constraint” below means a documented capability boundary, not necessarily a user complaint.

| System | Notation and layout | Updates, theme, actions, constraints |
|---|---|---|
| **Raycast classic** | React/TypeScript JSX describing a fixed catalog: List, Grid, Detail, Form. Native AppKit renderer, not browser DOM. Detail embeds CommonMark, so JSX is not the sole content grammar. | React state updates; host controls appearance; ActionPanel attaches callbacks/navigation. No general div/CSS composition. [List API](https://developers.raycast.com/api-reference/user-interface/list). |
| **Raycast 2** | Same extension-facing React API; implementation changed to React web content in a native platform shell. On macOS WebKit renders the main interface, including extension views. | React updates and host styles; existing action API. Authors report native maintenance, hiring and cross-platform costs as reasons for rewriting. It is incorrect to infer native rendering from JSX or native window chrome. [Technical account](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast). |
| **Alfred** | Script Filter JSON rows; Grid View largely reuses that schema; Text View uses JSON carrying plain text/Markdown. These are separate workflow objects, not arbitrary nested layouts. | Script reruns replace results; Text View can update dynamically. Host themes and text size preferences; `arg` and modifier arguments flow into connected workflow actions. Grid ignores `rerun`. Rich pages still require Markdown, not row JSON alone. [Rows](https://www.alfredapp.com/help/workflows/inputs/script-filter/json/), [Text](https://www.alfredapp.com/help/workflows/user-interface/text/), [Grid](https://www.alfredapp.com/help/workflows/user-interface/grid/). |
| **LaunchBar** | Script actions return JSON result items, with titles, icons and action-related properties. Fixed result browsing, with separate Large Type and previews. | Complete script results; host appearance; action scripts and URLs handle activation. No verified free dashboard language or partial-JSON streaming. [Developer reference](https://developer.obdev.at/launchbar-developer-documentation/). |
| **Vicinae** | React/TypeScript extension API and Raycast compatibility; current repository describes QtQuick/QML presentation and C++ logic. | React updates translated to host UI, host theme and actions. Compatibility varies, particularly for macOS-specific APIs. No verified arbitrary CSS dashboard surface. [Architecture](https://github.com/vicinaehq/vicinae/blob/main/AGENTS.md), [compatibility](https://docs.vicinae.com/install-extensions). |
| **Sol** | React Native launcher implementation, scripts and built-in commands. | I could not verify a supported third-party rich-view notation, streaming contract, or extension styling/action schema. Do not treat its implementation language as an extension language. [Repository](https://github.com/ospfranco/sol). |
| **ueli** | TypeScript result data: `name`, `description`, `image`, `defaultAction`, optional `additionalActions` and `details`. Fixed search-result model. | Results supplied by extension logic; host renders and styles them. Action objects attach behavior. A public free-layout dashboard language and partial-spec streaming were not verified. [Actual result type](https://github.com/oliverschwendener/ueli/blob/main/src/common/Core/SearchResultItem.ts). |
| **PowerToys Command Palette** | .NET/WinRT objects: list, detail, form, Markdown and grid pages. Forms use Adaptive Card JSON; content pages can contain richer content. | Asynchronous item changes notify the host; host appearance and command objects; card actions handle forms. Native list objects and card JSON are distinct representations. [Overview](https://learn.microsoft.com/en-us/windows/powertoys/command-palette/extensibility-overview), [forms](https://learn.microsoft.com/en-us/windows/powertoys/command-palette/using-form-pages). |
| **Tinycast** | Exists: SwiftUI/AppKit launcher running built Raycast extensions through JavaScriptCore, rendered in SwiftUI. | React-style extension screens and action menus; appearance switches on the next command launch. Authors document compatibility gaps. It supplies a new runtime for an existing API, not a newly invented data language. [Extension documentation](https://tinycast.dev/docs/extensions/). |

## B. Other systems

Here “both” means a model can author the representation as well as a program. It does not establish equal reliability. Where documentation only describes message replacement, no incremental syntax parser is implied.

| System | Authors, notation and layout | Streaming, styling, actions and documented limits |
|---|---|---|
| **Slack Block Kit** | Developers; JSON blocks containing Slack text notation. Mostly fixed blocks, sections, fields and accessories. | Current agent sessions support streaming blocks and replacing block IDs. Host theme; action IDs route interactions. Block/text limits and surface-specific support constrain composition. [Block Kit](https://docs.slack.dev/block-kit/), [streaming](https://docs.slack.dev/reference/methods/chat.startStream/). |
| **Adaptive Cards** | Developers or models; JSON component tree, Containers, ColumnSets, text, images, inputs. Composition within a catalog. | Usually send/update whole cards; no universal unfinished-JSON rendering contract. HostConfig owns typography, spacing and colors; OpenUrl/Submit/Execute actions. Host schema-version and feature support differ. [Host configuration](https://learn.microsoft.com/en-us/adaptive-cards/rendering-cards/host-config), [schema](https://adaptivecards.io/explorer/). |
| **Discord** | Developers; JSON embeds, or Components V2 with text, sections, containers and accessories. | Message edits, not token streaming; host appearance plus limited colors. Buttons use URL/custom IDs. Embeds have field/text budgets; V2 has component budgets and different message rules. [Message schema](https://github.com/discord/discord-api-docs/blob/main/developers/resources/message.mdx), [components](https://docs.discord.com/developers/components/reference). |
| **Telegram** | Developers; JSON message entities or restricted MarkdownV2/HTML plus keyboard JSON. Fixed messages, not dashboard composition. | Send/edit messages; host styling; callback data, URLs and Web Apps. Escaping and formatting restrictions; full layouts require a separate HTML Mini App. [Bot API](https://core.telegram.org/bots/api), [features](https://core.telegram.org/bots/features). |
| **Apple snippets, widgets, Live Activities** | Developers; compiled SwiftUI view trees, parameterized by app state. Free composition within each surface's limits. | Snippets regenerate after intents; widgets use timelines; Live Activities use state updates, not streamed source. System environment and modifiers style views. AppIntent buttons/toggles attach behavior. Repeated snippet execution must avoid side effects; surfaces constrain controls and execution. [Snippets](https://developer.apple.com/documentation/appintents/snippetintent), [interactivity](https://developer.apple.com/documentation/widgetkit/adding-interactivity-to-widgets-and-live-activities). |
| **Home Assistant** | Users/developers; YAML configuration with typed cards, grids and stacks. | Entity state updates existing cards; themes and CSS variables; tap/hold actions call services or navigate. Custom web cards extend the catalog but add code and maintenance. [Cards](https://www.home-assistant.io/dashboards/cards), [actions](https://www.home-assistant.io/dashboards/actions). |
| **Notion blocks** | Users/integrations/models; JSON typed blocks, rich-text arrays, columns and children. | Append/update API calls, not unfinished block parsing; host styles with limited annotations/colors. Links and supported block interactions, not arbitrary callbacks. Unsupported block types and nesting rules limit round trips. [Block reference](https://developers.notion.com/reference/block). |
| **GitHub Markdown** | Both; Markdown plus alerts and permitted HTML such as details/summary. Document flow, tables and lists. | A renderer can reparse prefixes, but GFM specifies no streaming transport. GitHub theme and sanitization; links/disclosures, no arbitrary action callbacks. Alerts and details are GitHub features beyond the core GFM spec. [Alerts](https://docs.github.com/en/get-started/writing-on-github/getting-started-with-writing-and-formatting-on-github/basic-writing-and-formatting-syntax#alerts). |
| **MDX** | Both; Markdown, JSX, expressions and imports. Arbitrary supplied components. | Compilation normally needs syntactically valid input; incremental repair is extra machinery. CSS/component themes; JS handlers. Executable content requires trust or isolation, not just an HTML sanitizer. [MDX explanation](https://mdxjs.com/docs/what-is-mdx/). |
| **ChatGPT apps/widgets** | Developers write HTML/JS widgets; model selects tools and supplies data. | Tool results feed an iframe; separate widget lifecycle. CSS/theme integration and host bridge actions. CSP, sandbox and host compatibility are real integration work. This is not a model-facing universal component grammar. [Current UI integration](https://developers.openai.com/plugins/build/chatgpt-ui). |
| **MCP Apps / MCP-UI** | Developers, potentially models; HTML resource linked from tool metadata. | Sandboxed iframe plus JSON-RPC bridge, not streamed HTML syntax. CSS and host context; tool calls/messages handle actions. MCP-UI's current SDK implements MCP Apps; historical remote-DOM/URL modes should not be confused with the standard. [MCP Apps](https://py.sdk.modelcontextprotocol.io/advanced/apps/), [MCP-UI](https://mcpui.dev/guide/introduction). |
| **Google A2UI** | Both; flat JSON component definitions, IDs, data bindings and update messages. Current SDK also accepts compact Express expressions compiled to wire JSON. | Progressive component/data messages; client-owned catalog and theme; named action events. Requires catalog agreement and validation. Model notation need not equal wire notation. [Messages](https://a2ui.org/concepts/messages/), [inference formats](https://a2ui.org/concepts/inference-formats/). |
| **Vercel AI SDK** | Developers supply React components; models usually emit tool calls/data selecting them. | Streams message/tool states; application owns CSS and event handlers. Experimental RSC `streamUI` has documented abort, remount/flicker and suspense problems; vendor recommends AI SDK UI for production. [Migration guidance](https://ai-sdk.dev/docs/ai-sdk-rsc/migrating-to-ui). |
| **json-render** | Both; catalog-constrained JSON, root ID and element map, props and child references. | Progressive specs/patches; registered components own styling; named actions/state bindings. Catalog design is application work; schema safety does not guarantee sensible composition. [Project and example](https://json-render.dev/). |
| **Anthropic artifacts** | Models write HTML, React or other artifact code. | Code is generated before/while the artifact becomes available; no verified universal partial-UI grammar. Own CSS and JS interactions; sandbox/platform capabilities constrain execution. [Supported artifacts](https://support.claude.com/en/articles/9487310-what-are-artifacts-and-how-do-i-use-them). |
| **Claude / OpenAI structured outputs** | Both; developer-defined JSON Schema, potentially recursive UI trees. | Constrained generation; token streaming still needs accumulation or a partial parser. Renderer supplies styling and permitted actions. Schema restrictions, refusals/truncation and semantic mistakes remain. [Claude](https://platform.claude.com/docs/en/build-with-claude/structured-outputs), [OpenAI UI example](https://openai.com/index/introducing-structured-outputs-in-the-api/). |
| **Thesys C1 / OpenUI** | C1 generated component JSON. Current documentation redirects toward OpenUI: compact `name = Component(args)` language, developer catalog, model composition. | Line-oriented progressive rendering; registered React components/theme; actions, state and tool queries. Vendor supplies validation/autofix because malformed output remains possible. [Language](https://www.openui.com/docs/openui-lang). |
| **CopilotKit / AG-UI** | Developers register renderers; models emit tool calls, state or a supported declarative UI payload. AG-UI itself is an event protocol, not a layout language. | Streams text, tool and state events; renderer controls themes/actions. A2UI or another format supplies missing layout semantics. [Protocol](https://docs.ag-ui.com/introduction). |
| **Streamlit / Gradio** | Developers or code-generating models; executable Python. Streamlit ordered calls/columns; Gradio Interface or Blocks/Rows/Columns. | Runtime updates, Streamlit write streams or Gradio generator yields; theme settings/CSS; callbacks. Streamlit reruns require state/caching care. Gradio's streaming guide was inaccessible during this check; its exact current constraints remain unverified. [Streamlit](https://docs.streamlit.io/develop/concepts/architecture), [Gradio guide](https://www.gradio.app/guides/streaming-outputs). |

## Concrete notation examples

These representative examples show the range. A system without free layouts cannot faithfully express the requested dashboard; no invented dashboard API is supplied for it.

**Raycast row**, inside a List. Imports omitted:

```tsx
<List.Item icon={Icon.Document} title="Invoice" subtitle="Due Friday"
  actions={<ActionPanel><Action.OpenInBrowser title="Open"
    url="https://example.com/invoice" /></ActionPanel>} />
```

Raycast's standard Detail could show the dashboard's text/table in Markdown, but it has no general three-column stat composition in this catalog.

**Alfred row**. Connect the Script Filter to an Open URL workflow action:

```json
{"items":[{"title":"Invoice","subtitle":"Due Friday",
 "icon":{"path":"invoice.png"},"arg":"https://example.com/invoice"}]}
```

Text View can show the number, a three-column Markdown table and a list, but that remains a document, not native stat cards.

**Adaptive Cards row**, as a body fragment. URL activation applies to the container:

```json
{"type":"Container","selectAction":{"type":"Action.OpenUrl","url":"https://example.com/invoice"},
 "items":[{"type":"ColumnSet","columns":[
  {"type":"Column","width":"auto","items":[{"type":"Image","url":"https://example.com/icon.png","size":"Small"}]},
  {"type":"Column","width":"stretch","items":[
   {"type":"TextBlock","text":"Invoice"},
   {"type":"TextBlock","text":"Due Friday","isSubtle":true}]}]}]}
```

**Adaptive Cards dashboard**, complete payload:

```json
{"type":"AdaptiveCard","version":"1.5","body":[
 {"type":"TextBlock","text":"$12,400","size":"ExtraLarge","weight":"Bolder"},
 {"type":"ColumnSet","columns":[
  {"type":"Column","width":"stretch","items":[{"type":"TextBlock","text":"Orders: 42"}]},
  {"type":"Column","width":"stretch","items":[{"type":"TextBlock","text":"Returns: 2"}]},
  {"type":"Column","width":"stretch","items":[{"type":"TextBlock","text":"Customers: 30"}]}]},
 {"type":"TextBlock","text":"• Invoice A\n• Invoice B","wrap":true}]}
```

**MDX dashboard**. These capitalized components must be defined by the application; they are not built into MDX:

```mdx
# $12,400

<Grid columns={3}>
  <Stat label="Orders" value={42} />
  <Stat label="Returns" value={2} />
  <Stat label="Customers" value={30} />
</Grid>

- Invoice A
- Invoice B
```

The corresponding row could be `<Row icon="document" title="Invoice" subtitle="Due Friday" action="open-invoice" />`, provided the host defines that component and action contract.

**json-render dashboard**, using the demonstration catalog's Metric, Grid, Stack and Text components:

```json
{"root":"page","elements":{
 "page":{"type":"Stack","props":{"direction":"vertical"},"children":["total","stats","list"]},
 "total":{"type":"Metric","props":{"label":"Revenue","value":"$12,400"}},
 "stats":{"type":"Grid","props":{"columns":3},"children":["a","b","c"]},
 "a":{"type":"Metric","props":{"label":"Orders","value":"42"}},
 "b":{"type":"Metric","props":{"label":"Returns","value":"2"}},
 "c":{"type":"Metric","props":{"label":"Customers","value":"30"}},
 "list":{"type":"Text","props":{"text":"Invoice A; Invoice B"}}
}}
```

The last element is deliberately text rather than a fabricated built-in List. A real short list can use a vertical Stack of Text components. A row similarly composes horizontal Stack, Icon, vertical text Stack and Button. An application-defined Row component makes that shorter, at the cost of another catalog entry.

**Executable script**, a Streamlit dashboard:

```python
st.metric("Revenue", "$12,400")
for col, label, value in zip(st.columns(3),
                            ["Orders", "Returns", "Customers"], [42, 2, 30]):
    col.metric(label, value)
st.markdown("- Invoice A\n- Invoice B")
```

A row can use columns, `st.write` and `st.link_button`; the script must execute. HTML can express both examples directly using flex/grid, text and links, but CSS and action code become part of the authoring burden.

## C. Synthesis and evidence

Four families emerge:

1. **Fixed result records and page templates**: Alfred, LaunchBar, ueli and launcher APIs. Short references, low overhead for rows, strong parsing and host styling. Richness needs more templates or a second content grammar. Whole-result replacement is straightforward; partial JSON needs additional framing.
2. **Catalog-constrained composition**: Adaptive Cards, Block Kit, A2UI, json-render, Notion and OpenUI. One structural representation can contain lists and richer content. JSON has mature tooling but repeated keys; compact DSLs reduce repetition while adding a parser and positional signatures. Catalog size determines teachability and flexibility. Themes belong to renderers rather than arbitrary author CSS.
3. **Documents with components**: Markdown extensions, MDX and the previously researched ChatGPT Intelligent UI DIL. Plain content is cheap; custom tags unlock layouts. Mixed grammar and unfinished expressions complicate streaming and sanitization. DIL's exact syntax remains reverse-engineered evidence, not a published stable API; see the earlier research. MDX adds executable JavaScript, a materially larger trust boundary.
4. **Executable UI or embedded app**: SwiftUI, React artifacts, HTML MCP Apps, Streamlit and Gradio. Can express both examples in one programming language, with extensive styling and interaction. Requires runtime isolation, execution and more documentation. A widget selected by tool data does not mean the model describes its layout.

**Who truly uses one notation?** Adaptive Cards, A2UI, json-render and OpenUI compose repeated rows and dashboards from the same catalog. Their “list” need not have launcher selection, ranking or keyboard semantics. Notion does the same for documents. React/SwiftUI/Python can cover both through code. Raycast shares a component API across page types but retains Markdown inside Detail. Alfred and Command Palette explicitly mix representations. MCP Apps unify delivery, not authoring syntax.

**What is reliably cheap for models?** There is no verified universal winner across models and UI tasks. OpenAI's 2024 vendor evaluation reported 100% schema adherence for its constrained model versus under 40% for an earlier model; this measures schema compliance, not layout quality. Claude likewise compiles schemas into generation grammars and documents exceptional termination/refusal cases. Neither proves JSON is cheapest.

More directly, [A2UI's current evaluation](https://a2ui.org/concepts/inference-formats/#token-and-latency-benchmarks) reports 54 tasks with Gemini 3.8 Flash: without thinking, Express used median 297 code tokens versus JSON's 807, with identical 53/54 first-attempt passes. Input tokens also fell from 10,980 to 6,000. This is a small vendor suite, not evidence across all models. [OpenUI's benchmark](https://www.openui.com/docs/openui-lang/benchmarks) compares equivalent representations in seven scenarios and reports substantial savings for positional syntax. It establishes encoding size, not independent model reliability. Its production recommendation to use streaming correction is evidence that a compact grammar still needs validation.

Published evidence therefore supports constrained schemas for syntactic reliability and compact catalog languages for lower encoding cost under measured conditions. Claims that models inherently write XML, Markdown, JSON or JSX most reliably in every setting remain unverified.
