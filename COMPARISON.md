# Wicket 0.1 compared with 0.0.x

Updated 11 Nov 2026. "First Wicket" and OLD mean the 0.0.x line, last released as 0.0.15 (commit `71a75a1`, 18,970 lines under `Sources/`, 12,206 test lines; 19,914 counting scripts and example extensions). The git history of this repository keeps it. "New Wicket" is this 0.1 rewrite; its design is in [SPEC.md](SPEC.md). Facts about the first Wicket come from three code audits, the third of which checked this file against the code.

## At a glance

The new app is **6,405 Swift lines plus 207 resource lines (6,612)** with **214 tests over 5,208 Swift test lines**. Two live-agent tests are opt-in. What still needs hands-on checking is in [ISSUES.md](ISSUES.md).

Of the 34 areas in the table below:

| Status | Count | Areas |
| --- | ---: | --- |
| Same | 8 | Platform, panel, agent ownership, permission prompts, extension basics, tag syntax, process stopping, updates and distribution |
| Same idea, smaller | 6 | Dependencies, agent protocol, agent docs and tools, extension views, ordering, markdown parsing |
| Changed | 11 | Streaming, triggers, built-ins, rich answer rendering, trust, calculator, settings, architecture, tests, headless testing, voice |
| Deferred | 4 | Secrets, run history, file search, shell commands |
| Dropped | 2 | Folder fingerprint, dedicated repair flow |
| New | 3 | User-editable component styles, protocol spike before UI, offscreen pixel checks |

## Overview

| Area | First Wicket | New Wicket | Status |
| --- | --- | --- | --- |
| Language and UI | Swift 6, SwiftUI content in an AppKit shell, macOS 26 | The same | Same |
| Panel, layering and hotkey | Floating non-activating panel with careful focus handling (891 lines); glass-only container beneath foreground | Focus and layering ported. Default Option+Space; existing config wins. Native launch-at-login control; login startup stays hidden and launch-time presentation never arms voice. 40-point margin, no extra window shadow, shared layout dimensions | Same |
| Dependencies | Sparkle only | swift-cmark and Sparkle (release edition only) | Same idea |
| Agent ownership | No own model loop, uses existing harnesses and their logins | The same | Same |
| Agent protocol | Two hand-made integrations: Claude Code stream-json and Codex app-server (1,650 lines) | The same idea, smaller: one JSON-lines process connection and one translator per CLI. One process per question, which ends with the turn; a follow-up resumes the session. A Node/ACP adapter design was built first and dropped | Same idea, smaller |
| Agent answers | Arrive as whole messages | Streamed as they are written; the Stream answers setting turns it off for whole messages | Changed |
| Permission prompts | Agent's own permission system, shown as Allow or Deny in the panel | The same, one native confirmation card. Mode, model, effort and speed are chosen in Settings from what each tool lists; Cmd+Return allows once, Esc denies, IME keeps priority | Same |
| Tools for the agent | No MCP server. Instructions, docs, examples and a `wicket` CLI | Instructions, the extension contract and an installed units extension in the Wicket folder. Every turn names the executable for headless `--query` and `--extension` runs. No MCP server and no authoring CLI | Same idea, smaller |
| What an extension is | A folder with a manifest and any executable. JSON in on stdin, one JSON object out on stdout, fresh process per call | `wicket.json`, argv without a shell, JSON input and arguments, one complete view, 10-second deadline and bounded output. Runs from its own folder. The old messages need migration | Same |
| Extension views | `answer`, `list`, `detail`, `close`, `reload`, `error` | `list` and `detail` built, ordered metadata, aliases, prominent rows and open/copy/paste/run/agent actions. `form` deferred | Same idea, smaller |
| How extensions get into the main list | By command name. `once` and `live` modes | Name, bounded regex (including empty input), or fallback. Patterns publish one completed view; typing cancels old work | Changed |
| Result ordering | Fixed tiers: exact matches, calculator, fuzzy matches, fallbacks, with a usage boost | Fixed tiers by match quality (math, pattern results, name matches, Ask agent, fallbacks, errors). Learned usage only breaks ties inside a tier at the root. No user-ordered source list. Ask agent leads only without a strong match | Same idea |
| Built-in features | App launch, calculator, file search and shell commands as fixed built-ins | App launch and math are compiled but sit behind the extension contract, can be switched off in Sources and replaced by extensions. File search and shell commands are not ported yet | Changed |
| Rich answers: what the agent writes | Markdown with short tags such as `<stat value="…"/>`, 12 component families | Markdown with seven component families; bounded inert tags, literal code and completed tag-like prose | Same |
| Rich answers: how they are drawn | Own scanner, parser, validator and builder, then one SwiftUI view per component (about 3,850 lines) | swift-cmark, a bounded tag adapter, one shared safe WebView, an isolated bridge and one CSS file; page scripts blocked by CSP (about 460 lines). The prototype painted in 37 ms warm and added about 83 MB; sustained memory return is unverified | Changed |
| Adding a component | A Swift definition, a Swift view and two registry entries, then recompile | A few lines of CSS in a file you own | New |
| Plain markdown | Parsed by Foundation, drawn as native blocks (164 lines) | Parsed by Apple's swift-cmark, drawn by the web view | Same idea |
| Extension trust | Sealed immutable copies of approved revisions, pending revisions, review of changes, management UI (915 lines) | Removed: enabled means trusted. An extension runs from its own folder when its source is on; new ones are on at once and the user switches them off in Sources. Not a sandbox | Changed |
| Folder fingerprint | Covers paths, contents, executable bits and symlinks | Not needed without approvals | Dropped |
| Stopping extension processes | Careful process tree handling (382 lines) | Ported, with Dispatch pipe reads so concurrent runs cannot starve deadlines/cancellation | Same |
| Secrets | Declared in the manifest, stored in the Keychain | Not ported yet | Deferred |
| Run history and diagnostics | Recent runs kept per extension (451 lines) | Not ported yet. A failed run shows its error | Deferred |
| Fix with agent | Repair conversations tied to revisions | Ask the agent in the normal conversation. No dedicated flow | Dropped |
| Calculator | Math, units and currencies (1,335 lines) | Basic math built in; offline unit conversion as the installed `units` extension. Broader units and currencies deferred | Changed |
| File search | Built in (Spotlight) | Not ported yet; planned, see [ROADMAP.md](ROADMAP.md) | Deferred |
| Shell command runner | Built in (196 lines) | Not ported yet; planned, see [ROADMAP.md](ROADMAP.md) | Deferred |
| Voice | On-device dictation with its own settings (638 lines) | Enabled by default and armed when the launcher opens; typing takes over. No shortcut, microphone-only consent, Automatic microphone choice that avoids Bluetooth headsets, on-device streaming. Extensions wait for settled speech. No automatic model download | Changed |
| Settings | Live JSON config plus 1,244 lines of settings UI. Model and effort choices already come from the agent | Four native tabs backed by one preserving atomic config writer. Shortcut registration before persistence, transparency saved on release, separate write errors, source switches and macOS launch at login. Agent options come from each CLI | Changed |
| Internal architecture | General command, frame and action layer (3,211 lines). Its row type is referenced from 46 files, the widest coupling in the app | Codable ProviderRequest to list or detail view, native host composition and actions, in one library module | Changed |
| Updates and distribution | Sparkle, notarized DMG, Homebrew cask | The same: the release machinery, editions, bundle ids and Sparkle key are kept | Same |
| Tests | 12,206 lines | 214 tests, 5,208 Swift lines, including voice and audio, settings, ranking, rendering, real subprocess and hidden WebKit regressions. Two live-agent tests are opt-in | Changed |
| Headless testing | A `wicket` CLI for agent tooling (check, run, logs, secrets) | The app binary itself: `--query`, `--extension`, JSON output, real config, usage and providers, no NSApplication. No authoring CLI | Changed |
| Pixel checks | Original panel used as the visual reference | An opt-in offscreen capture test with text recognition. Offscreen checks do not prove glass or focus; real-window pixels come only from hands-on checks | New |
| Build order | Features built broadly | Protocol spike, then launcher, agent, extensions, voice, settings, review fixes, simplification and release machinery | New |

## What the first Wicket got right

- Using existing agents instead of building a harness.
- The extension contract: any program, normalised by its output.
- Short tags in markdown as the agent's way to write rich answers.
- One renderer shared by agent answers and extension views.
- The hard platform work: panel focus and process trees.

## Where the lines went that we are not spending again

| Cost in the first Wicket | First Wicket lines | New Wicket as built |
| --- | ---: | --- |
| Machinery to read and validate the tag language | about 1,450 | swift-cmark plus a bounded tag adapter |
| One definition and one view per component | about 1,570 | 73 CSS and 29 bridge lines, shared by agent answers and extension details |
| General command, frame and action layer | 3,211, part of it still needed | A direct provider and view path |
| Two agent integrations | 1,650 | A connection and two translators, which now carry what a first design left to Node adapters |
| Sealed revisions, management UI and the coordinator around them | about 1,400 | Nothing: enabled means trusted |

These are replacement areas, not like-for-like file counts. The total is measured with `find Sources -type f | xargs cat | wc -l`: physical lines including comments, blanks and resources, excluding dependencies and generated files. The compiled app index stays warm in memory and is rebuilt on watched changes; a run-once replacement must own its cache. Long-running extensions remain deferred.

Physical hotkey and Allow/Deny delivery, IME, Spaces and fullscreen, VoiceOver and larger text, external open, copy and paste, live CSS, scrolling and selection, busy-background contrast, sustained WebKit memory return, real dictation, device switching, shortcut recording and login-item relaunch are checked by hand. See [ISSUES.md](ISSUES.md). Audible testing on a machine in use is forbidden.

[The detailed size comparison](docs/size-comparison.md) attributes most of the gap to design changes and omitted scope. Its 4,702-line snapshot predates voice on open, settings and the direct agent protocols; the current count above includes them. The smaller design came from first-principles work before reading the old code.

## Rewrite or reshape

An independent assessment (GPT-6.1 Sol, read-only, asked to test the lean towards a rewrite) concluded: fresh repository with selective ports, about 70% confident. The outcome: the rewrite was developed separately and landed in this repository as 0.1, with the first Wicket in its history.

| | Reshape the first Wicket | Fresh repository |
| --- | --- | --- |
| Strongest argument | The code is sound and well tested. Disciplined deletion keeps tested integration and release tooling | About 89% of the source is deleted or touched anyway. Building around the new contract makes it harder to keep old policy by accident |
| What survives | 3,000 to 4,000 test lines keep their value, 1,500 to 2,000 nearly unchanged | About 2,000 source lines port almost intact, plus about 640 for voice, with 1,200 to 1,800 test lines |
| Main risk | Cross-cutting removals are underestimated and compatibility scaffolding stays behind | Obscure platform behaviour is lost and lifecycle bugs are rediscovered |
| Expected size at the end | 6,000 to 8,000 lines with a web renderer, 7,000 to 9,000 native | The same |

The first Wicket's problem is accumulated product policy, not careless code: naming, concurrency and structure are good.

Pieces worth porting: panel focus and key handling (extracted from `PaletteController.swift`), `ProcessTree.swift`, `RevisionHash.swift`, app scanning, `FuzzyMatcher.swift`, `UsageStore.swift`, `LatestWriter.swift`, `MarkdownBlocks.swift`, and the voice files.
