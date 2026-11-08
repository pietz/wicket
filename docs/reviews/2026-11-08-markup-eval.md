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
