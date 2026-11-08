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
