# Quit Apps

A `once` list of running apps sorted by memory, with `run` actions to quit or force quit (answered with `reload`, so the list refreshes) and a hidden `app` command that shows a detail view.
`apps.js` is a JXA helper that asks AppKit for the running apps and quits them; quitting needs no extra permission.
The fixture checks the list's shape and the error paths with a pid that can't exist, so it never quits anything; `wicket check .` runs it.
