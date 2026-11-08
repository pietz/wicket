# Size audit towards 12k lines (three GPT-6.1 Sol reviews, 2026-11-08)

Production code at 0.0.11: about 19,200 lines (Core 7,910, Host 4,781 plus CLI 153, App 6,378). The owner asked for free cuts and 80/20 cuts (small loss of experience, large saving), aiming loosely at 12,000. Estimates are net production lines; tests excluded.

**Headline:** no large dead subsystem anywhere. Free cuts total about 650 to 850 lines; the recommended 80/20 cuts about 800 more. 12,000 is not reachable without dropping pillars or features the owner chose (one CLI, images, Finder context, paste-back, the pickers); even accepting every listed cut lands near 16,000.

## Free (no behaviour change)
| Where | Cut | Lines |
|---|---|---:|
| Host | Comments that restate architecture.md | 110 to 150 |
| Host | Caller-owned command execution (`run(invocation, emit:)`), medium risk | 45 to 65 |
| Host | Synthesized internal initializers | ~50 |
| Host | One enabled-extension page builder | 15 to 25 |
| Host | Shared JSON-line encoder, one message error, obsolete diagnostic cleanup | 20 to 25 |
| Core | Fold `ScreenFrame` into `Frame` (one presentation state), medium risk | ~90 |
| Core | Diagnose prose tags in the scanner, not a second pass | ~40 |
| Core | One tolerant settings field reader | ~35 |
| Core | Trim repeated comments; unused convenience APIs | ~65 |
| App | Redundant comments | 50 to 70 |
| App | `URLSession.bytes` for the image collector (keep every safety check) | 45 to 65 |
| App | Native `Grid` for columns | 35 to 45 |
| App | Built-in registrations as data; shared settings writes | 55 to 80 |

(Earlier, the palette builder judged the `Frame`/`ScreenFrame` merge not worth it; the Core auditor estimates 90 lines. Decide on a prototype.)

## 80/20 (recommended by the auditors)
| Where | Cut | User loses | Lines |
|---|---|---|---:|
| Core+App | Drop `<timeline>`, `<badge>`, `<progress>` for items, facts and stats | Timeline rails, status pills, progress bars | ~350 |
| App | Native `NSMenu` for ⌘K instead of the overlay (prototype first) | The action panel's search field | 190 to 230 |
| Core | Remove named scientific functions and constants | `sqrt`, `log`, trig, `pi`, `e` | ~115 |
| App | Page metadata always below the text | Side-by-side metadata on long pages | 90 to 115 |
| Host | Fix and Change with Agent start a fresh conversation | The builder's original context | 65 to 85 |
| Core | Echo calculator input as typed | Normalized echo of the expression | ~55 |

## Considered and kept
- Both CLIs (drop one: 330 to 400), live model pickers (fixed list: 150 to 170; a JSON-only setup: 250+), final-answer-only (40 to 55).
- Remote images (330 to 370 App), cards and columns (~315), charts (~200), Finder context (~240), paste-back (~240), the menu bar icon (~120), automatic voice arming (45 to 60), card shrink timing, settings tabs, ⌘1 to ⌘9 (~60, optional).
- Run history depth (latest per command: 45 to 65), the generated command inventory for the agent (65 to 85): conditional on evidence.
