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

<field name="grid"/>
<field name="labels"/>
<field name="opacity"/>
<field name="period"/>

<progress label="Opacity" value="{opacity}%" percent="{opacity}"/>"""
print(json.dumps({"body": body, "fields": [
    {"name": "grid", "description": "Grid lines", "type": "bool", "value": grid == "true", "action": True},
    {"name": "labels", "description": "Axis labels", "type": "bool", "value": labels == "true"},
    {"name": "opacity", "description": "Opacity", "type": "number", "min": 0, "max": 100, "step": 5,
     "value": int(opacity)},
    {"name": "period", "description": "Group by", "type": "choice", "value": period,
     "options": [{"value": key, "label": key.title()} for key in periods]},
]}))
