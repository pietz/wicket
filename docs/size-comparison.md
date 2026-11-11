# Wicket source size comparison

A snapshot from 10 Nov 2026, kept as the analysis it was. OLD is the 0.0.x line (0.0.15); NEW is the rewrite as of commit `b702f1a`, which became 0.1. Since then NEW dropped its ACP adapters for direct `claude` and `codex` protocols, removed extension fingerprint approval, added voice on open, settings and release machinery, and grew from 4,702 to about 6,600 source lines (see [COMPARISON.md](../COMPARISON.md)). Paths and line ranges below refer to those two trees, not to the current one.

NEW has 4,702 source lines versus OLD's 18,970, a 4.03:1 ratio.
The 14,268-line gap mostly reflects changed architecture and omitted product scope, not proven redundant code.
A rough allocation is 8,650 lines of design changes, 4,320 of missing scope, and 1,298 potentially compressible in place.
That last number is an investigation allowance, not a demonstrated safe deletion or a measured failure of previous reviews.
Restoring comparable scope might put NEW around 7,200–9,700 lines, making the ratio roughly 2.6:1 to 2.0:1.

## Physical lines by area

Counts include blank lines, comments and every file below `Sources/`, including NEW's CSS, JavaScript and example resources. OLD is the checked-out tree; NEW is commit `b702f1a`, not its concurrently edited working files. Each whole file appears once, assigned by its primary job. Cross-cutting files make boundaries approximate; for example, panel composition also implements navigation, and infrastructure includes NEW's CLI. Ratios mean OLD divided by NEW. Tests, dependencies and generated files are excluded.

| Area | OLD | NEW | OLD / NEW |
| --- | ---: | ---: | ---: |
| Answer rendering | 3,850 | 402 | 9.58 |
| Math | 1,335 | 116 | 11.51 |
| Agent connection and sessions | 1,692 | 714 | 2.37 |
| Extensions, execution and trust | 3,202 | 538 | 5.95 |
| Voice | 596 | 304 | 1.96 |
| App indexing, matching and usage | 462 | 385 | 1.20 |
| Settings and management | 1,104 | 110 | 10.04 |
| Panel, views and hotkey | 2,785 | 1,426 | 1.95 |
| Command model and navigation | 2,348 | 149 | 15.76 |
| File search, shell and updates | 614 | 0 | — |
| Processes, diagnostics and infrastructure | 671 | 546 | 1.23 |
| Other: context, CLI, chord, entry | 311 | 12 | 25.92 |
| **Total** | **18,970** | **4,702** | **4.03** |

## Estimated attribution of the gap

These are **net gap allocations**, not counts of individually proven removable lines. Mixed files were apportioned by judgment; code moved across table rows stays in its original file's row. The categories are mutually exclusive for arithmetic, but actual changes interact. Treat individual allocations as rough, often uncertain by hundreds of lines. NEW-only functionality offsets OLD lines within the same row, so the table does not claim that these are gross implementations of each feature.

| Area | A: scope absent | B: design | C: possible in-place | Net gap |
| --- | ---: | ---: | ---: | ---: |
| Answer rendering | 250 | 3,100 | 98 | 3,448 |
| Math | 1,000 | 150 | 69 | 1,219 |
| Agent sessions | 0 | 850 | 128 | 978 |
| Extensions and trust | 850 | 1,600 | 214 | 2,664 |
| Voice | 220 | 0 | 72 | 292 |
| Apps and matching | 0 | 0 | 77 | 77 |
| Settings and management | 850 | 50 | 94 | 994 |
| Panel and UI | 300 | 850 | 209 | 1,359 |
| Command and navigation | 100 | 1,900 | 199 | 2,199 |
| File search, shell and updates | 550 | 0 | 64 | 614 |
| Infrastructure | 100 | 0 | 25 | 125 |
| Other | 100 | 150 | 49 | 299 |
| **Total** | **4,320** | **8,650** | **1,298** | **14,268** |

**A:** Missing scope includes file search, explicit shell commands, Sparkle updates, currencies and much of unit math, extension secrets, run history, dedicated repair, management and settings windows, voice-on-open, and some rich component families. Some code for these features is embedded in shared files. Not all of the estimate is separable deletion.

**B:** OLD draws validated native components and owns the scanner, builder and views. NEW uses cmark, WebKit and CSS. OLD has separate Claude and Codex wire integrations; NEW delegates to ACP adapters. OLD keeps sealed extension revisions and a coordinator; NEW reviews fingerprints and runs verified disposable copies. OLD has a general command/frame/action model; NEW uses a smaller provider contract and direct composition. These are changes in dependencies, behaviour and tradeoffs, not evidence of redundant lines. None requires a fresh repository in principle.

**C:** The 1,298 lines are a speculative upper-middle working estimate for simplification under OLD's architecture and retained scope, not a line-by-line proof. Some could turn out to implement required edge cases; some savings might be found elsewhere. A credible safe range is perhaps **500–1,500**, pending an actual refactor and regression tests. The examples below show candidates and their limits, not a demonstrated 1,298-line patch.

**D:** Near-unchanged ports contribute no meaningful net savings: OLD `Sources/WicketCore/FuzzyMatcher.swift:1–134` versus NEW `Sources/WicketCore/FuzzyMatcher.swift:1–135`, and both `Sources/WicketCore/UsageStore.swift:1–55`. App scanning, process-tree handling and transcription are also substantial ports with changes. They belong in neither A, B nor C merely because they are long.

## Concrete comparisons

Paths below are relative to the respective repository. Line ranges in NEW refer to `b702f1a`.

- **Markup, architectural replacement:** OLD `Sources/WicketCore/Markup/Scanner.swift:61–126,304–390` and `Builder.swift:44–201`, followed by `Sources/WicketApp/Markup/DocumentView.swift:1–289`, scan, validate and render native document structures. NEW `Sources/WicketCore/AnswerMarkdown.swift:6–124`, `Sources/WicketApp/AnswerRenderer.swift:1–176` and `Resources/answers.css:1–73` delegate parsing and display. This saves thousands but changes rendering, supported components and dependencies. It is not ordinary code compression.
- **Extension approval, architectural replacement:** OLD `Sources/WicketHost/RevisionStore.swift:44–142` seals and retains revisions, with `Extensions.swift:55–110,150–234` coordinating active revisions and runs. NEW `Sources/WicketApp/ExtensionHost.swift:18–49,95–128` fingerprints and verifies disposable copies. Both review before execution, but revision management and lifecycle guarantees differ.
- **Voice session, candidate for local simplification:** OLD `Sources/WicketApp/Voice.swift:112–160` and NEW `Sources/WicketApp/VoiceInput.swift:35–74` manage transcription, cancellation and timeouts in similar ways. OLD additionally supports armed-on-open and timing/logging. Only the overlapping state handling is a compression candidate; the difference in lines is not all waste.
- **Hotkey, smaller policy with an omitted feature:** OLD `Sources/WicketApp/PaletteHotKey.swift:13–57` and NEW `Sources/WicketApp/PaletteHotKey.swift:5–21` replace registrations while preserving a usable shortcut on failure. OLD also pauses registration for its settings recorder and exposes status. The overlapping registration logic merits review, but deleting recorder support would be scope loss.
- **Index and ranking, mixed change:** OLD `Sources/WicketCore/SearchIndex.swift:1–46` plus `Ranker.swift:24–57` and NEW `Sources/WicketCore/Ranking.swift:4–39` index and order results. NEW combines responsibilities, but changes priority, usage and tie-breaking. This is a possible local consolidation only if OLD's ordering remains tested; the line difference cannot be claimed as pure C.

These comparisons do not establish three independent, behaviour-preserving C savings of known size. A genuine proof would require implementing and testing them. It would be misleading to label architecture or omitted behaviour as that proof.

## Fairness and parity

NEW adds streaming answers, configurable provider ordering and triggers, editable answer CSS and query-specific usage. It also uses external ACP adapters and cmark: their implementation lines are excluded, so this compares owned source, not total code executed. OLD already uses external agent harnesses and Apple frameworks. NEW's basic arithmetic and example unit converter are not OLD's broad calculator. Its simpler trust flow still verifies copied code, but does not offer OLD's revision/history management.

NEW's `ExtensionHost.swift:49` silently starts an empty approval ledger if reading or decoding fails, and `:77` treats an unreadable extension directory as empty. Those fallbacks deserve review, though they are not proof of an exploitable failure. The rewrite's spec records hands-on gaps including physical hotkeys, input methods, accessibility, WebKit scrolling/selection and sustained memory return. It reports a prototype rising from 95 MB to 178 MB after using WebKit. Voice is counted at the specified commit; ongoing uncommitted voice edits are excluded. No app was launched for this report.

Restoring OLD's missing features plausibly adds **2,500–5,000** owned source lines to NEW: roughly 700–1,300 for math, 600–1,200 for settings and voice options, 500–1,100 for extension history/secrets/repair, and 700–1,400 for file search, shell, updates and missing answer features. These ranges overlap in implementation and are estimates, not a build plan. NEW would then be **7,202–9,702 lines**, or OLD about **2.6–2.0 times** its size. Equivalent compatibility, polish and accessibility could shift that range; preserving OLD's exact native renderer would shift it substantially higher.

## Verdict on the hypothesis

The evidence does not establish that LLMs are intrinsically poor at compressing existing code. It shows that a narrow review preserving OLD's architecture and scope could not honestly deliver most of this gap. OLD's own `AGENTS.md` forbids WebViews and unneeded dependencies; that rules out the largest NEW saving until the owner changes the design constraint. Even the 500–1,500 estimate is not proven removable. Prior review prompts, findings and full diffs were not independently audited here, so their quality cannot be judged.

History shows both accumulation and replacement. Commit `143d22c` introduced a large scanner, builder and component model; `90cd7a7` added native component views and image loading. `64aaaf0` extended the scanner to diagnose prose tags. Conversely, `fccb80d` removed a 710-line extension session when replacing its protocol, and `7dba516` folded screen frames into frames, with 233 deletions versus 157 insertions. This is not simply a story of agents always layering and never deleting.

To find the larger savings in place, commission a whole-system redesign with explicit permission to change the renderer, agent protocol, extension trust model and product scope. Set a measured size and parity target, inventory dependencies and behaviours, prototype alternatives, delete superseded paths, and run parity and platform checks. A conventional cleanup review should instead be judged on demonstrated safe changes, not on whether it reproduces a rewrite with different constraints.

## Owner's response, and a correction to the verdict

The owner's reviews of OLD did ask what could be removed or replaced. The agents answered only within the existing design: none proposed replacing the two agent integrations with one protocol, or the native renderer with a web view, and none flagged that the `AGENTS.md` ban on web views and dependencies was itself the most expensive line in the repository. So the hypothesis needs restating rather than rejecting. Agents are not poor at compressing code. In this case they were poor at questioning a design they had been shown: reading the code first made every part look like a requirement, and written rules were obeyed instead of priced.

What produced the smaller design here was the order of work: describe the product from first principles, design it with no access to the old code, then compare the result against what exists. The differences are the list a review should have produced.
