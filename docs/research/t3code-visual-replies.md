# T3 Code: rich output in assistant replies

Repo: github.com/pingdotgg/t3code, read at HEAD e9e934bb (main) on 2026-11-12.
Paths below are relative to the repo root.

## Headline finding

T3 Code has NO component vocabulary inside the markdown. There is no MDX, no custom tags (`<stat/>`, `<card/>`), no JSON-block
or fenced-language component catalog, and no component prompt. Instead there are two separate mechanisms, both outside the
markdown stream, both rendered as sandboxed iframes between the tool call and the final text:

1. "Visual replies": the agent calls an MCP tool `html_render` with a complete self-contained HTML page (own CSS and JS).
   Client shows it in a borderless sandboxed iframe above the final text reply. On main, on by default.
2. "MCP Apps": any MCP server tool that returns an MCP Apps (ext-apps) UI resource is rendered as an interactive iframe app
   in place of the tool call. Interactive (can call tools, post messages to the thread).

Plain assistant text goes through an ordinary react-markdown-style unified pipeline with a few extras (GitHub alerts,
"Insight" blocks, Codex directives). Components are "write whole HTML", not "write tags".

## 1. How the model is told and what it writes

Syntax: a tool call, not text. `html_render({ html | path, title, height })`, preceded by optional `html_preview({ html | path, width?, appearance? })`
which returns a PNG screenshot, contentHeight and console output so the agent can self-check.

- Tool definitions: `apps/server/src/mcp/toolkits/html/tools.ts:30-112`.
  - `html_render` description, tools.ts:79 (verbatim):
    "Show a finished HTML page (chart, diagram, mockup) inline in this thread, above your final reply. Do not announce or restate the page. Frame fits height to ${HTML_RENDER_MAX_FIT_HEIGHT}px. On mobile, content past the given height scrolls. ${HTML_RENDER_LAYOUT_GUIDE} ${HTML_RENDER_THEME_GUIDE}"
  - params: path? (absolute .html), html? (1..512_000 chars), title (1..200), height (int, 80..2000, "Use the contentHeight from html_preview").
  - `PAGE_RULES`, tools.ts:27-28: "Self-contained: inline <style> and <script>. Local images as absolute paths are inlined. Remote URLs load as-is."
  - html_preview description, tools.ts:31: "Check an HTML page before html_render. Returns PNG, contentHeight, and console output. ${PAGE_RULES} Theme and layout rules are in html_render."
- Prompt guidance injected into the agent's instructions: `packages/provider-core/src/server/orchestrationInstructions.ts:21-25` ("### Visuals and preview"), verbatim:
  "- Answer data with a trend or comparison with a chart and show any visual the user asks for here: pass an HTML file path or inline HTML to `html_preview`, then `html_render`. A screenshot on disk or a text description doesn't show it. Never start a server for it. Page tools write only on user request. Never use them to show results. Asked for an image to post, send or use elsewhere: a `.png` file and its path, never `html_render`."
  Used by ClaudeAdapterV2, Pi, ACP etc. (`T3_CODE_ORCHESTRATION_INSTRUCTIONS`). Whole instruction block is kept under 4,000 bytes per section (Codex truncation), line 4.
- Theme guide, `packages/shared/src/htmlRender.ts:224-230`, verbatim:
  "Use theme CSS variables on :root, not fixed colors: --background, --foreground, --muted, --card, --popover, --secondary, --border, --ring, --primary, --accent, --destructive, --warning, --success, --info, --code-background (most have a matching -foreground; accent, destructive, and warning also have -surface), --chart-1 to --chart-6, --radius, --font-sans, --font-mono. The base sheet sets background, text, and font."
- Layout guide, htmlRender.ts:232-238, verbatim:
  "Frame width is reply width (728px desktop, about 360px phones), on the thread background. Leave html, body, and the outer element with no background color, no outer card, border, banner title, or side padding. This wins over any rule that sets a page background. T3 adds an overridable 8px html gutter for selection rings and shadows. Use fluid widths within it. A box that needs its own background gets 16px padding and var(--radius) corners. Give charts fixed pixel heights. Let content set the height. Do not use vh units or height:100% on html or body. Both are rejected or loop."
- Tool-result message back to the agent, `apps/server/src/mcp/toolkits/html/handlers.ts:81-82`:
  "Shown to the reader above your reply. Don't mention or describe the page; reply with only what it doesn't already say."
- Claude pre-approval: `apps/server/src/orchestration-v2/Adapters/ClaudeAdapterV2.ts:2220` (`mcp__t3-code__html_render` is on the read-only allow list).
- Model sees the tools via a deferred "tool search": `apps/server/src/mcp/toolkits/toolSearch/tools.ts:10`.
- Behavioural evals: `evals/mcp-tool-use/cases/visual-preview.ndjson` (bad pattern: agent served HTML via http.server and opened it in a preview tab; rule: "build a self-contained HTML page, check it with html_preview, then publish it with html_render").

Component catalog: none. The "catalog" is the theme token set above (colours, 6 chart colours, radius, fonts). The model writes arbitrary HTML/CSS/JS (CDN scripts allowed, so Chart.js etc.). Page base sheet, htmlRender.ts:390-395: html padding 8px, background var(--background), font-size 14px, line-height 1.5, focus ring, zoom-in cursor on images.

The user doc (`docs/user/html-renders.md`) describes it as "Visual replies": "Agents can answer with a page instead of only text: a chart, table, diagram, image collage, or mockup."

## 2. Rendering pipeline

### A. html_render pages
- Server `apps/server/src/htmlRender/HtmlRender.ts`: `publish` (~line 495-540) reads source, `rejectViewportHeight` (vh units rejected, line 108-111, 493), inlines local images (only if bytes are really images), injects a bootstrap `<style id="t3-theme">` plus `<script>` into `<head>` via `injectHtmlRenderBootstrap` (htmlRender.ts:449-468; blanks script/style/template/comments first so it can't inject into inert content), writes it as a thread attachment with `-html` id suffix (served as sandboxed text/html), measures page heights at nine widths (320..1144, htmlRender.ts:24) in a pinned headless Chrome for Testing that T3 downloads itself (~120 MB, docs/user/html-renders.md:9).
- Theme is delivered as CSS custom properties from the active app theme (`htmlRenderTheme`, htmlRender.ts:175-222), via URL fragment before first paint and live via `postMessage` `ui/notifications/host-context-changed` (MCP Apps wire format, line 240, 386). Light and dark both supported.
- Client iframe: `apps/web/src/components/chat/HtmlRenderFrame.tsx`, which wraps `HtmlRenderDocument` in `apps/web/src/components/files/BrowserDocumentFrame.tsx:~324-325`: `sandbox="allow-scripts allow-forms"` and comment "Never allow-same-origin: the opaque origin keeps the page out of the app's session." Mobile uses a WebView (`apps/mobile/src/features/threads/HtmlRenderWebView.tsx`). Frame height follows the page via ResizeObserver reporting `ui/notifications/size-changed` (htmlRender.ts:242, 406), capped at 20,000px.
- Row placement: `apps/web/src/components/chat/TimelineAssistantRows.tsx:~331` renders HtmlRenderFrame as its own timeline row above the final message. Not streamed: the page appears when the tool call completes (it is a tool result, not text deltas). Older clients just show an ordinary tool row.
- Safety (from PR #15968 body, by Theo): previews load from a made-up web origin served from memory so file:// is unreachable; all preview traffic through an in-process SOCKS5 proxy that only connects to public IPs (blocks loopback/LAN); navigation/popups/WebRTC locked down; pages cannot open windows or native dialogs; external links open only via host (`ui/open-link`, http(s) only, htmlRender.ts:259-276) after user activation; local images must really be images. Open risk acknowledged in PR: a page can grab keyboard focus and read what you type next; pages can load public CDN URLs even if the provider sandbox blocks network.
- Invalid page handling: errors are tool failures returned to the agent (`handlers.ts:10-23`: FileError, TooLarge, ImagesNotFound, ViewportHeight -> `invalid_request`), so the model retries. No partial/streamed rendering to handle.

### B. Ordinary markdown (assistant text)
- Libraries (`apps/web/package.json:82-86`, `packages/shared/package.json:566-572`): react-markdown ^10.1.0, remark-gfm, remark-math 6.0.0, remark-parse, remark-rehype, remark-breaks, rehype-raw, rehype-sanitize, mdast-util-directive/micromark-extension-directive. No MDX, no Streamdown.
- `packages/shared/src/markdownPipeline.ts`: remark plugins list lines 237-249 (gfm, autolink suffixes, absolute file path links, Windows paths, GitHub alerts, ordered-list numbers, list indentation, codex directives, image line breaks, code meta, link normalisation); rehype lines 336-342: `rehypeRawWhenPresent` (only invokes rehype-raw if raw HTML exists, line 326), image meta, local editor links, then `rehypeSanitize` with `CHAT_MARKDOWN_SANITIZE_SCHEMA` (lines 197-235) = hast-util-sanitize defaultSchema plus data-* attributes (data-alert, code meta, image src variants, Codex artifact props) and extra href protocols (file, t3-citation, t3-context, thread link, local file schemes). So unknown tags such as `<stat .../>` would be stripped by the default tag allow-list (children kept as text); `javascript:` hrefs are removed (tested at markdownPipeline.test.ts:239-262).
- Mapping to React: `apps/web/src/components/chat/markdownRenderer.ts:47-109` (own react-markdown clone: unified -> remark-parse -> plugins -> remark-rehype{allowDangerousHtml} -> rehype plugins -> `toJsxRuntime` with `components`). Leftover `raw` nodes become plain text (line 68-70). Element-to-component map `CHAT_MARKDOWN_COMPONENTS` in `apps/web/src/components/ChatMarkdown.tsx:1032-1735`: h1-h6, div (renders Codex artifact-template card), p, blockquote (GitHub alert styling), ol, li, input (task list), a (file/thread/citation chips), code, img, table, details, pre (code block with diff/shiki, "run shell command" when fence closed).
- Streaming: `ChatMarkdown.tsx:1805-1890`. While `isStreaming`, text is split into blocks (`splitMarkdownBlocks`, `apps/web/src/components/chat/markdownStreamBlocks.ts`), only the last block re-parses, earlier ones cached (`cache={!isStreaming || index < blocks.length-1}`). An incremental parser (`apps/web/src/markdown-incremental.ts:34-98`) caches completed code fences followed by a blank line. Closed vs open fences tracked so unfinished code blocks don't run (ChatMarkdown.tsx:1703, 1722). LRU render cache 500k chars (markdownRenderer.ts:25).
- Special "components" in markdown, all small and inherited from other agents' conventions, not T3 design:
  - GitHub alerts `> [!NOTE|TIP|IMPORTANT|WARNING|CAUTION]` (`packages/shared/src/markdownGithubAlerts.ts:10-40`, styled at ChatMarkdown.tsx:~346+).
  - Claude Code "★ Insight ─────" blocks rewritten to blockquotes with data-alert=insight (`markdownPipeline.ts:536-615`, only when `renderInsights`).
  - Codex directives: `:codex-file-citation[...]{...}`, `:codex-followup`, and leaf `::artifact-template{artifact_kind=...}` (kinds: document, presentation, spreadsheet, site, google-docs, google-slides, google-sheets, image, email, slack) via micromark-extension-directive restricted to those exact names (`packages/shared/src/codexMarkdownDirectives.ts:1-140`, `codexArtifactTemplates.ts:1-12`). Rendered as `CodexArtifactTemplateCard` with an "onUse" callback. This is compat with the Codex app's own output, not a T3 feature the model is taught.
  - Citations `t3-citation:` links, thread links `t3-thread://`.

## 3. Interactivity

- html_render pages: scripts run, forms allowed, so internal interactivity (tabs, sliders, hover, copy buttons; PR #27462 "copy buttons in html_render visuals work") works. The host bridge is minimal and one-way: page -> host only for open-link, open-image (lightbox), size-changed, key shortcuts forwarding (htmlRender.ts:240-246). There is NO way for an html_render page to send a message or action to the agent. User must copy/paste (Theo's video: "copy-as-prompt" buttons).
- MCP Apps (`packages/client-runtime/src/mcpApps/host.ts`; `apps/web/src/components/chat/McpAppFrame.tsx`; `docs/user/html-renders.md:13-19`): full ext-apps host. Methods: `ui/initialize`, `tools/call` (app can call tools on its own server; user is asked first unless tool is read-only, line 243), `ui/message` (post a message into the thread; always asks, line 275), `ui/update-model-context` (line 315: "T3 Code sends the latest note from each app with your next message"), `ui/open-link`, `ui/request-display-mode` (inline/fullscreen/pip), `ui/download-file`, size-changed, teardown. Works for Codex and Claude (Claude Code >= 2.1.301).
- So buttons/forms that talk to the agent exist only in MCP Apps, which are authored by MCP server developers, not by the agent on the fly.

## 4. Design craft / guidance on prose vs components

- Trigger is intent-based in one sentence: use for "data with a trend or comparison" ("chart") and "any visual the user asks for". Tool says: "Do not announce or restate the page", and the tool result says reply with "only what it doesn't already say". Image-for-elsewhere requests must be a .png, not html_render.
- Design rules for the page are mostly layout hygiene (no outer card/banner/background/side padding, transparent page on the thread background, 16px padding + var(--radius) for boxes, fixed chart heights, no vh) plus theme tokens so output follows the user's light/dark/custom theme. No component library, typography scale, or examples are given; model has full freedom.
- A self-check loop is built in: html_preview screenshot + console messages + contentHeight before publishing.
- Frame UX: full-screen with zoom (PRs #17561, #20281, #34067), hover "Open full screen" button, page keeps working after originals deleted, deleted with thread.
- Open PR #35134 (not merged, created 2026-11-12): setting `visualInstructions` to override the built-in visual guidance, because "T3's built-in visual guidance can force an inline HTML render even when a user's publishing workflow calls for a standalone report and a link." Shows the guidance is opinionated and in the system prompt.

## 5. Public discussion

- PR #15968 "feat: agents can show HTML pages inline in threads", by Theo (t3dotgg), merged 2026-10-05, takes over #15916 by Ben Davis (bmdavis419, the "davis7" credited in the tweet). Opening line: "Agents could only answer in markdown, so charts, galleries, and mockups were out of reach. Now an agent can build a self-contained HTML page, check it with screenshots, and publish it inline in the thread, above its final reply." Includes the security review list and "Open decisions". https://github.com/pingdotgg/t3code/pull/15968, original https://github.com/pingdotgg/t3code/pull/15916
- PR #16234 (Theo, closed unmerged, 2026-10-05): proposed making it an opt-in "Visual replies (beta)" setting, noting it "shipped on for everyone ... new and only lightly tested". Rationale for the description design: "The always-on 'Showing visuals' prompt section moved into the html_render description, so no provider adapter has to know about the setting." Not in main: grep finds no `visualReplies` setting. Feature remains on by default in main.
- Theo tweet (via Digg aggregator https://digg.com/ai/qjksolti, secondary, no exact date): "We just shipped in-app visualization capabilities in T3 Code", credits @davis7. Reactions: "game-changer ... render individual components or full pages in chat"; some worry agents hallucinate styles or overcomplicate simple tasks.
- Theo video "Stop letting your agents write Markdown." (2026-05-13, 36 min; summary at https://rosetta.to/u/t3dotgg/stop-letting-your-agents-write-markdown, auto-generated, secondary). Argument: prefers HTML over markdown for large plans/specs/reports; more expressive, readable (tabs/nav), shareable, interactive (sliders, copy-as-prompt/JSON export back to the agent). He mentions CopilotKit (a sponsor) rendering custom React components with typed inputs, calls MDX an "untapped market", says "all roads lead to React", and says he is "considering letting agents return custom HTML UI inside" T3 Code. He lists trade-offs: tokens, noisy diffs, novelty, poor mobile, hosting, hallucinated images. So the shipped design chose raw HTML over typed components/MDX.
- Related issue #21078: Code Mode tool search inconsistently omitted html_preview/html_render (a discoverability problem of the tool-based approach).
- Other: Mintlify-hosted and community docs exist but I did not find anything describing components.

## What I checked and did not find

- grep over apps/ packages/ docs/ for generative ui, genui, json-render, a2ui, mcp-ui, MDX, Streamdown, custom tag registries, "components" prompt text: no hits beyond the above. No MDX/Streamdown dependency in any package.json (`apps/web`, `apps/mobile`, `packages/shared`).
- No branch/fork examined; shallow clone only (main). The feature lives in main (merged #15968). PR history/git log not available locally (depth 1), used `gh` for PRs.
- `git log -S` unavailable at depth 1; no tweets fetched from X directly (only the Digg mirror).

## Take-aways for a cmark + custom-tags design (my reading)

- T3 trades safety and uniformity for freedom: whole sandboxed HTML page per visual, theme via CSS variables, self-check screenshot loop. No cross-agent component schema, no streaming of UI, no actions back to the agent (except MCP Apps).
- Cheap ideas that are portable: (1) a fixed token vocabulary (`--chart-1..6`, `--success/--warning/--info`, `-surface` variants) that the model is told to use instead of colours; (2) prompt trigger rule "data with a trend or comparison -> chart; visual asked -> visual; image for elsewhere -> file"; (3) "don't restate the visual in text" instruction plus a tool-result hint; (4) fall back gracefully: unknown tags are stripped, children kept (sanitize), leftover raw HTML shown as text; (5) per-block streaming cache with fence-aware incremental parse.
