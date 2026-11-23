# `wicket-js`

Wicket ships a small Swift executable linked to system JavaScriptCore. The agent can write and edit an extension on a Mac without developer tools. Each request gets a fresh process and JavaScript context. Official extensions that need macOS APIs stay compiled Swift.

## Declaration and wire format

```json
{"contract":2,"name":"Example","command":["wicket-js","main.js"]}
```

Reserve the exact bare `wicket-js` name in the extension runner. Resolve it to `Contents/MacOS/wicket-js` alongside Wicket, ahead of PATH lookup. A missing bundled helper is a repair error. Require one relative script path in the extension folder. The script needs neither a shebang nor an execute bit. Read it afresh on every request, including in a symlinked extension folder. Keep the existing manifest schema, working directory and environment.

```js
function main(request) {
  return { body: `# ${request.input.length} characters` };
}
```

The executable reads the existing UTF-8 JSON line on stdin and passes that object as `request`. It has the same `input`, `fields`, `settings`, `locale`, `submitted`, optional `action` and optional `rootMatch` as other programs. Parse the request before evaluating the file and call its top-level `main` once. An object becomes the existing JSON view on stdout. A string becomes raw stdout under the same Markdown and leading-`{` rules as other programs. `undefined` prints nothing, which the existing host accepts only for a hidden run. Reject a promise with “main must be synchronous; wicket.fetch returns directly” and reject other return types. Send `console.log` and `console.error` to stderr. Use the existing view decoder, permission gate, action handling and repair rows. Invalid input, a missing `main`, script exceptions and serialization failures exit nonzero with a diagnostic on stderr. Include the script and line when available. The outer 10-second deadline and stdout and stderr caps of 1 MiB and 256 KiB still apply.

## Host functions

Expose synchronous functions on `wicket`. Blocking happens in the request process. Cap both `fetch` and `run` timeouts at the remaining 10-second request deadline. Block both during root matches. This extends the owner’s fetch decision to commands to follow the fast-path rule in AGENTS.md. Host functions throw JavaScript `Error`s with the operation and reason for bad arguments, denied calls and I/O failures. An uncaught error reaches stderr through the usual repair path. Capture the root-match flag from stdin before evaluating any script, so changing `request.rootMatch` or moving a call to top-level code cannot change the checks.

- **`wicket.read(name)`** returns UTF-8 text or `null` for a missing file. **`wicket.write(name, text)`** atomically writes UTF-8 text and returns `undefined`. Accept one filename without path components in `WICKET_DATA_DIR`, with a 1 MiB limit per file. Reject symlinks and non-regular files. Write via a temporary file in the same directory and rename it into place. Concurrent readers see a complete value and the last rename wins. Root matches can read local data and update a bounded cache. Gate durable user-visible changes on submission and the relevant action.
- **`wicket.fetch(url[, {method, headers, body, timeoutMs}])`** makes an HTTP(S) request (GET by default) and returns `{status, body}` with a numeric status and UTF-8 text. HTTP error statuses are results. Transport errors, timeout (five seconds by default), or a body exceeding 1 MiB cancel the transfer and throw. Count bytes as they arrive. Use an ephemeral native session without persistent cookies or credentials, and allow up to five redirects, each checked for HTTP(S). Put slow lookups behind `submit:true` and use cached data for matches.
- **`wicket.run(argv[, {input, timeoutMs, maxBytes}])`** executes one program with literal arguments and no shell. Inherit the extension's working directory and environment. Resolve bare names on Wicket's PATH and relative paths from the working directory. Write the optional input string to stdin, then close it. Return `{status, signal, stdout, stderr}` with UTF-8 text, a numeric status on exit or a numeric signal on termination, and `null` for the other field. Nonzero exit is a result. Default to 2,000 ms and 256 KiB of combined output, with maxima of 5,000 ms and 1 MiB. Reject invalid limits and drain both pipes concurrently. Keep the child in the runner's process group. Timeout or overflow kills the direct child and throws a catchable error. Wicket's existing `ProcessTree.swift` cleanup stops any descendants when the runner exits.

For both `fetch` and `run`, gate effects on `submitted` and any required named action. Unsubmitted requests outside root matches may read state.

Enabled means trusted. These functions offer convenient defaults within that model. JavaScript has standard language built-ins and one source file. Leave out npm, local imports, `require`, browser and Node globals, timers and a Foundation object bridge. Native code can use system frameworks internally. Use existing Wicket actions for opening links and copying text.

## Performance and first run

The trial in `tools/js-trial/` at `26f9782` used the JavaScriptCore C API with `main(request)` and JSON output. Its README reports **8.5 ms median / 11.2 ms p95** direct and warm, versus **3.4 / 4.5 ms** for Swift on an M1 Pro. The headless run, including Wicket startup, was **34.2 / 39.4 ms**. The helper was 56 KB. This baseline predates the host functions and its headless harness copied a helper into the extension folder.

On comparable hardware, target a signed runner at or below **12 ms median / 18 ms p95** for the same calculator workload, and measure root query latency against Wicket's existing 30 ms initial hold. Initialize networking and subprocess support only when called. A fresh signed helper took about **174 ms median** on first execution in the trial. A script edit measured **8.6 ms median**, while the Swift rebuild took **51 ms**. Sign one helper inside the app before signing the bundle. Recheck first and second invocations after a fresh signed install or update, then edit the script and run it again. The first execution of a new helper may incur the macOS check. Editing or adding scripts should stay at warm latency.

## Contract and verification

Put the manifest and `main(request)` example in the contract. Include “Keep `main` synchronous because `wicket.fetch` returns directly.” Show JSON storage with `wicket.read` and `wicket.write`. In step 2, convert the site search and web fallback recipes to `wicket.run(["/usr/bin/open", url])` behind submission, with `encodeURIComponent` for query values. Show a submitted fetch and escape `<` in fetched text placed in a body. Keep the existing action, permission and headless recipes.

For APIs that need a key, the user stores it once with `security add-generic-password` and never pastes it into chat. The extension reads it with `wicket.run(["/usr/bin/security","find-generic-password","-s","wicket.<id>","-w"]).stdout.trim()`.

Run scratch fixtures through `--extension` and `--query`. Compare Swift and JS views, including locale, fields, named actions, Markdown and a silent hidden run. Cover missing scripts, exceptions, malformed views and immediate edits. Exercise missing and oversized data, symlink rejection, atomic replacement and scratch isolation. Use a local HTTP fixture for success, redirects, errors, timeout and byte limits. Verify a root match makes zero requests and starts zero children even if it changes the request object. Test literal argv, both output streams, nonzero exit, overflow and descendant cleanup on timeout and cancellation. Verify the signed bundle headlessly on a Mac without developer tools.

## Build order

1. Ship the bundled runner, manifest resolution, pure computation support and data files. Document the entry point and storage recipe. Verify signed warm and first-run timings.
2. Ship fetch and command execution with their limits and root checks. Switch the contract examples and make JavaScript the authoring default in `agent-instructions.md` once headless tests pass.

## Open questions

- **Warm the helper on startup?** Start with the existing root hold and late-result delivery. Add a background probe of the bundled binary on a new app build only if the installed-build check shows a noticeable first-use delay. A probe would evaluate only built-in code.
