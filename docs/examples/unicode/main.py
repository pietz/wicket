"""Finds Unicode characters by name. Wicket starts it once per keystroke, so the name table is
built on the first run and cached in WICKET_DATA_DIR; later runs read it in a few milliseconds."""

import json
import os
import sys
import unicodedata


def names():
    cache = os.path.join(os.environ["WICKET_DATA_DIR"], f"names-{unicodedata.unidata_version}.txt")
    if not os.path.exists(cache):
        table = ((cp, unicodedata.name(chr(cp), "")) for cp in range(0x110000))
        with open(cache + ".tmp", "w") as file:
            file.writelines(f"{cp:X}\t{name}\n" for cp, name in table if name)
        os.replace(cache + ".tmp", cache)
    with open(cache) as file:
        return [(int(cp, 16), name) for cp, name in (line.rstrip("\n").split("\t") for line in file)]


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
    hits = sorted((h for h in names() if all(w in h[1] for w in words)), key=lambda h: len(h[1]))
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


try:
    response = run(json.load(sys.stdin))
except Exception as error:
    print(f"run failed: {error!r}", file=sys.stderr)
    response = {"error": {"message": str(error)}}
print(json.dumps(response))
