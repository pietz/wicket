# Architecture review

A recurring, independent review of the code against the whole roadmap. The lead runs it; the owner decides anything consequential it surfaces.

## When

- Before each major workstream that touches the core (palette navigation, AI, voice, MCP, custom UI).
- Otherwise every few milestones, or when a builder reports working around the design rather than through it.

## How

- Two reviewers from different providers, in parallel, read-only (currently Claude Fable and GPT Astra, high effort). Different models catch different things; agreement between them is the strongest signal.
- Give them the code and the roadmap, never our conclusions or a hypothesis to confirm. A reviewer handed an answer tends to return it.
- The forcing function is the roadmap: ask what breaks when the coming features land, not whether the code is "clean".
- Demand file and type citations, a ranking by consequence, and a plan in small steps that each keep `Scripts/check.sh` green.
- Ask what to delete or merge, not only what to add.
- The lead merges both reviews into `docs/architecture.md` and the roadmap, records decisions in CONCEPT.md, and brings disagreements on big calls to the owner with a recommendation.

## Prompt

Fill in the "What is coming" list from ROADMAP.md at the time of the review, and name the next workstream.

```
You are an independent architecture reviewer for Wicket, a native macOS launcher (Swift 6,
AppKit + SwiftUI, macOS 26+, SwiftPM, no third-party deps) in <repo path>. READ-ONLY: do not
edit, commit, or run the app or any benchmark script.

Context: the owner wants an architecture flexible and clean enough to sustain everything on the
roadmap without tech debt. Before the next big step (<next workstream>) we pause for this review.

Read first: AGENTS.md, CONCEPT.md, ROADMAP.md, docs/architecture.md (if present),
docs/extensions.md. Then read all of Sources and Tests. Judge the code, not the plan.

What is coming that the architecture must carry:
- <one line per roadmap feature, from ROADMAP.md>

Answer concretely, citing files and types:
1. Core model: are the current primitives right for all of the above? What is missing, wrong,
   or should be renamed or merged? Is the module split right?
2. Where will the code crack first as those features land? Rank by consequence.
3. The minimal target architecture: the handful of concepts and boundaries to lock in now, with
   short Swift signatures. Simplest design that carries the roadmap; no speculative layers.
   Prefer modern Apple APIs.
4. A refactor plan: ordered small steps that each keep Scripts/check.sh green, with size
   estimates, split into "before <next workstream>" and "can wait".
5. Anything in the concept or decisions you would challenge.

Be candid; disagree with the existing design where warranted. Final message: the full review,
under ~1500 words, structured by the five questions.
```
