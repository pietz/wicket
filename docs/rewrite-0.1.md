# Wicket 0.1 rewrite retrospective

11 Nov 2026. The comparison is the last 0.0.x release, `v0.0.15` (`71a75a1`), against the first rewrite release, `v0.1.0` (`be57477`). The replacement commit `73bc094` has `71a75a1` as its direct parent; `3968409` restored release machinery, `5f52888` reorganized documentation, and `be57477` released it. Later fixes shipped in `v0.1.1` and `v0.1.2` (`a1a5064`); the observed HEAD, `c0ead52`, adds first-use feedback. These are separate from the 0.1.0 measurement.

## Size of the released trees

Physical lines, including comments and blanks; parentheses are nonblank lines, still including comments. These are owned, tracked text, not lines of executable code or total dependency code.

| Category | 0.0.15 | 0.1.0 | HEAD `c0ead52` |
| --- | ---: | ---: | ---: |
| Production Swift | 18,970 (17,305) | 6,405 (6,114) | 6,603 (6,302) |
| Test Swift | 12,206 (11,015) | 5,202 (4,901) | 5,483 (5,167) |
| Bundled runtime resources | 26 (15) | 207 (181) | 207 (181) |
| Other tracked source and examples | 1,214 (1,134) | 313 (291) | 313 (291) |
| **Total defined below** | **32,416 (29,469)** | **12,127 (11,487)** | **12,606 (11,941)** |

Production Swift fell by 12,565 physical lines, or 66%; test Swift fell by 7,004, or 57%. Runtime resources grew by 181 lines as the rewrite put CSS, a bridge, instructions and example extensions in the bundle. HEAD adds 198 production and 281 test Swift lines to 0.1.0. The 5,208 test lines quoted in the current SPEC are a later snapshot, not the 0.1.0 tag. These are tree sizes, not diff churn or proof of equivalent functionality.

To reproduce, run this from the repository root. The total is the sum of Swift under `Sources/` and `Tests/`, runtime resources under `Sources/WicketApp/Resources/` or the old `Resources/agent.md`, and `Package.swift`, `Scripts/` and `Extensions/` excluding `vendor/`. It includes example manifests and READMEs in those directories, but excludes test fixtures, other documentation, bundle metadata and icons, generated/build output and dependencies. Python `splitlines()` counts a final unterminated line; nonblank means it has a non-whitespace byte, not that it contains code.

```sh
python3 - v0.0.15 v0.1.0 c0ead52 <<'PY'
import subprocess, sys
for ref in sys.argv[1:]:
    paths = subprocess.check_output(['git', 'ls-tree', '-r', '--name-only', ref]).decode().splitlines()
    groups = {name: [0, 0] for name in ('production Swift', 'test Swift', 'runtime resources', 'other source')}
    for p in paths:
        if p.startswith('Sources/') and p.endswith('.swift'): name = 'production Swift'
        elif p.startswith('Tests/') and p.endswith('.swift'): name = 'test Swift'
        elif p.startswith('Sources/WicketApp/Resources/') or p == 'Resources/agent.md': name = 'runtime resources'
        elif p == 'Package.swift' or (p.startswith(('Scripts/', 'Extensions/')) and '/vendor/' not in p): name = 'other source'
        else: continue
        lines = subprocess.check_output(['git', 'show', f'{ref}:{p}']).splitlines()
        groups[name][0] += len(lines)
        groups[name][1] += sum(bool(line.strip()) for line in lines)
    print(ref, groups, 'total', [sum(v[i] for v in groups.values()) for i in range(2)])
PY
```

## What changed and why

The first Wicket separated `WicketCore`, `WicketHost` and `WicketApp`, with a general command, frame and action model and a separate authoring CLI. The rewrite uses one testable app library and a thin executable, with a smaller JSON provider request and list/detail response. Apps and basic math remain compiled providers; extensions are ordinary programs called on demand. Panel focus, process-tree handling, app scanning, matching and usage were selectively carried forward. The rewrite was designed from the product first, then compared with the old code; [the comparison](../COMPARISON.md) records the choice of a fresh design with selective ports rather than preserving the existing structure.

The largest reductions are architectural and scope-dependent:

- **Rich answers:** the old scanner, validator, builder and native component views were about 3,850 lines. The new cmark parser, bounded tag adapter, WebKit renderer, bridge and CSS replace that machinery and allow local CSS edits. This adds cmark and WebKit, moves rendering away from native glass, and ships seven component families instead of twelve. The old and new figures use different boundaries and are not a controlled parity measurement.
- **Command and extension machinery:** the old general command/frame/action layer is reported at 3,211 lines; the rewrite composes narrower provider views directly. Sealed approved extension revisions, their coordinator and management UI were replaced by “enabled means trusted.” New and edited enabled extensions run with the user's access, including on pattern matches; this removes approval and revision guarantees, not merely code. Invisible automatic runs remain a documented concern.
- **Calculator and built-ins:** the earlier size study assigned 1,335 lines to old math versus 116 to the then-current rewrite, but that rewrite snapshot was `b702f1a`, before release, so those figures are directional rather than release counts. 0.1 has basic arithmetic and a bundled unit extension; broader units and currencies, Spotlight file search and shell execution are deferred. Settings, extension secrets, run history and the authoring CLI also lost or deferred scope. The [earlier detailed study](size-comparison.md) estimates the relative contributions of design and missing scope, explicitly as judgments rather than proven removable lines.
- **Agents:** both releases use the user's existing Claude and Codex tools, rather than a Wicket model loop. The rewrite initially tried Node/ACP adapters, then used a shared JSON-lines connection with a translator for each CLI, one process per question and session resumption for follow-ups. This avoids keeping a warm agent alive, at the cost of process startup and inherited user configuration on each turn. Its reported half-gigabyte warm-process observation is not a benchmark of the released app.

0.1 also adds streamed answers, pattern and fallback extension triggers, editable answer CSS, and opt-in offscreen panel checks. The release retains Sparkle and signing identity, but intentionally does not import old settings, usage or extensions. Thus a smaller tree does not mean a drop-in feature replacement. External framework and parser code is outside the counts.

## Outcome and next judgment

The size goal was met: 6,612 production Swift and bundled resource lines at 0.1.0, below the SPEC's 8,000-line ceiling. This is evidence of a smaller owned implementation, not evidence that the original code was redundant, that the rewrite is faster, or that it has equivalent coverage. Prototype WebKit timings and memory are not integrated-app measurements. The old [size study](size-comparison.md) applies to an earlier rewrite snapshot, and its estimates should not be added to these release totals.

First use of 0.1.1 reported working follow-ups, permissions, voice onset and ranking, but the owner found the panel bland and answers worse than 0.0.x. `v0.1.1` fixed keyboard focus; `v0.1.2` added agent logging and other fixes. [ROADMAP.md](../ROADMAP.md) recommends prototyping a lighter native answer renderer against 0.0.15, and prioritizes file search, shell and calculator scope. [ISSUES.md](../ISSUES.md) still records unverified signed GUI paths, cask upgrades, accessibility, IME, physical hotkeys, voice/device behavior and integrated renderer performance; the Sparkle upgrade through 0.1.1 was verified on the owner's Mac.

The rewrite succeeded at reducing the core and making extensions more direct, while trading away capabilities, extension revision protections and native answer presentation. Keep the smaller provider model, but judge the renderer prototype on actual appearance, accessibility, memory and complexity before replacing it, and restore deferred features in priority order with measured scope and behavior rather than treating the line budget as the outcome.
