#!/bin/zsh
# Interactive checklist for one announced screen session, run by the owner at a free Mac. It starts
# Wicket Dev (Scripts/build-app.sh) in an isolated config folder and sends no synthetic keys,
# pointer movement or screenshots.
#   Scripts/verify-session.sh
set -euo pipefail
cd "${0:A:h}/.."
app="${WICKET_BUILD_APP:-$PWD/build/Wicket Dev.app}"
exe="$app/Contents/MacOS/Wicket"
[[ -x "$exe" ]] || { print -u2 'Run Scripts/build-app.sh before screen time.'; exit 1; }
command -v claude >/dev/null && command -v codex >/dev/null || {
  print -u2 'Before screen time, install claude and codex and sign in with both.'; exit 1;
}
if pgrep -f "^$PWD/build/[^/]+[.]app/Contents/MacOS/Wicket$" >/dev/null; then
  print -u2 'A Wicket build from this folder is running. Quit it before this isolated check.'; exit 1
fi
print 'Only after announcing one five-minute screen session to the owner.'
read -r 'ready?Type start to begin (anything else exits): '
[[ "$ready" == start ]] || exit 0
check_dir="$(mktemp -d /tmp/wicket-check.XXXXXX)"
write_config() {
  local name="$1" model mode
  if [[ "$name" == claude ]]; then model=sonnet; mode=default; else model=gpt-6.1-sol; mode=read-only; fi
  cat > "$check_dir/config.json" <<JSON
{
  "hotkey": "$2", "backgroundTransparency": $3,
  "providers": [{"id":"math","enabled":$4},{"id":"apps","enabled":true}],
  "agent": {"name":"$name","model":"$model","effort":"low","mode":"$mode"}
}
JSON
}
write_config claude option+space 0.15 true
WICKET_CONFIG_DIR="$check_dir" "$exe" > "$check_dir/app.log" 2>&1 &
wicket_pid=$!
trap 'kill -TERM "$wicket_pid" 2>/dev/null || true' EXIT INT TERM
print '\n0:00–1:00  Launcher, input anchor and math'
print 'Toggle Option+Space. Immediately type cal, backspace, and type a sentence.'
print 'Judge the fixed top border, selection, icons and readability. Launch Calculator only if not already open.'
print 'Summon, type 200*10%+2^3, expect 28, Enter to copy.'
read -r 'answer?Return here and Enter after copying: '
[[ "$(pbpaste)" == 28 ]] && print 'Clipboard PASS' || print 'Clipboard FAILED'
write_config claude ctrl+option+shift+return 0.15 false
print '\n1:00–1:40  Ranking, live config, owner hands'
print 'New hotkey Ctrl+Option+Shift+Return. Type 2+2: only Ask agent. Do not submit it.'
print 'Search c, select a lower prefix app, launch, reopen c and check learned ordering.'
print 'Owner: check IME composition and editing; dismiss over another Space/fullscreen if convenient.'
read -r 'answer?Enter to restore shortcut and math: '
write_config claude option+space 0.15 true
print '\n1:40–2:30  Ask, rich answer and follow-up'
print 'Ask: Remember LANTERN-47. Show a stat with value 42 and a warning callout. No tools.'
print 'Enter the Ask agent row; confirm streaming. Follow up: What is the codeword? using Cmd+Enter.'
print 'Select and copy answer text. Click a harmless HTTPS Markdown link if present.'
read -r 'answer?Enter after checking: '
print '\n2:30–3:25  Native permission prompt'
print "Ask: Write ALLOWED to $check_dir/allowed.txt using the file-writing tool, no shell."
print 'Owner: inspect the displayed path, then click Allow once.'
print "Then ask: Write DENIED to $check_dir/denied.txt using the file-writing tool, no shell. Click Deny."
read -r 'answer?Enter when both turns finish (skip a slow step to keep time): '
[[ -f "$check_dir/allowed.txt" && ! -f "$check_dir/denied.txt" ]] && print 'Permission files PASS' || print 'Permission files need inspection'
print '\n3:25–4:10  Idle reload while checking composition'
print 'Dismiss for at least 35 seconds. Owner: judge focus return and the earlier IME/Space checks.'
print 'Reopen: answer should remain. Follow up: What is the codeword? The session must resume.'
read -r 'answer?Enter to switch agent: '
write_config codex option+space 0.15 true
print '\n4:10–5:00  Codex, cancellation, live CSS'
print 'Esc back to search. Cmd+Enter: Count 1 to 5000, one per line. Cancel during streaming.'
print 'Then ask: Show one stat with value 42. No tools. Check Codex and its options file.'
read -r 'answer?Enter when the stat appears: '
print '\nw-stat { border: 2px solid AccentColor; }' >> "$check_dir/theme.css"
print 'Owner: confirm the stat border updates live, answer scrolling/selection feels native, and Esc returns then closes.'
read -r 'answer?Enter to finish the on-screen session and quit this instance: '
print "Done. Isolated config, options, permission files and log: $check_dir"
print 'Normal Wicket files were not edited. Close only test apps you opened. Record failures and skipped checks.'
