"""Copy this example into extensions/ and open Canvas Controls."""
import json
import sys

request = json.load(sys.stdin)
fields = request.get("fields", {})
periods = {"day": "Daily", "week": "Weekly", "month": "Monthly"}
period = fields.get("period", "week")
if period not in periods:
    period = "week"
opacity = fields.get("opacity", "75")
if opacity not in {str(value) for value in range(0, 101, 5)}:
    opacity = "75"
grid = "true" if fields.get("grid", "true") == "true" else "false"
labels = "true" if fields.get("labels", "true") == "true" else "false"

# An action is one-shot. In a real command, persist the new grid value here.
confirmed = request.get("submitted") and request.get("action") == "set-grid"
status = ("Grid shown." if grid == "true" else "Grid hidden.") if confirmed else "Chart preview"
body = f"""# {periods[period]} chart
{status}

<field name="grid" label="Grid lines" type="bool" value="{grid}" act="true"/>
<field name="labels" label="Axis labels" type="bool" value="{labels}"/>
<field name="opacity" label="Opacity" type="number" min="0" max="100" step="5" value="{opacity}"/>
<field name="period" label="Group by" type="choice" options="day=Day&week=Week&month=Month" value="{period}"/>

<progress label="Opacity" value="{opacity}%" percent="{opacity}"/>"""
print(json.dumps({"body": body}))
