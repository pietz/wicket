# Big-picture review before 0.0.11 (GPT-6 Astra, 2026-11-08)

Reviewed at `eacbdd6`, read-only, all 489 tests passing. Verdict: the implementation is substantially cleaner than its documentation; no surviving subsystem of the removed features.

## Fix before release
1. CONCEPT and ROADMAP still state removed or superseded designs as current (MCP and levelled UIs as direction, `repeatable`, protocol 1, `wicket check` linting output, harness-default model and effort, aliases, JSON-RPC sessions, root routing, sandboxed fixture checks, Make jobs, rollback, prompt commands, permission levels). Replace with the current contract; git keeps the history.
2. Calculator: a magnitude-based zeroing threshold erases exact results (`9007199254740991 - 9007199254740990` gives 0).
3. Host markup integration: the agent was not told the catalog (done in M3), agent replies are shown with host authority (`.show` default), and Copy took raw text with tags (fixed in M2).
4. File search misses top-level home entries (`~/Documents`, `~/report.pdf`).

## Fix soon
- FSEvents root-level or rescan events leave edited extensions at their old revision.
- Run serialization holds per Extensions instance; `wicket run` can overlap the app's run on the same data folder.
- A stopped Run Agent skips the review offer and conversation bookkeeping CONCEPT promises.
- Extension item usage is recorded but never ranks anything.
- Two public logs of error descriptions that may hold paths.

## Simplifications
- Merge the forwarding AgentRunner into AnswerStream (30 to 45 lines).
- Delete unused `Screen.text(home:)` (about 50 lines with tests).
- A constructor for hidden action commands in AppRuntime (20 to 30 lines, optional).

## Fine as is
Six-pillar scope matches registrations and settings; migration tests for ignored old keys are useful; links, currency, Finder context, paste-back, settings, updates and the CLI are supporting behaviour worth keeping; sealed revisions, review tokens, the static check and process-tree cleanup are justified; app launching, follow-ups, approvals and voice have no blockers.

## CONCEPT.md outline (100 to 130 lines)
1. Purpose and scope: thesis, the six pillars, supporting behaviour, the freeze.
2. Product principles: native and fast, small core, extensions for the rest, explicit consent, restrained UI.
3. Interaction contract: ranking, invocation, navigation, copy and paste.
4. AI and native replies: one Run Agent, harness-owned permissions, whole messages, the markup catalog, defaults, follow-ups.
5. Extensions and trust: protocol 2, one process per run, static check versus real testing, per-revision approval, secrets, run history.
6. Voice and distribution.
7. Open questions.
Delete the old architecture summary, alpha scope and supersession narratives; mechanisms go to docs/architecture.md, benchmarks to performance docs.
