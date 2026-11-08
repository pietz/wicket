# Spike: harness structured output (2026-11-08)

Spike on branch `t3/ae7ef1d9` (commit 2bf8ea7, scripts and trimmed transcripts in `spikes/structured-output/`, not merged). Verdict: the harness-schema design holds for Claude Code 2.1.319 and Codex 0.167.

Throwaway experiment for the decision "Agent output becomes native UI through one shared vocabulary"
(CONCEPT.md, docs/reviews/2026-11-08-agent-ui.md). Live runs of Claude Code 2.1.319 and Codex
0.167.0, driven by `driver.py` the way `ClaudeTranscript` and `CodexTranscript` drive them. Nothing in
`Sources/` changed.

- `driver.py`: speaks Claude's stream-json (both ways, `--permission-prompt-tool stdio`) and Codex's
  app-server JSON-RPC, answers approvals, logs every line to `runs/<harness>-<name>.jsonl` and a
  summary to `runs/<harness>-<name>.summary.json`. `show.py` prints summaries, `bench.py` the latency table.
- `schema.json`: the test schema. Object root `{"result": anyOf[detail, answer, list]}` with a `type`
  enum discriminator, every key required, optionals as `["string","null"]`, `additionalProperties:false`.
- `schemas/`: variants for the schema-feature probes. `instructions-*.txt`: the appended system prompt / developer instructions.
- Runs used Claude `--model sonnet --effort low`, Codex `gpt-6-luna` low (and `gpt-6.1-terra` low,
  Wicket's default, where noted), in a temp git repo with a few files. The `system/init`, skills,
  account and rate-limit events in the transcripts are trimmed (they listed the owner's setup).

## Flags and params

Claude: `claude -p --output-format stream-json --verbose --include-partial-messages --input-format
stream-json --permission-prompt-tool stdio --model sonnet --effort low --permission-mode
<bypassPermissions|manual> --json-schema '<schema>' [--append-system-prompt …] [--resume <id>]`, prompt
as a `user` stream-json line, `can_use_tool` answered with `control_response`, stdin closed on `result`.
Answer mode (`claude-answer-mode.jsonl`): Wicket's flags (`--safe-mode --tools "" --permission-prompts
none --no-session-persistence …`) plus `--json-schema`, prompt as plain text.

Codex: `codex app-server`; `initialize`, `initialized`, `thread/start {cwd, developerInstructions?}` or
`thread/resume {threadId, cwd, excludeTurns}`, then `turn/start {threadId, input, model, effort,
approvalPolicy, sandboxPolicy, approvalsReviewer:"user", outputSchema}`; approvals answered
`{decision: accept|decline}`. Answer mode: ephemeral read-only thread, Wicket's `features.*=false` overrides.

## Findings

| # | Claude Code 2.1.319 | Codex 0.167 |
|---|---|---|
| 1 Plain question | Works. Parsed object in `result.structured_output`; `result.result` holds the same JSON as a string. The call is a `tool_use` named `StructuredOutput` (input streams as `input_json_delta`), answered by a `tool_result` "Structured output provided successfully". `stop_reason` is `tool_use`, no extra API turn. **Without an instruction Sonnet first writes the answer as prose, gets a synthetic user message `[structured-output-enforce] You MUST call the StructuredOutput tool…` and then repeats it in the tool: double output, +1 to 3 s.** With "do not write prose outside StructuredOutput" in the system prompt it calls the tool directly (`claude-plain-instr`). | Works. Final `agentMessage` (`phase: "final_answer"`) whose `text` is the JSON string; its `item/agentMessage/delta`s stream raw partial JSON. Nothing else marks it as structured. |
| 2 Tool use | Works: Bash `tool_use`/`tool_result` stream first, StructuredOutput last (`claude-tools`, `-tools-instr`). Picks `list` with absolute paths (`/private/tmp/…`, realpath). | Works: `commandExecution` items stream first, the JSON message last. Luna low chose `detail` even with instructions; Terra low chose `list` (`codex-tools-terra`). Paths as `/tmp/…` (not realpath). |
| 3 Approvals | `control_request can_use_tool` (Bash) arrives mid-run in `manual` mode; allow runs it, deny makes the model explain in `detail` (`claude-approve`, `claude-deny`). StructuredOutput itself never asks: `permission_decision {accept, source: config}` even in manual mode. | `item/commandExecution/requestApproval` arrives with `approvalPolicy untrusted` + `workspaceWrite`; accept runs it, decline gives `status: declined` and an `answer` saying so (`codex-approve`, `codex-deny`). With `readOnly` sandbox Luna refused to write without asking (model choice, not schema). |
| 4 Follow Up | `--resume <id>` + `--json-schema` works, same session id, remembers the prior turn (`claude-resume`). History file holds the prose message, the synthetic enforce message, the StructuredOutput `tool_use` (the JSON as tool input), its `tool_result`, then a `<synthetic>` "No response requested." assistant message. **Resuming without `--json-schema` breaks**: the model calls StructuredOutput from habit, gets `No such tool available`, falls back to prose, `structured_output: null` (`claude-resume-noschema`). | `thread/resume` + `outputSchema` works (`codex-resume`). History (`excludeTurns:false`) holds the old final `agentMessage` with the JSON as its text. Schema is per turn: resuming without it gives JSON anyway, by imitation, unenforced (`codex-resume-noschema`). |
| 5 2+2 / refusal | `answer {title:"4", subtitle:null}` with and without instructions. "What is my banking PIN?" gives `detail` with advice. | `answer {title:"4"}`. PIN: `answer` with title "I can't retrieve…". Luna also chose `answer` for a two-sentence explanation (`codex-plain`): needs the instructions and a better model. A model-level safety refusal was not triggered. |
| 6 Failure modes | (a) The model gives up and answers in prose after the enforce nudge: **`subtype: success`, `is_error: false`, no `structured_output` key, prose in `result.result`** (`claude-schema-impossible`). (b) Failed validations go back as `tool_result` errors ("Output does not match required schema: …") and are retried; after `MAX_STRUCTURED_OUTPUT_RETRIES` (default unknown; set to 2 here): `subtype: error_max_structured_output_retries`, `is_error: true`, `errors: ["Failed to provide valid structured output after 2 attempts — …"]` (`claude-retries`). (c) A non-object root schema: `subtype: success`, `is_error: true`, result "API Error: 400 tools.N.custom.input_schema.type: Field required", exit 1. | Constrained decoding: output always matches when the turn completes. Unsatisfiable schema: `turn/completed status: failed`, "Incomplete response returned, reason: max_output_tokens" after ~5 s. Rejected schemas: `turn/completed status: failed` whose `error.message` is the raw OpenAI 400 JSON (after the turn started; `turn/start` itself succeeds). |
| 7 Intermediate prose | Text before tool calls still streams as `text_delta` events of separate messages (`claude-narrate`). The final answer does not stream as text (it is tool input). | `agentMessage` items with `phase: "commentary"` stream as normal prose; the final one is `phase: "final_answer"`. The phase is on `item/started`, so deltas can be routed by `itemId`. |
| 8 Overhead (median of 3, warm) | 2+2: 1.86 s vs 1.86 s, out 70 vs 3 tokens. Tools: 4.13 s vs 3.80 s, out 369 vs 208. Input +1.3k (the tool definition). Cost +$0.001. The first run with a schema pays a cache write (~40k tokens, ~$0.15): the tool set changes the prompt-cache prefix, so mixing schema and no-schema runs costs cache. | 2+2: 3.95 s vs 3.62 s, out 25 vs 5. Tools: 9.7 s vs 7.6 s (noisy), out 218 vs 175. Input +~200 tokens. |
| 9 Schema features | Client-side validation, lenient: `oneOf`, `$defs`/`$ref`, recursion, optional (non-required) keys and missing `additionalProperties` all work. Root must be `type: object` (else API 400). | OpenAI strict: **rejected** `oneOf`, non-required keys, missing `additionalProperties:false`, non-object root. **Accepted** `anyOf`, `$defs`/`$ref`, recursion, `["string","null"]`, `anyOf [string, null]`, `const`. |

## Verdict

The harness-schema design holds for both. Every scenario works: tool use, mid-run approvals, resume,
and both answer and acting modes (`--tools ""` still leaves StructuredOutput). One schema written to
OpenAI strict rules (object root, `anyOf`, everything required, nullable optionals,
`additionalProperties:false`, `$defs` allowed) works unchanged on both.

What the adapters must handle:

- **Claude**
  - Drop `StructuredOutput` from activity and acting: no "Used StructuredOutput" row, no `.acted`.
    Today it is not in `readOnly`, so it would count as acting.
  - Take the answer from `result.structured_output`. `result.result` is the JSON as a string, which
    the current adapter would show raw.
  - Treat `success` with no `structured_output` as the "keep the prose with a notice" failure.
    `error_max_structured_output_retries` is an error that carries no prose.
  - Always tell the model to reply only through StructuredOutput. Otherwise every reply is written
    twice, and the prose streams as text before the screen arrives.
- **Codex**
  - Hold back the deltas of the `final_answer` message (phase from `item/started`) instead of
    streaming them as text. Commentary messages still stream as prose.
  - Parse `item.text` of the final message as JSON.
  - A failed turn's `error.message` can be raw API JSON, so unwrap its inner `message`.
- **Both**
  - Pass the schema on every run, Follow Up included. Claude breaks without it, and Codex only imitates.
  - Ship the screen guidance (when to use list, answer or detail) as instructions, since schema
    descriptions alone didn't steer Luna.
  - Validate the screen in Wicket anyway: decoding guarantees the shape, not the meaning (Luna named
    a wrong file in `codex-tools`).
  - Normalise paths: Claude gives `/private/tmp`, Codex `/tmp`.
  - Optional: both stream the JSON (`input_json_delta`, message deltas), so a partial-JSON parser
    could draw rows as they arrive.
