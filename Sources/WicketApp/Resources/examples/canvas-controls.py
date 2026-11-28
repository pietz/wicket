"""Copy this example into extensions/ and open Canvas Controls."""
import json
import sys

request = json.load(sys.stdin)
fields = request.get("fields", {})
action = request.get("action") if request.get("submitted") else None

if fields.get("view") == "form" and action != "save-chart":
    print(json.dumps({
        "title": "Name Chart",
        "back": {"view": "preview"},
        "fields": [
            {"name": "title", "type": "text", "label": "Title", "placeholder": "Weekly activity",
             "value": fields.get("title", "")},
            {"name": "goal", "type": "number", "label": "Goal", "description": "Target per period",
             "placeholder": "100", "min": 0, "max": 1000, "value": fields.get("goal", "")},
        ],
        "actions": [{"type": "run", "title": "Save", "action": "save-chart", "fields": {"view": "preview"}}],
    }))
    sys.exit(0)

if action == "reset-preview":
    fields = {}

periods = {"day": "Daily activity by hour", "week": "Weekly activity by day", "month": "Monthly activity by week"}
period = fields.get("period", "week")
if period not in periods:
    period = "week"
opacity = fields.get("opacity", "75")
if opacity not in {str(value) for value in range(0, 101, 5)}:
    opacity = "75"
grid = fields.get("grid", "true") == "true"
caption = fields.get("caption", "Activity")

# A named action is one-shot. A real command would persist the validated change here.
status = {
    "set-grid": "Grid shown." if grid else "Grid hidden.",
    "set-caption": "Caption updated.",
    "save-chart": "Chart information received.",
    "reset-preview": "Preview reset.",
}.get(action, "Sample data")
categories, values = {
    "day": ("09:00,12:00,15:00,18:00", "14,25,20,28"),
    "week": ("Mon,Tue,Wed,Thu,Fri", "32,29,38,35,41"),
    "month": ("Week 1,Week 2,Week 3,Week 4", "98,115,110,123"),
}[period]
body = f"""{status}

<field name="caption"/>
<field name="grid"/>
<field name="opacity"/>
<field name="period"/>

<chart labels="{categories}">
<line values="{values}"/>
</chart>

<row title="Name Chart…" run="edit?view=form"/>
<row title="Reset Preview…" tone="destructive" run="reset-preview" action="Reset Preview">
Restore the original preview values.
</row>"""
print(json.dumps({"title": "Chart Preview", "body": body, "fields": [
    {"name": "caption", "type": "text", "label": "Caption", "description": "Name shown in exported charts",
     "placeholder": "Activity", "value": caption, "default": "Activity", "action": True},
    {"name": "grid", "description": "Grid lines", "type": "bool", "value": grid, "action": True},
    {"name": "opacity", "description": "Opacity", "type": "number", "min": 0, "max": 100, "step": 5,
     "value": int(opacity)},
    {"name": "period", "description": "Group by", "type": "choice", "value": period,
     "options": [{"value": key, "label": label} for key, label in periods.items()]},
]}))
