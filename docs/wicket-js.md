# `wicket-js`

Wicket ships a small Swift executable (`Sources/WicketJS/`, bundled at `Contents/MacOS/wicket-js`) linked against system JavaScriptCore so the agent can write and edit extensions without Apple's developer tools. Each request runs in a fresh process and `JSGlobalContext`. Official extensions needing macOS APIs stay compiled Swift.

Author-facing manifest syntax, `main(request)` contract, host function signatures, limits, and recipes live in the [extension contract](../Sources/WicketApp/Resources/extension-contract.md#a-javascript-command). This note covers host internals and non-goals.

## Host resolution and execution

- `ExtensionRunner` reserves the bare command name `"wicket-js"`, resolving it directly to `Contents/MacOS/wicket-js` ahead of `PATH` (a missing or non-executable helper reports a repair error).
- Expects exactly one relative script path inside the extension folder (no leading `/`, no `..`, no NUL, resolved path must be a regular file within the folder). No shebang or execute bit needed; the script is read fresh on every request, including through symlinks.
- `ExtensionRunner` sets `WICKET_JS_DEADLINE_NS` to 100 ms under the 10-second outer deadline so capped host calls throw before the outer timeout kills the runner.
- `main.swift` parses the stdin JSON object and captures `rootMatch` *before* evaluating the script, so top-level code or mutating `request.rootMatch` cannot bypass root-match restrictions.
- Calling `main(request)` returns a view object (serialized as JSON), a raw string (same Markdown / leading-`{` rules as any program), or `undefined` (silent output, accepted only for hidden runs). Returning a `Promise` fails with `"main must be synchronous; wicket.fetch returns directly"`. Exceptions report script name and line number on stderr.

## Host function internals

- **`wicket.read` / `wicket.write` (`Storage.swift`):** Single filename in `WICKET_DATA_DIR`, ≤1 MiB. Opens with `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`, checks `S_IFREG` via `fstat`/`lstat`, and writes atomically via `mkstemp` + `rename` in the same directory.
- **`wicket.fetch` (`Fetch.swift`):** Uses `URLSessionConfiguration.ephemeral` with cookies, credential storage, and cache disabled. Counts bytes incrementally (1 MiB cap) and allows up to 5 HTTP(S) redirects, preserving `Authorization` only on same-origin redirects. Blocked during `rootMatch`.
- **`wicket.run` (`Run.swift`):** Spawns via `posix_spawn` with `POSIX_SPAWN_CLOEXEC_DEFAULT` in the runner's own process group so `ProcessTree.swift` cleans up descendants when the runner exits. Drains stdout/stderr concurrently with `poll`, enforces `timeoutMs` (default 2,000 ms, max 5,000 ms, capped at remaining budget) and `maxBytes` (default 256 KiB, max 1 MiB combined), and `SIGKILL`s the direct child on overflow or timeout. Blocked during `rootMatch`.

## Deliberate non-goals

Standard JavaScriptCore built-ins and one source file only: no npm, local imports/`require`, browser or Node globals, timers, or Foundation bridge. Use Wicket actions (`open`, `copy`, `paste`) for UI effects and `wicket.run` for CLIs (such as Keychain's `security`).

## Performance and open question

- Target for signed warm runs on Apple silicon: ≤12 ms median / ≤18 ms p95 (network and subprocess code initialize only when called). First execution of a freshly installed/updated signed helper incurs macOS's code-signing check; script edits stay at warm latency.
- **Warm the helper on startup?** Keep the 30 ms root hold and late delivery for now; add a background startup probe of built-in code only if real installed builds show a noticeable first-use delay.
