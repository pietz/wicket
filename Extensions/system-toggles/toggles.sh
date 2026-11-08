#!/bin/sh
# System toggles: each command changes one setting and answers with `close`.
# Wicket starts it once per run: it reads one request from stdin, prints one response and exits.

fail() { jq -nc --arg message "$1" '{error: {message: $message}}'; }
close() { jq -nc --arg message "$1" '{close: {message: $message}}'; }

# Each command prints a result object and succeeds, or prints the error message and fails.
# Details go to stderr, which Wicket keeps for diagnostics.

dark_mode() {
  # System Events needs the Automation permission; macOS asks the first time.
  if dark=$(osascript -e 'tell application "System Events" to tell appearance preferences' \
    -e 'set dark mode to not dark mode' -e 'return dark mode' -e 'end tell' 2>&1); then
    if [ "$dark" = true ]; then close "Dark mode on"; else close "Dark mode off"; fi
    return
  fi
  printf 'osascript: %s\n' "$dark" >&2
  case $dark in
    *-1743*) echo "Allow Wicket to control System Events in System Settings > Privacy & Security > Automation." ;;
    *) echo "Could not change the appearance." ;;
  esac
  return 1
}

mute() {
  if muted=$(osascript -e 'set muted to not (output muted of (get volume settings))' \
    -e 'set volume output muted muted' -e 'return muted'); then
    if [ "$muted" = true ]; then close "Sound muted"; else close "Sound on"; fi
    return
  fi
  echo "This output device can't be muted."
  return 1
}

sleep_displays() {
  if pmset displaysleepnow >&2; then
    jq -nc '{close: {}}'
    return
  fi
  echo "Could not put the displays to sleep."
  return 1
}

command=$(jq -r '.command')
case $command in
  dark-mode) result=$(dark_mode) ;;
  mute) result=$(mute) ;;
  sleep-displays) result=$(sleep_displays) ;;
  *) result="Unknown command $command" && false ;;
esac
if [ $? = 0 ]; then printf '%s\n' "$result"; else fail "$result"; fi
