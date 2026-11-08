#!/bin/sh
# GitHub pull requests: review requests and your own open PRs, through the search API.
# Wicket starts it once per run: it reads one request from stdin, prints one response and exits.

fail() {
  jq -nc --arg message "$1" --arg data "${2:-}" \
    '{error: ({message: $message} + if $data == "" then {} else {data: $data} end)}'
}

# Searches GitHub for $1; sets $status (HTTP status, or 0 when GitHub can't be reached) and $body.
search() {
  # The token goes in through a curl config on stdin, so it never shows up in `ps`.
  if response=$(printf 'header = "Authorization: Bearer %s"\n' "$GITHUB_TOKEN" |
    curl --silent --show-error --max-time 20 --config - --get \
      --header 'Accept: application/vnd.github+json' --header 'X-GitHub-Api-Version: 2022-11-28' \
      --data-urlencode "q=is:open is:pr archived:false $1" --data 'sort=updated' --data 'per_page=50' \
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

command=$(jq -r '.command')

case $command in
  review-requests) query="review-requested:@me" ;;
  my-prs) query="author:@me" ;;
  *) fail "Unknown command $command"; exit ;;
esac
if [ -z "${GITHUB_TOKEN:-}" ]; then
  fail "No GitHub token; store one with: wicket secret set github-prs GITHUB_TOKEN"
  exit
fi

search "$query"
detail=$(printf '%s' "$body" | jq -r '.message? // empty' 2>/dev/null)
case $status in
  200) if result=$(items) && [ -n "$result" ]; then printf '%s\n' "$result"; else fail "GitHub sent an answer this extension doesn't understand."; fi ;;
  0) fail "Can't reach GitHub; check the network connection." ;;
  401) fail "GitHub rejected the token; store a new one with: wicket secret set github-prs GITHUB_TOKEN" "$detail" ;;
  403 | 429) fail "GitHub refused the request, probably its rate limit; try again in a few minutes." "$detail" ;;
  *) fail "GitHub answered with HTTP $status." "$detail" ;;
esac
