A focused day on **wicket**: the agent markup parser landed, and replies now render natively.

<stat label="Files" value="12"/>
<stat label="Added" value="+340" tone="positive"/>
<stat label="Removed" value="−120" tone="negative"/>
<stat label="Commits" value="4"/>

<timeline title="Commits">
  <event time="09:12" title="Parse agent markup into a block tree" detail="a1c94e2 · 3 files"/>
  <event time="11:40" title="Render stat, chart and facts natively" detail="7d03b18 · 5 files"/>
  <event time="14:05" title="Keyboard selection for entity lists" detail="e52f9aa · 2 files"/>
  <event time="16:31" title="Show unknown tags as text; tests" detail="0b6e771 · 2 files"/>
</timeline>

<list title="Files">
  <file path="~/Private/wicket/Sources/WicketCore/Markup/Parser.swift"/>
  <file path="~/Private/wicket/Sources/WicketCore/Markup/Scanner.swift"/>
  <file path="~/Private/wicket/Tests/WicketCoreTests/MarkupTests.swift"/>
  <file path="~/Private/wicket/docs/markup.md" accessory="new"/>
</list>

And 8 more, mostly in Sources/WicketApp.
