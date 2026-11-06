#!/bin/sh
# GitHub pull requests: review requests and your own open PRs, through the search API.
# Persistent loop: answers every request on stdin and exits when Wicket closes it.
#
# Testing: when GITHUB_PRS_FIXTURE_DIR is set, the API is not called. Each command reads
# $GITHUB_PRS_FIXTURE_DIR/<command>.json instead, shaped {"status": <HTTP status>, "body": <JSON>}.
# `wicket check` sets WICKET_CHECK=1 and has no network, so then the canned answers in fixture/ are
# used and session.jsonl replays offline: `wicket check .`

if [ "${WICKET_CHECK:-}" = 1 ]; then : "${GITHUB_PRS_FIXTURE_DIR:=fixture}"; fi

reply() { jq -nc --argjson id "$1" --argjson result "$2" '{jsonrpc: "2.0", id: $id, result: $result}'; }
fail() {
  jq -nc --argjson id "$1" --argjson code "$2" --arg message "$3" --arg data "${4:-}" \
    '{jsonrpc: "2.0", id: $id, error: ({code: $code, message: $message} + if $data == "" then {} else {data: $data} end)}'
}

# Searches GitHub; sets $status (HTTP status, or 0 when GitHub can't be reached) and $body.
search() {
  if [ -n "${GITHUB_PRS_FIXTURE_DIR:-}" ]; then
    status=$(jq '.status' "$GITHUB_PRS_FIXTURE_DIR/$1.json")
    body=$(jq -c '.body' "$GITHUB_PRS_FIXTURE_DIR/$1.json")
    return
  fi
  # The token goes in through a curl config on stdin, so it never shows up in `ps`.
  if response=$(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" |
    curl --silent --show-error --max-time 20 --config - --get \
      --header 'Accept: application/vnd.github+json' --header 'X-GitHub-Api-Version: 2022-11-28' \
      --data-urlencode "q=is:open is:pr archived:false $2" --data 'sort=updated' --data 'per_page=50' \
      --write-out '\n%{http_code}' https://api.github.com/search/issues); then
    status=$(printf '%s' "$response" | tail -n 1)
    body=$(printf '%s' "$response" | sed '$d')
  else
    status=0 body=""
  fi
}

# The search result as a list: open, copy and an inline detail view per pull request.
items() {
  printf '%s' "$body" | jq -c '
    def ago: (now - fromdateiso8601) as $s
      | if $s < 3600 then "\($s / 60 | floor)m" elif $s < 86400 then "\($s / 3600 | floor)h"
        elif $s < 2592000 then "\($s / 86400 | floor)d" else "\($s / 2592000 | floor)mo" end;
    def text: if . == null or . == "" then "_No description._"
      elif length > 4000 then .[:4000] + "\n\n…" else . end;
    {list: {items: .items | map(
      (.repository_url | sub(".*/repos/"; "")) as $repo
      | {open: {url: .html_url, title: "Open in Browser"}} as $open
      | {copy: {text: .html_url, title: "Copy Link"}} as $copy
      | {
        id: .html_url,
        title: .title,
        subtitle: "\($repo) #\(.number) by \(.user.login)\(if .draft then " (draft)" else "" end)",
        accessory: (.updated_at | ago),
        actions: [$open, $copy, {detail: {
          title: .title,
          markdown: (.body | text),
          metadata: ([
            {label: "Repository", value: $repo},
            {label: "Number", value: "#\(.number)"},
            {label: "Author", value: .user.login},
            {label: "Updated", value: .updated_at[:10]},
            {label: "Comments", value: (.comments | tostring)}
          ] + if (.labels | length) > 0 then [{label: "Labels", value: (.labels | map(.name) | join(", "))}] else [] end),
          actions: [$open, $copy]
        }}]
      })}}'
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
  [ "$id" = null ] && continue # a notification, such as cancel: requests are answered in order
  if [ "$method" != run ]; then fail "$id" -32601 "Unknown method $method"; continue; fi

  case $command in
    review-requests) query="review-requested:@me" ;;
    my-prs) query="author:@me" ;;
    *) fail "$id" 1 "Unknown command $command"; continue ;;
  esac
  if [ -z "${GITHUB_TOKEN:-}" ]; then
    fail "$id" 1 "No GitHub token; store one with: wicket secret set github-prs GITHUB_TOKEN"
    continue
  fi

  search "$command" "$query"
  detail=$(printf '%s' "$body" | jq -r '.message? // empty' 2>/dev/null)
  case $status in
    200) if result=$(items) && [ -n "$result" ]; then reply "$id" "$result"; else fail "$id" 1 "GitHub sent an answer this extension doesn't understand."; fi ;;
    0) fail "$id" 1 "Can't reach GitHub; check the network connection." ;;
    401) fail "$id" 1 "GitHub rejected the token; store a new one with: wicket secret set github-prs GITHUB_TOKEN" "$detail" ;;
    403 | 429) fail "$id" 1 "GitHub refused the request, probably its rate limit; try again in a few minutes." "$detail" ;;
    *) fail "$id" 1 "GitHub answered with HTTP $status." "$detail" ;;
  esac
done
