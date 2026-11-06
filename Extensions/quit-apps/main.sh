#!/bin/sh
# Quit Apps: lists running apps by memory, quits or force quits them, and shows details.
# Persistent loop: answers every request on stdin and exits when Wicket closes it.
# apps.js talks to AppKit (NSWorkspace, NSRunningApplication); ps adds memory and CPU.

reply() { jq -nc --argjson id "$1" --argjson result "$2" '{jsonrpc: "2.0", id: $id, result: $result}'; }
fail() { jq -nc --argjson id "$1" --argjson code "$2" --arg message "$3" '{jsonrpc: "2.0", id: $id, error: {code: $code, message: $message}}'; }
apps() { osascript -l JavaScript apps.js "$@"; }

# Resident memory (KiB) and CPU per pid, as a JSON object keyed by pid.
usage() {
  ps -o pid=,rss=,%cpu= -p "$1" 2>/dev/null |
    jq -Rn '[inputs | [splits(" +") | select(. != "")] | {key: .[0], value: {rss: (.[1] | tonumber), cpu: (.[2] | tonumber)}}] | from_entries'
}

# jq helpers shared by the list and the detail view.
JQ_DEFS='
def size: if . >= 1048576 then "\(. / 1048576 * 10 | round / 10) GB" else "\(. / 1024 | round) MB" end;
def cpu: "\(. | round)% CPU";
def quit($after): [
  {run: {command: "quit", args: {pid, name, after: $after}, title: "Quit \(.name)"}},
  {run: {command: "force-quit", args: {pid, name, after: $after}, title: "Force Quit \(.name)"}}
];
def place: if .path then [
  {open: {url: .path, title: "Switch to \(.name)"}},
  {open: {url: (.path | sub("/[^/]+/?$"; "")), title: "Show in Finder"}}
] else [] end;
'

list() {
  running=$(apps list) || return 1
  pids=$(printf '%s' "$running" | jq -r 'map(.pid) | join(",")')
  printf '%s' "$running" | jq -c --argjson usage "$(usage "$pids")" "$JQ_DEFS"'
    map(. + ($usage[.pid | tostring] // {rss: 0, cpu: 0}) | .key = (.bundle // .path // .name))
    | group_by(.key) | map(if length > 1 then map(.key += "#\(.pid)") else . end) | flatten
    | sort_by(-.rss)
    | {list: {items: map({
        id: .key,
        title: .name,
        subtitle: (.cpu | cpu),
        accessory: (.rss | size),
        actions: (quit("reload") + [{run: {command: "app", args: {pid}, title: "Show Details"}}] + place)
      } + (if .path then {icon: {file: {url: .path}}} else {} end))}}'
}

detail() {
  pid=$1
  app=$(apps info "$pid") || return 1
  if [ "$app" = null ]; then echo "That app is no longer running."; return 1; fi
  printf '%s' "$app" | jq -c --argjson usage "$(usage "$pid")" "$JQ_DEFS"'
    . + ($usage[.pid | tostring] // {rss: 0, cpu: 0})
    | {detail: {
        title: .name,
        markdown: "# \(.name)\n\n`\(.path // "no bundle")`",
        metadata: ([
          {label: "Memory", value: (.rss | size)},
          {label: "CPU", value: "\(.cpu | round)%"},
          {label: "Process ID", value: (.pid | tostring)}
        ] + (if .bundle then [{label: "Bundle ID", value: .bundle}] else [] end)
          + (if .launched then [{label: "Launched", value: (.launched | strflocaltime("%Y-%m-%d %H:%M"))}] else [] end)),
        actions: (quit("close") + place + (if .bundle then [{copy: {text: .bundle, title: "Copy Bundle ID"}}] else [] end))
      }}'
}

# quit or force: asks AppKit, then waits up to 3 seconds for the process to end.
stop() {
  verb=$1 pid=$2 name=$3 after=$4
  [ "$after" = close ] || after=reload
  app=$(apps "$verb" "$pid") || return 1
  if [ "$app" = null ]; then echo "$name is no longer running."; return 1; fi
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.25
  done
  if kill -0 "$pid" 2>/dev/null; then
    message="Asked $name to quit" # it may be showing a save dialog
  elif [ "$verb" = force ]; then
    message="Force quit $name"
  else
    message="Quit $name"
  fi
  jq -nc --arg after "$after" --arg message "$message" '{($after): {message: $message}}'
}

while IFS= read -r line; do
  {
    read -r id
    read -r method
    read -r command
    read -r pid
    read -r name
    read -r after
  } <<JSON
$(printf '%s\n' "$line" | jq -r '(.id | tojson), (.method // ""), (.params.command // ""),
  (.params.args.pid // 0 | tostring), (.params.args.name // "The app"), (.params.args.after // "reload")' 2>/dev/null)
JSON
  if [ -z "$id" ]; then fail null -32700 "Could not parse the request."; continue; fi
  [ "$id" = null ] && continue # a notification, such as cancel: nothing here is slow enough to stop
  if [ "$method" != run ]; then fail "$id" -32601 "Unknown method $method"; continue; fi

  case $command in
    quit-apps) result=$(list) ;;
    app) result=$(detail "$pid") ;;
    quit) result=$(stop quit "$pid" "$name" "$after") ;;
    force-quit) result=$(stop force "$pid" "$name" "$after") ;;
    *) result="Unknown command $command" && false ;;
  esac
  if [ $? = 0 ] && [ -n "$result" ]; then
    reply "$id" "$result"
  else
    fail "$id" 1 "${result:-Could not read the running apps.}"
  fi
done
