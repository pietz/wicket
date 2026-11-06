#!/bin/sh
# Answers with the current ISO week number, then exits; Wicket starts it again next time.
read -r request
id=$(printf '%s' "$request" | jq '.id')
week="Week $(date +%V)"
jq -nc --argjson id "$id" --arg week "$week" \
  '{jsonrpc: "2.0", id: $id, result: {answer: {title: $week, subtitle: "ISO week number"}}}'
