#!/usr/bin/python3
"""No network request: the selected row opens a search in the user's browser."""
import json, sys, urllib.parse
query = json.load(sys.stdin)["input"].strip()
items = []
if query:
    items = [{"id": "search", "title": "Search for " + query, "icon": "globe", "actions": [
        {"type": "open", "url": "https://www.google.com/search?" + urllib.parse.urlencode({"q": query})},
        {"type": "copy", "text": query}]}]
print(json.dumps({"items": items}))
