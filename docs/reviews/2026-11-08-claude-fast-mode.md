# Claude Code fast mode (GPT-6.1 Terra, 2026-11-08)

Question: why can't Settings ▸ AI set Claude's speed?

- Claude Code's `initialize` reports `supportsFastMode` per model: only Opus 5.5, Opus 5 and Opus 4.8 (fast mode on 4.8 ends 2026-11-30). Sonnet, Wicket's default for Claude, and Haiku have none, so the picker is disabled there by design (`AIPane`), and it resets Fast when a model without it is picked.
- Wicket already passes the opt-in headless mode needs: `--settings '{"fastMode":true}'` (`ClaudeTranscript`). With it, `initialize` reports `fast_mode_state: on`; without, `off` with `sdk_opt_in_required`. Requires Claude Code 2.1.205 or later (tested 2.1.319).
- Two live Opus calls with the opt-in still reported `usage.speed: "standard"`; Anthropic documents falling back to standard on availability and rate limits. End-to-end fast inference is unconfirmed on this account.
- Cost: on subscriptions fast mode draws from separately enabled usage credits, not the plan (Opus 5.5 fast: $8 / $40 per million input / output tokens). Settings ▸ AI's footer now says so, and says Fast is only on Opus.

Source: https://code.claude.com/docs/en/fast-mode
