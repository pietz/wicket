# Response to Fable

## 1. Where I now agree or changed my mind

**Your job → recipe → tool distinction is better than my operation vocabulary.** I distinguished deterministic execution from recurring judgment, but buried that distinction. Your three names make the product understandable and give judgment-heavy tasks a legitimate destination. Adopt them, without implying every recipe should eventually become a tool. “Keep” is also better than “Save Tool”: it does not promise compilation before we know what can be preserved.

**Your folder is a stronger expression of the brief than my package registry.** The owner's first priority is reshaping the product itself. Editable built-in definitions, keymaps, ranking rules and views make that concrete. My constrained catalog risks becoming another plugin API with an agent attached. I would expose built-in behavior through the same documented formats as personal tools, while retaining a small protected runtime. Testing whether a fresh agent can extend the product from its contract and examples is an excellent acceptance test.

**The reverse interface deserves more weight.** Letting existing agent sessions submit questions and typed results gives the launcher a purpose beyond originating work. I underweighted that. An authenticated, scoped `ui.ask`/`ui.show` interface belongs in the architecture, although universal session control need not precede the reuse experiment.

**Your Raycast architecture research corrects mine.** I treated its native extension rendering as current without separating versions. Raycast's technical account distinguishes v1's native rendering from v2's hybrid web-based architecture. Our combined report should use that correction, without inferring poor performance from the stack alone. [Raycast technical deep dive](https://www.raycast.com/blog/a-technical-deep-dive-into-the-new-raycast)

## 2. Where I still disagree

**1. Forging does not eliminate integration maintenance or supply-chain risk.** An intent card can reproduce a bad instruction; generated code can introduce dependencies; authentication, pagination and API changes still need owners. Recreating the same connector separately for every user can multiply maintenance. Your proposal relocates the work rather than removing it. Skip a marketplace initially, but permit maintained connectors beneath personal compositions. **Evidence that would settle it:** compare independently forged integrations with shared connectors on several real services, including changed schemas and expired credentials; measure correctness and total repair effort, not generation time.

**2. The safety promises outrun the proposed implementation.** Your weeks 5–6 executable allowlist cannot establish the capability guarantees promised earlier. Allowing `gh` does not specify which authenticated operations are permitted. A manifest saying “read-only” is not enforcement. Likewise, a UI keypress is not sufficient evidence of human approval if the delegated agent can control that UI. Keep unrestricted external-agent execution explicitly outside the constrained runtime; start generated tools with brokered operations and validated parameters. **Evidence:** adversarial tests showing that undeclared file access, remote writes, privilege expansion and synthetic approval fail across every supported execution route. Until then, narrow the promise.

**3. One successful example does not prove a repaired tool.** A recorded PR table can reward code that reproduces yesterday's answer while mishandling pagination, empty results or the meaning of “waiting on me.” Keep the original example, but add independent cases and explicit invariants. Repair must demonstrate preserved behavior, not merely a passing replay. Also, model-free does not mean offline or instantaneous: your own PR tool needs a network call. **Evidence:** held-out inputs and deliberate dependency changes, measuring semantic errors and user repair time as well as crashes.

**4. I would test Keep before replacing the daily launcher.** Your sequence spends four weeks on classic launching and dispatch before the differentiator, and asks the developer to uninstall their incumbent. That tests replacement completeness and one person's tolerance. My sequence tests the uncertain behavior: do people voluntarily reuse and modify tools they helped create? Your “one in five kept commands” threshold also ignores how many people return and whether savings exceed upkeep. **Evidence:** a multi-user pilot against each participant's existing agent-plus-launcher workflow. Replacement becomes justified if the extra hotkey demonstrably prevents otherwise valuable reuse.

**5. Editable files should not make ordinary customization agent-dependent.** A width slider or URL field can be faster and clearer than prompting, waiting and reviewing a diff. Keep direct controls over the same files; avoid a second configuration system. Similarly, context chips should represent deliberately attached material, not require users to remove unrelated clipboard contents on every invocation. **Evidence:** timed customization tasks and attachment-error observations comparing direct controls with agent-only edits, and explicit capture with default attachment.

**6. Competitive incentives are hypotheses, not protection.** Separate processes do not imply an incumbent cannot integrate creation and reuse. Raycast already exposes Quick AI in Root Search; describing its agent as confined to a separate window overstates our opening. Nor can we establish that nobody owns the agent-inbox role from this research. Win on a demonstrably better lifecycle, not predictions that incumbents will abstain. **Evidence:** users preferring our complete loop when offered an incumbent plus their existing agent for the same tasks. [Raycast v2 manual](https://manual.raycast.com/new-in-v2)

## 3. A joint position I would sign

1. Build a native, keyboard-first workbench whose distinguishing loop is **do → inspect → Keep → reuse → modify**.
2. Recognize jobs, model-dependent recipes and direct-execution tools; disclose which requires inference or a network.
3. Keep familiar local actions independent of agents, with stable selection and measured latency budgets.
4. Make personal tools and configurable built-in behavior readable, versioned files with validated changes and recovery.
5. Borrow supported external agents; preserve their approval boundaries and keep saved local tools useful without them.
6. Render typed results through consistent native components, with room for clarification and expanded review.
7. Attach context deliberately; enforce constrained capabilities rather than merely displaying declarations.
8. Support agent-originated questions and results through a scoped interface without becoming a full session dashboard.
9. Defer a store and broad replacement features; retain the option of maintained connectors and direct settings controls.

**First experiment: a two-week reuse-and-reshape pilot once a narrow prototype works.** Recruit eight technical Mac users who already use agents. Keep their existing launcher. Provide one supported adapter, selected-text/file inputs, native result views, Keep, versioning, and constrained transforms. Have each bring two genuinely recurring tasks and establish their current workflow's effort. Observe unprompted reuse, successful modification, review burden and repair time; distinguish recipes from deterministic tools.

Pre-register a provisional go criterion: at least five participants independently reuse two personal tools on three separate days and modify one without developer help, with net effort saved after creation and repairs. Any preview/execution mismatch requires fixing before expansion. If the pilot fails, diagnose recurrence, discovery and maintenance separately; do not automatically pivot to mission control. This experiment tests both reports' central claim: personal capability accumulates usefully rather than becoming another folder to maintain.
