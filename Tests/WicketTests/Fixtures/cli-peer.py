import json, sys

# Replays recorded CLI traffic: {"out": message} is written to stdout, {"in": text} waits for a
# stdin line that contains the text. Then it idles like the real CLIs until stdin closes.
for step in map(json.loads, open(sys.argv[1])):
    if "out" in step:
        print(json.dumps(step["out"], ensure_ascii=False), flush=True)
    else:
        for line in sys.stdin:
            if step["in"] in line:
                break
        else:
            sys.exit("peer: stdin ended before " + step["in"])
sys.stdin.read()
