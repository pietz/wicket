#!/bin/zsh
# One benchmark session: latency, memory and a typing smoke test for Wicket (and any variants), then
# Tinycast. Takes over the keyboard and screen for ~3 minutes: only run when the Mac is free.
#   Scripts/bench/session.sh <Tinycast.app path> <output dir>
# Everything uses ⌃⌥Space so a ChatGPT-style ⌥Space binding cannot interfere.
set -uo pipefail
cd "${0:A:h}/../.."
tinycast="$1"; out="$2"; runs="${RUNS:-30}"
mkdir -p "$out" build
config="$(mktemp -d)"
echo '{"hotkey": "ctrl+option+space"}' > "$config/settings.json"
swiftc -O Scripts/bench/hotkey-latency.swift -o build/hotkey-latency
swiftc -O Scripts/bench/keys.swift -o build/keys
Scripts/build-app.sh >/dev/null
pkill -x Wicket; pkill -x Tinycast; sleep 1

smoke() {  # $1 label, $2 process: open, type "term", move down, screenshot, close
  build/keys ctrl-opt-space "await:$2" t e r m down || return
  sleep 0.4
  screencapture -x "$out/$1.png"
  build/keys "await:$2" esc esc; sleep 0.4
}

variant() {  # $1 label, rest: env assignments
  local label=$1; shift
  env "$@" WICKET_CONFIG_DIR="$config" build/Wicket.app/Contents/MacOS/Wicket --background >/dev/null 2>&1 &
  sleep 4
  echo "== $label"
  build/hotkey-latency Wicket "$runs" --ctrl || echo "latency run aborted"
  sleep 3; footprint -p "$(pgrep -x Wicket)" | grep 'phys_footprint:'
  smoke "$label" Wicket
  pkill -x Wicket; sleep 1
}

# Add `variant <label> VAR=value ...` lines to A/B an experiment switch.
variant wicket

defaults write com.tinycast.app hotkey.togglePalette -string \
  '{"combo":{"_0":{"carbonKeyCode":49,"carbonModifiers":6144}}}'
open -g "$tinycast"; sleep 6
echo "== tinycast"
build/hotkey-latency Tinycast "$runs" --ctrl || echo "latency run aborted"
sleep 3; footprint -p "$(pgrep -x Tinycast)" | grep 'phys_footprint:'
smoke tinycast Tinycast
pkill -x Tinycast
echo "done; screenshots in $out"
