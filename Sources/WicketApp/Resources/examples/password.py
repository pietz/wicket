#!/usr/bin/python3
"""Random passwords, offline: `length` and `count` are declared arguments, so the list changes as a slot
is filled. Each row copies itself. A missing, invalid or out-of-range value uses the default."""
import json, secrets, string, sys
arguments = json.load(sys.stdin).get("arguments", {})

def number(name, default, most):
    try:
        value = int(arguments.get(name, ""))
    except ValueError:
        return default
    return value if 1 <= value <= most else default

length, count = number("length", 20, 128), number("count", 5, 20)
alphabet = string.ascii_letters + string.digits + "-_!@#%+="
passwords = ["".join(secrets.choice(alphabet) for _ in range(length)) for _ in range(count)]
print(json.dumps({"items": [
    {"id": str(index), "title": password, "subtitle": f"{length} characters", "icon": "key",
     "actions": [{"type": "copy", "text": password}]}
    for index, password in enumerate(passwords)]}))
