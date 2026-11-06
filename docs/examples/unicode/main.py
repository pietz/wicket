"""Finds Unicode characters by name. Persistent: the name table is built once, then every
keystroke is answered from memory."""

import json
import sys
import unicodedata

NAMES = [(cp, unicodedata.name(chr(cp), "")) for cp in range(0x110000)]
NAMES = [(cp, name) for cp, name in NAMES if name]


def item(cp, name):
    char, code = chr(cp), f"U+{cp:04X}"
    return {
        "id": code,
        "title": name.title(),
        "subtitle": code,
        "accessory": char,
        "actions": [
            {"paste": {"text": char}},
            {"copy": {"text": char}},
            {"run": {"command": "character", "args": {"codepoint": cp}, "title": "Show Details"}},
        ],
    }


def search(text):
    words = text.upper().split()
    if not words:
        return {"list": {"items": []}}
    hits = sorted((h for h in NAMES if all(w in h[1] for w in words)), key=lambda h: len(h[1]))
    return {"list": {"items": [item(cp, name) for cp, name in hits[:100]]}}


def character(cp):
    char, code = chr(cp), f"U+{cp:04X}"
    return {
        "detail": {
            "title": unicodedata.name(char).title(),
            "markdown": f"# {char}\n\n`{code}` {unicodedata.name(char)}",
            "metadata": [
                {"label": "Code point", "value": code},
                {"label": "Category", "value": unicodedata.category(char)},
                {"label": "UTF-8", "value": char.encode().hex(" ").upper()},
            ],
            "actions": [{"copy": {"text": char}}, {"copy": {"text": code, "title": "Copy Code Point"}}],
        }
    }


def run(params):
    if params["command"] == "search":
        return search(params["text"])
    if params["command"] == "character":
        return character(params["args"]["codepoint"])
    raise ValueError(f"Unknown command {params['command']}")


for line in sys.stdin:  # ends when Wicket closes stdin
    message = json.loads(line)
    if "id" not in message:
        continue  # a notification, such as cancel; this extension answers fast enough to ignore it
    try:
        reply = {"result": run(message["params"])}
    except Exception as error:
        print(f"run failed: {error!r}", file=sys.stderr)
        reply = {"error": {"code": 1, "message": str(error)}}
    print(json.dumps({"jsonrpc": "2.0", "id": message["id"], **reply}), flush=True)
