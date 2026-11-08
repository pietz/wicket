# Reply markup on real agents (2026-11-08)

Does the agent use Wicket's tags well once it is told about them? 14 prompts went through Run Agent's real path (`AnswerStream`, the CLI adapters, the bundled rules plus `Markup.agentReference()`), on the default models of Claude Code 2.1.319 and Codex 0.167, with the user's own configuration. Each page the palette would draw was parsed as the palette parses it and linted as `wicket run` lints an extension (`Markup.lint`: any issue counts). Rerun with `WICKET_EVAL_MARKUP=claude,codex WICKET_EVAL_OUT=<file> swift test --filter replyMarkupEvaluation`.

Prompts: four that need no tags (capital of Australia, days in a leap year, git rebase in two sentences, "good morning" in Japanese) and ten that may use them (Swift vs Rust for a CLI, two phones compared, EU populations, six months of revenue, weather in Berlin, free disk space, SSH key setup step by step, the newest files in Downloads, reading JSON in Python, the crewed Apollo missions).

## Results

| Round | CLI | Zero strict problems | Tags on a no-tag prompt | `<answer>` on a no-tag prompt | Tagged replies to the other ten | Largest reply |
|---|---|---|---|---|---|---|
| 1 | Claude Code | 14/14 | 0 | 3 | 5 | 2005 B, 5 blocks |
| 1 | Codex | 14/14 | 0 | 0 | 5 | 2125 B, 3 blocks |
| 2 | Claude Code | 14/14 | 0 | 3 | 5 | 2255 B, 5 blocks |
| 2 | Codex | 14/14 | 0 | 3 | 4 | 2180 B, 3 blocks |
| 3 | Claude Code | 14/14 | 0 | 3 | 5 | 1912 B, 4 blocks |
| 3 | Codex | 14/14 | 0 | 3 | 5 | 2058 B, 4 blocks |

84 of 84 replies had no strict problem; none used a component other than `<answer>` where none was wanted. Rounds 2 and 3 use the final wording. Components seen: `<chart>` (revenue), `<stat>`, `<fact>`, `<file>` rows (Downloads), `<event>` timelines (Apollo), `<answer>` (short values, weather, disk space). Comparisons came as Markdown tables on both CLIs, never `<columns>` or `<card>`; that reads well in the panel and isn't a problem. Median time to answer: 6 s Claude Code, 7 to 9 s Codex.

## Wording changes

- Round 1: "Write plain Markdown first … use them only where they genuinely help: numbers to compare, a few items with a picture, files or pages to open, steps at times. A reply that is a sentence or two, an explanation or a how-to stays plain Markdown." Claude Code still answered the short questions with `<answer>` (whose catalog entry invites exactly that) while Codex wrote plain text, and Claude Code listed the Downloads files by name in a numbered list, not as `<file>` rows.
- Round 2 made both explicit: "A direct question whose answer is one value (a name, a number, a time) is best answered by `<answer>` alone; other short replies are plain text", and "Files and folders you list for the user are `<file>` rows with absolute paths, never names or paths in prose; pages to open are `<url>` rows." Both CLIs then behaved alike on both, and round 3 confirmed it.
- The reference listed "Adjacent rows (file, url, item) form a list." three times and repeated every grouping in the table; each grouping is now said once.

## Notable failures

None against the lint. Worth knowing:

- Codex's working messages ("I'll check the current conditions in Berlin.") open the page, since a run shows each whole message before the answer. That is the design (whole messages), not the reply wording.
- Codex's weather reply was plain text in round 2 and `<answer>` in rounds 1 and 3: a one-sample-per-prompt evaluation shows tendencies, not rates.

## Size

The largest reply was 2255 bytes in 5 blocks, far under the 8 KiB where the eager `DocumentView` layout would start to matter (a 64 KiB page takes about 470 ms), so the view is unchanged.

## Structure becomes components (later the same day)

The owner saw agents in real use rarely draw components: told "write plain Markdown first … use them only where they genuinely help", they wrote tables and bullet lists. The guidance now says the opposite, as concrete lines: key numbers become `<stat>`s, two or three things compared become `<card>`s in `<columns>` (a table only for many rows or attributes), facts about one subject `<fact>`s, files and pages rows, what changed and a day's events a `<timeline>`, series a `<chart>`, status `<badge>`s, fullness `<progress>`, a warning a `<callout>`; plain Markdown stays for explanations, how-tos with code and conversation, and one value is `<answer>` alone. One short comparison example follows (`agentExampleIsClean` keeps it clean markup). The reference grew from 3687 to 4497 bytes, about 200 tokens.

The evaluation now has 18 prompts: 8 plain (the four short ones, a brief HTTPS explanation, "thanks, that worked", the SSH and Python how-tos with code) and 10 structured, each with the components that fit it (iPhone 17 vs Pixel 11, EU populations, a signup funnel's numbers, the revenue trend, today's calendar, what changed today in a fresh git repository with five commits, disk usage, Hamburg's weather tomorrow, the newest Downloads, the Apollo timeline). Targets: every reply strictly clean, at least 80% of structured prompts with a fitting component, at most 1 in 10 plain prompts with tags other than `<answer>`. Default models (Claude Code `sonnet`, Codex `gpt-6.1-terra`).

| Round | CLI | Zero strict problems | Structured with a fitting component | Plain with tags | Median time |
|---|---|---|---|---|---|
| 1 | Claude Code | 17/18 | 9/10 | 0/8 | 5.9 s |
| 1 | Codex | 18/18 | 9/10 | 0/8 | 7.7 s |
| 2 | Claude Code | 18/18 | 10/10 | 0/8 | 5.8 s |
| 2 | Codex | 18/18 | 8/10 | 0/8 | 7.7 s |
| 3 | Claude Code | 18/18 | 10/10 | 0/8 | 5.3 s |
| 3 | Codex | 18/18 | 9/10 | 0/8 | 8.0 s |

Round 3 is the final wording. Comparisons now come as cards in columns on both CLIs (facts per side, sometimes a stat), numbers as stat strips with tones and charts, disk usage as `<progress>` or stats with the biggest folders as `<file>` rows, the repository's commits as a timeline (Claude Code). Plain prompts got no component in any round; short values kept getting `<answer>`.

Wording changes:

- Round 1 to 2: Claude Code wrote "Hi `<username>`!" in prose (an unknown tag, the only strict problem in all rounds), so a placeholder now goes in backticks; it put its sources in a prose line, so "Sources and pages: `<url>` rows"; Codex summarized today's commits as bullets, so the timeline line names commits first.
- Round 2 to 3: the timeline line starts "What changed (commits, edits)". Codex still answered the repository prompt with prose and bullets in all three rounds; it summarizes what the commits did rather than listing them, which reads fine but misses the timeline.

Notable failures and caveats:

- The calendar was empty that Sunday: Claude Code answered with `<answer>` "Nothing today" in round 1 and a `<callout>` after, Codex with a plain sentence in round 2 and a `<callout>` in rounds 1 and 3. Neither invented events. The prompt can't test a full day's timeline on an empty calendar.
- Callouts are the most common extra: Claude Code adds one for caveats (price sources, conversion rates) in about half the structured replies. They read well, but a long one is a paragraph in a box.
- Codex still opens replies with its working message ("I'll check tomorrow's forecast for Hamburg."), as before.
- One sample per prompt per round: the rates are tendencies.

## Rules or a picture: an A/B comparison (later the same day)

The owner prefers an intuitive brief to a list of "when X, use Y" rules, so the two were compared on the 18 prompts above, in the same conditions on the same evening: two rounds per variant per CLI, default models (Claude Code `sonnet`, Codex `gpt-6.1-terra`), rounds run A, B, A, B. `WICKET_EVAL_GUIDANCE=<file>` swaps the guidance part of the reference (`Markup.guidance`: everything before "Syntax:"); the syntax rules, the tag table with its "Use when" column, the limits and the comparison example are the same in both. Prompt bytes are the whole generated reference.

| Variant | Round | CLI | Zero strict problems | Structured with a fitting component | Plain with tags | Median time | Prompt bytes |
|---|---|---|---|---|---|---|---|
| A, rules | 1 | Claude Code | 18/18 | 9/10 | 0/8 | 6.3 s | 4497 |
| A, rules | 1 | Codex | 18/18 | 8/10 | 0/8 | 8.3 s | 4497 |
| A, rules | 2 | Claude Code | 18/18 | 10/10 | 0/8 | 6.1 s | 4497 |
| A, rules | 2 | Codex | 18/18 | 6/10 | 0/8 | 7.8 s | 4497 |
| B, picture | 1 | Claude Code | 18/18 | 8/10 | 0/8 | 6.2 s | 4044 |
| B, picture | 1 | Codex | 18/18 | 8/10 | 0/8 | 7.0 s | 4044 |
| B, picture | 2 | Claude Code | 18/18 | 10/10 | 0/8 | 6.1 s | 4044 |
| B, picture | 2 | Codex | 18/18 | 7/10 | 0/8 | 6.6 s | 4044 |

Totals: A 72/72 clean, 33/40 fitting (83%), 0/32 plain with tags; B 72/72 clean, 33/40 fitting (83%), 0/32 plain with tags. Both variants answered the same three short questions with `<answer>` in every run.

Per structured prompt, the components each reply used (✓ fitting, ✗ not; `<answer>` left out):

| Prompt | CLI | A round 1 | A round 2 | B round 1 | B round 2 |
|---|---|---|---|---|---|
| phones | Claude Code | ✓ columns | ✓ columns, callout, rows | ✓ columns | ✓ callout, columns, rows |
| eu-population | Claude Code | ✓ stats | ✓ facts | ✓ chart | ✓ chart |
| funnel | Claude Code | ✓ stats, facts, callout | ✓ stats, facts, callout | ✓ stats, callout | ✓ columns, stats, facts, callout |
| revenue | Claude Code | ✓ stats, chart | ✓ chart, stats | ✓ stats, chart | ✓ stats, chart |
| calendar | Claude Code | ✗ prose | ✓ callout | ✗ prose | ✓ callout |
| repo | Claude Code | ✓ timeline | ✓ timeline | ✓ rows | ✓ rows |
| disk | Claude Code | ✓ progress, stats | ✓ progress, stats | ✗ columns, callout | ✓ progress, stats |
| weather | Claude Code | ✓ facts | ✓ stats | ✓ stats | ✓ columns |
| downloads | Claude Code | ✓ rows | ✓ rows | ✓ rows | ✓ rows |
| apollo | Claude Code | ✓ timeline | ✓ timeline | ✓ timeline | ✓ timeline |
| phones | Codex | ✓ columns, rows | ✓ columns, rows | ✓ columns, rows | ✓ columns |
| eu-population | Codex | ✓ facts, rows | ✓ facts, rows | ✓ facts | ✓ facts, rows |
| funnel | Codex | ✓ stats | ✗ columns | ✓ stats | ✓ stats |
| revenue | Codex | ✓ chart | ✓ chart, stats | ✓ chart | ✓ chart |
| calendar | Codex | ✗ prose | ✗ prose | ✗ prose | ✗ prose |
| repo | Codex | ✗ prose | ✗ prose | ✗ prose | ✗ prose |
| disk | Codex | ✓ stats | ✓ stats | ✓ stats | ✓ stats |
| weather | Codex | ✓ stats | ✗ `<answer>` only | ✓ stats | ✗ `<answer>` only |
| downloads | Codex | ✓ rows | ✓ rows | ✓ rows | ✓ rows |
| apollo | Codex | ✓ timeline | ✓ timeline, rows | ✓ timeline, rows | ✓ timeline, rows |

The misses are the same kind under both: the empty Sunday calendar answered in a sentence or `<answer>`, Codex summarizing the repository's commits in prose, Codex's weather as one `<answer>` "Cloudy, 4–8°C". B's two differences are mild: Claude Code listed the commits as `<item>` rows rather than a timeline (it still fits), and once answered disk usage with two cards of folder sizes as stats and facts instead of `<progress>`. Downloads came as `<file>` rows under both, and no placeholder escaped into prose, so no rule from A was worth adding back (no variant C).

**Decision: B.** It ties A on every metric with 453 fewer bytes (about 110 tokens), and the owner prefers the intuitive brief. The tag table's "Use when" column stays as it is: it is shared with docs/markup.md and carries the per-tag facts the brief leaves out.

Variant A, the rules (before the shared example):

```markdown
Wicket draws the tags below natively, and they beat Markdown wherever content has structure, so turn structure into tags:

- Key numbers: `<stat>`s, with `tone` for good or bad.
- Two or three things compared: a `<card>` each in `<columns>`, with stats or facts inside. A Markdown table only for many rows or attributes.
- Facts about one subject (specs, settings, a forecast): `<fact>`s.
- Files and folders: `<file>` rows with absolute paths, never paths in prose. Sources and pages: `<url>` rows. Other things to open or pick: `<item>` rows.
- What changed (commits, edits), a day's events, history: a `<timeline>` of `<event>`s with times. A series of numbers: a `<chart>`. Status: `<badge>`s. How full or far along: `<progress>`. A warning or tip: a `<callout>`.
- Plain Markdown stays for an explanation, a how-to with code and a conversational reply. A question whose answer is one value (a name, a number, a time) gets `<answer>` alone.
```

Variant B, the picture (adopted; before the shared example):

```markdown
Wicket draws your reply as a native page in a small launcher panel, so shape it the way a well-designed card or dashboard would: wherever the content has a shape, write the tag that draws it instead of Markdown. Numbers then read at a glance, things compared sit side by side, events line up in time, and files and pages become rows the user can open. Where there is no shape (a single value, an explanation, a how-to, a thank-you), the reply stays prose; a single value is `<answer>` alone.
```
