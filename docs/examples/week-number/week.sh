#!/bin/sh
# Answers with the current ISO week number. Wicket starts it for every run and writes the request
# to stdin; this command needs nothing from it.
week="Week $(date +%V)"
jq -nc --arg week "$week" '{answer: {title: $week, subtitle: "ISO week number"}}'
