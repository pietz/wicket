# Feature opportunities by impact and effort (GPT-6.1 Sol, 2026-11-08)

**Finding:** the best opportunities are extensions, not built-ins. The current protocol (live input plus a `run` action, `args` for drill-down, several manifest commands for root-searchable entries, lists and markup pages) already covers most cheap features. Clipboard history and system-wide snippet expansion are the exceptions. Impact is an informed estimate, not measured demand.

| # | Feature | Impact | How | Effort | Verdict |
|---:|---|---|---|---|---|
| 1 | Searchable snippets | High | Extension today (list, search, paste; Markdown files) | 80 to 180 lines | Do soon, public repo |
| 2 | Quicklinks and URL templates | High | Extension today | 50 to 150 | Do soon |
| 3 | Emoji and symbols | High | Extension today, with keyword data | 80 to 180 plus data | Do soon |
| 4 | Time zones and date arithmetic | Medium | Extension today (live) | 100 to 220 | Do soon |
| 5 | Browser bookmarks (one browser first) | High | Extension today | 150 to 350 | Do soon |
| 6 | System commands, app control | Medium | Existing samples | 20 to 100 each | Promote samples |
| 7 | Paste as plain text, text transforms | Medium | Extension (`pbpaste`, transform, paste) | 30 to 120 | Extension |
| 8 | GitHub PRs and issues | Medium (high for developers) | Existing sample | 100 to 250 | Extension |
| 9 | Dictionary | Medium | Extension (`dict://` or a helper) | 10 to 100 | Extension |
| 10 | Notes and task capture | Medium | Extension (live input, save action) | 80 to 200 | Extension |
| 11 | Apple Shortcuts launcher | Medium | Extension (`shortcuts run`) | 40 to 100 | Extension |
| 12 | Calendar agenda, join meeting | High for meeting-heavy users | Extension (Calendar scripting) | 180 to 400 | After simpler ones |
| 13 | Folder browsing | Medium | Extension (file rows, hidden `run`) | 100 to 220 | Extension |
| 14 | Window placement | High | Extension with an Accessibility helper | 300 to 800+ | Later |
| 15 | Clipboard history | High | Native capture and store, extension search | 600 to 1,200 host lines | Later, a scope decision (Tahoe's Spotlight already has one) |
| 16 | System-wide snippet expansion | High for existing users | Resident host integration | 1,000 to 2,500+ | Later |
| 17 | Empty-query favourites | Medium | Native | 150 to 350 | Later (frozen) |
| 18 | Per-command global hotkeys | High for power users | Native | 200 to 500 | Never under current scope (owner removed) |
| 19 | Another launcher's extension runtime | Low | Large native adapter | Thousands | Never |

```text
                    LOW EFFORT                     HIGH EFFORT
HIGH IMPACT         snippets, quicklinks, emoji,   clipboard history, window management,
                    bookmarks                      snippet expansion, calendar
MEDIUM/LOW IMPACT   time zones, dictionary, plain- another launcher's runtime
                    text paste, notes, system
                    commands, GitHub
```

**Three small protocol or host additions** that would help the most extensions, none needed before the extensions themselves show the limit:
1. Prefilled, optionally multiline text input with submit (200 to 450 lines).
2. The app captured at summon (pid, bundle id) in the invocation context (50 to 120 lines).
3. Opt-in interval runs of one-shot commands, keeping approval, timeouts and serialization (300 to 700 lines). Not a clipboard-history answer.

**Next five:** snippets, quicklinks, emoji, time zones, single-browser bookmarks, as the first extensions of a public repository beside the existing GitHub, system-toggles and quit-apps samples. Folders, docs and manual install through Review and Enable first; no store or new protocol until these show a concrete limit.
