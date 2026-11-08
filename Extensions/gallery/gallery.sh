#!/bin/sh
# Gallery: pages in Wicket's markup and one plain list, for trying the palette and as live
# documentation of the wire format. Every screen is a fixed JSON file in screens/, named after its command.
# Wicket starts it once per run: it reads one request from stdin, prints one response and exits.

command=$(jq -r '.command')
screen="screens/$command.json"
if [ -f "$screen" ]; then
  jq -c . "$screen"
else
  jq -nc --arg command "$command" '{error: {message: ("Unknown command " + $command)}}'
fi
