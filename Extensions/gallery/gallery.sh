#!/bin/sh
# Gallery: one of each screen Wicket draws, for trying the palette and as live documentation of the
# wire format. Every screen is a fixed JSON file in screens/, named after its command.
# Persistent loop: answers every request on stdin and exits when Wicket closes it.

while IFS= read -r request; do
  method=$(printf '%s' "$request" | jq -r '.method')
  # `cancel` is a notification: nothing to answer, and each answer here is immediate anyway.
  [ "$method" = run ] || continue
  id=$(printf '%s' "$request" | jq '.id')
  command=$(printf '%s' "$request" | jq -r '.params.command')
  screen="screens/$command.json"
  if [ -f "$screen" ]; then
    jq -c --argjson id "$id" '{jsonrpc: "2.0", id: $id, result: .}' "$screen"
  else
    jq -nc --argjson id "$id" --arg command "$command" \
      '{jsonrpc: "2.0", id: $id, error: {code: 1, message: ("Unknown command " + $command)}}'
  fi
done
