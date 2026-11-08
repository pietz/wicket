# Gallery

Pages written in Wicket's markup ([docs/markup.md](../../docs/markup.md)), as an agent replies or an extension's `detail.markdown` shows them, reached from one command, Gallery (`gallery`):

- **Weather:** a card with columns (a stat beside facts), a titled strip of stats with symbols, a sparkline and a link row.
- **Comparison:** two cards side by side, each a target that opens its store page, with a badge and stats; a Markdown table; a callout.
- **Repo Changes:** a strip of toned stats, a titled timeline and a titled list of file rows (on another Mac they say "Not found", which is a file row's own state).
- **Person:** an answer, a card holding a portrait fetched from the web (under "Show online content") beside facts, prose and link rows.
- **Calendar:** a badge, a timeline with one event that opens a link, and a progress bar.
- **Invoices:** a plain list in sections, under a summary whose stats are markup too.

Each screen is a fixed file in `screens/`, named after its hidden command. Try one with `wicket run . weather`, which also lints the page's markup.
