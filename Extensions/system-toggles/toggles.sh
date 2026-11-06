#!/bin/sh
# System toggles: each command changes one setting and answers with `close`.
# Persistent loop: answers every request on stdin and exits when Wicket closes it.

reply() { jq -nc --argjson id "$1" --argjson result "$2" '{jsonrpc: "2.0", id: $id, result: $result}'; }
fail() { jq -nc --argjson id "$1" --argjson code "$2" --arg message "$3" '{jsonrpc: "2.0", id: $id, error: {code: $code, message: $message}}'; }
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

while IFS= read -r line; do
  {
    read -r id
    read -r method
    read -r command
  } <<JSON
$(printf '%s\n' "$line" | jq -r '(.id | tojson), (.method // ""), (.params.command // "")' 2>/dev/null)
JSON
  if [ -z "$id" ]; then fail null -32700 "Could not parse the request."; continue; fi
  [ "$id" = null ] && continue # a notification, such as cancel: every command here is instant
  if [ "$method" != run ]; then fail "$id" -32601 "Unknown method $method"; continue; fi

  case $command in
    dark-mode) result=$(dark_mode) ;;
    mute) result=$(mute) ;;
    sleep-displays) result=$(sleep_displays) ;;
    *) result="Unknown command $command" && false ;;
  esac
  if [ $? = 0 ]; then reply "$id" "$result"; else fail "$id" 1 "$result"; fi
done
