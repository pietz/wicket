# Caffeinate

Type `caff 2` and press Return to keep the Mac and its display awake for two hours. Type `caff`, then Tab to fill hours, minutes and seconds. With no duration, or a duration of zero, the Mac stays awake until you turn it off. Running Caffeinate again replaces the current timer.

Inside Caffeinate, hours take the main field and Tab reaches minutes and seconds. The list leads with what you typed, **Keep Awake for 2 h 30 min** until a local time, and shows the current state, **Awake until 17:30** with the time left. Return on the state row runs **Turn Off**. With nothing typed, the state comes first. Hours accept decimals with either mark (`1.5`, `1,5`). Other text shows a hint row.

Caffeinate runs `/usr/bin/caffeinate -d -i [-t seconds]` in its own session, so the timer outlives the request, the panel and Wicket itself. It records the process ID and kernel start time in `WICKET_DATA_DIR` and stops only that process. When the timer ends, the state row disappears.

Hours are a text field so the keyword's argument fills them, because only a text field takes one. Minutes and seconds are number fields. Without a `match` pattern, the root row stays the plain command, and typing starts no process until you open Caffeinate.

For headless use, run `Wicket --extension caffeinate --submitted --fields '{"hours":"2"}'` to start a timer. Use `--submitted --action start` with no fields to keep the Mac awake until you turn it off, and `--submitted --action stop` to turn it off. Without `--submitted`, Caffeinate only reports the state.
