# Shell commands: product challenge and release review

GPT-6 Astra independently challenged the product before implementation and reviewed the finished code before release, 2026-11-09. Its recommendation: one explicit configurable prefix, one row, the existing output card and two destinations. Submission and Terminal handoff justify a small built-in; changing the extension protocol or adding a terminal emulator does not.

## Review and resolution

Astra found one release blocker: a three-second `yes` run left a 16 KiB tail but consumed 3.39 GB RSS. Follow-up isolation found `Data.removeFirst` advancing the retained buffer's indices while its backing storage grew. Rebuilding the suffix as fresh `Data` fixes that growth. The capture also now appends directly in the readability callback, keeping queued output outside the tail from becoming another unbounded buffer.

The retained [memory regression check](../../Scripts/bench/shell-output-memory.sh) compiles the real capture implementation and drains `yes` for three seconds. After the fix: 6.65 MB peak RSS, 16,384 bytes retained, truncation reported. It stops early and fails above 128 MiB. The full build, test and formatting check passes: 538 tests.

Astra found no other blocking correctness, quoting, authority or lifecycle issues and judged the feature coherent for an alpha release after the memory fix was verified. No dependencies or new action primitives were added. The existing process-tree limitation for deliberately daemonized descendants still applies.

## Verification

- Live inline submission displayed exact stdout, home cwd and exit status 0 in the existing card.
- Live ⌘Return opened the terminal; the command wrote the expected marker to a temporary file and the `.command` directory removed itself. Terminal's UI was inaccessible to the automation tool, so execution was checked through the command's result file.
- Tests cover no execution while typing, prefix ownership, both action orders, independent settings fallback and unknown-key preservation, live settings application, literal output, merged stderr, nonzero status, EOF stdin, output limits, cancellation of descendants, timeout, quoting, handoff and shutdown.
- Release-mode headless timing: ordinary root keystroke 0.387 ms, shell-prefix keystroke 0.0041 ms, frame push to content 0.580 ms. The Dev build's footprint after live runs was 30 MB, peak 31 MB. The screen-bound hotkey benchmark was not repeated before the owner ended the screen session; all subsequent verification was off-screen.


## 0.0.15: typing to continue

The owner asked for typing on output to start another command and typing on AI answers to continue the conversation. Astra's independent product challenge recommended the existing empty submit-text action path, preserving the first character and waiting for Return. Shell output now offers New Command; AI replies made entirely of rows use the same continuation behavior as prose. The footer advertises it, while row actions and the optional ⌘Return shortcut remain.

Astra's final review found no blockers. The full check passes (540 tests); off-screen controller checks cover shell, AI prose and AI rows, first text, no execution before Return, conversation arguments and Escape back to the result. Actual SwiftUI focus and live key delivery were not retested because the owner ended screen use.
