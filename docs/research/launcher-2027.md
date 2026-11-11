# What an AI-native launcher should be in early 2027 (research, 2026-11-08)

Three researchers (GPT Astra, GPT Sol, Claude Opus; same prompt, web research, no local code) and one Pi comparison (Sol). Input for the owner, not decisions.

## Where all three agree
- **The market:** Raycast has AI extensions, MCP, BYO subscription and "Agents" (renamed presets): powerful but bolted on, a growing taxonomy users must administer. Alfred 6 keeps AI optional. Spotlight in macOS 27 does conversational, cross-app requests (beta) and on-screen awareness: asking from the launcher is becoming the platform baseline. Claude Code and Codex already drive the Mac in the background. Pi's self-extending harness is the strongest idea out there.
- **Top ideas (ranked similarly by all three):**
  1. **The selection is the operand, the app you came from is the destination.** Select, summon, "make this shorter", see a preview, Replace in Mail / Copy. Visible removable context chips. (All three rank this first; the owner paused selected text earlier as "okay, not amazing".)
  2. **One field, predictable execution.** Local results never wait for AI; Return runs the highlighted row; one explicit shortcut always sends the text to the agent (Tab or similar). Never let late inference change the selection under the user's fingers.
  3. **Dismissible jobs that come back as rows.** Escape hides a running agent; the next summon shows "Comparing quotes" / "Needs your approval" / "Ready", searchable; approvals bring the launcher back.
  4. **Hold the summon key to speak.** Tap to type, hold to talk; live transcript into the same field, routed like typed text.
  5. **A successful run becomes a command.** "Keep this" after success; prefer saved instructions, generate code only when needed; review, test, rollback.
- **Don't:** a chat workspace (history sidebar, personas, model pickers in everyday use); continuous screen watching or proactive pop-ups; making ordinary launching depend on AI latency or a subscription; a second brain (own model, memory store or computer-use stack) duplicating the user's agent.
- **Memory:** small, plain-text, editable ("summaries are three bullets").

## Pi vs Wicket (Sol, Pi commit ccbb224)
Wicket already has Pi's central idea, and better controlled activation (sealed revisions, isolated check, per-revision consent, rollback, any language). Pi has the tighter authoring loop: its system prompt maps topics to bundled docs and runnable examples; `/reload` keeps the conversation; new tools are callable in the same session. Cheap things to borrow:
1. **Ship a complete authoring kit:** the app bundles only extensions.md; also bundle extension.schema.json and a few working samples with fixtures, and name their paths in the preamble.
2. **A richer command inventory on demand:** stable ids, descriptions, input modes, folders (today: titles, keywords, ids, capped at 60).
3. **An explicit repair loop:** the agent runs `wicket check`, fixes, repeats until it passes, then says what it tested; `wicket run` documented as the real-environment test.
