# A public extension repository (GPT-6 Astra, 2026-11-08)

**Recommendation:** a small curated catalog (about ten extensions the maintainer reviews and supports), after the core freeze. Not a marketplace: that is a different security and maintenance commitment. The consent and sealing design is the install foundation; it does not make downloaded code safe.

## Organisation
- One repo: `extensions/<id>/` (manifest, source, README, licence, vendored dependencies), `catalog/<id>.json` (maintainer, attribution, compatibility, changelog, network behaviour), a generated `index.json` (names, terms, versions, immutable commits, file inventories, Wicket revision hashes). Protocol unchanged.
- Anyone may open a PR; only maintainers publish after reviewing all changed code. No obfuscation, runtime downloads or install scripts; start source-only, no binaries. Ids reserved forever. CI validates and computes revisions; PR jobs never see publishing credentials (Vicinae's PR flow is a precedent).
- Sharing back starts as an agent task ("prepare this extension for sharing": strip personal config, check for secrets, document, show the diff); a PR only on an explicit instruction.

## Discovery
- **Find Extensions** in the Extensions screen (and as a command): a normal list, not rows under app and file results.
- The cached index shows at once and refreshes when older than a day; search is local, nothing per keystroke. Offline browsing shows "last updated"; downloads need a fresh index so withdrawals apply. Search text never leaves the Mac; previews use text and SF Symbols, no remote images.

## Install and trust
- Download into staging outside the watched folder, a bounded list of regular files at an immutable commit; reject unsafe paths, links, case collisions and oversize; seal and compare with the published revision.
- Sign the index with a dedicated catalog key whose public half ships in Wicket; an increasing generation rejects rollbacks.
- Never overwrite an unrelated id or local modifications; provenance stored outside the folder, "Locally modified" after edits.
- Same static check, sealed revision and review token; the review adds publisher, author, source link, version, revision, changes, interpreters, secrets, and says plainly that it runs with the user's access to files and network.
- **Gap:** `wicket run` runs unreviewed folders with real secrets; reusing catalog code must not trigger it automatically.
- Updates: a badge on refresh, download on request, review per revision; withdrawn revisions get an advisory and Disable.
- **Sandbox:** not needed for a tiny fully reviewed catalog; required before broad third-party distribution, and a separate runtime project.

## Agent fit
On a build request, the agent checks installed commands, then the cached catalog: use an exact match, else adapt one, keeping its licence and upstream revision.

## Scope
Outside the freeze. First the repo, rules and a few examples with no Wicket change; then native v1: one catalog command, a signed-index cache, a staged downloader, provenance in the review. About 1,000 to 2,000 production lines plus 200 to 400 of repo tooling. Defer ratings, arbitrary repos, background updates, dependency installs, automatic PRs. The real cost is reviewing every revision.
