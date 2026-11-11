# OpenAI's Intelligent UI (two GPT-6.1 Terra research passes, 2026-11-08)

**What it is.** "Intelligent UI", in ChatGPT since 2026-10-07 (Chat, not Work or Voice): GPT-6 composes answers from text and a library of native, progressively rendered components (charts, side-by-side comparisons, buttons, forms, calculators). OpenAI says the model was *trained and evaluated* to choose content, layout and interactivity, including plain text when that is enough. Sources: https://openai.com/index/gpt-6-for-everyone/, https://help.openai.com/en/articles/20001598-intelligent-ui-in-chatgpt

**Not published:** the model-facing syntax, catalog or system prompt. No credible leak was found (checked system_prompts_leaks, chatgpt_system_prompt, leaked-system-prompts, GitHub code search).

**Reverse engineering** (OpenUI, third party, https://www.openui.com/blog/how-chatgpt-intelligent-ui-works): the format ("DIL") is Markdown mixed with JSX-like tags, expressions, `{@body …}` JavaScript, conditionals, loops, handlers and `DIL.useState`; about 70 registered native components, 39 seen in captures. Invalid properties are dropped silently.

**Related developer products:** ChatKit widgets (restricted JSX templates with a data schema, hydrated by the server; `Card`, `ListView`, `Badge`, `Row`, `Col`, `Form`, `Button`; typed action payloads treated as untrusted) and the Apps SDK (developer-built app UIs inside ChatGPT). Neither is the model's free output format.

**An older alleged ChatGPT prompt** for search widgets (unverified) has one useful rule: "Generally, you should only use one rich UI element per response, as they are visually prominent."

## For Wicket
- It validates the direction (prose by default, components where they make content clearer, native rendering), not a syntax. DIL is a small programming language; Wicket's fixed semantic catalog is deliberately simpler and safer, and needs no training.
- OpenAI leans on training, which supports keeping our instruction a short brief rather than a rule list (A/B in 2026-11-08-markup-eval.md).
- Worth an A/B next: one sentence of restraint (the smallest useful set of blocks; don't repeat a chart's values in prose), aimed at Claude's habit of adding a caveat callout to about half its replies.
- Keep failures observable to authors (`wicket run` is strict), unlike DIL's silent drops.
