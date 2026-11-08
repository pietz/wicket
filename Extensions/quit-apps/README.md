# Quit Apps

A `once` list of running apps sorted by memory, with `run` actions to quit or force quit (answered with `reload`, so the list refreshes) and a hidden `app` command that shows a detail view.
`apps.js` is a JXA helper that asks AppKit for the running apps and quits them; quitting needs no extra permission.
Try the error path without quitting anything: `wicket run . quit --args '{"pid": 99999999, "name": "Ghost", "after": "reload"}'`.
