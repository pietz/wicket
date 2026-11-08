# Markup

Wicket's markup is Markdown with a fixed set of native component tags. An agent's reply is written in it, and so are an extension's `detail.markdown` and `list.summary`. Wicket parses it into a document and draws each tag as a native view: no HTML, no web view.

```
A focused day on **wicket**.

<stats>
<stat value="12" label="Files"/>
<stat value="+340" label="Added" tone="positive"/>
</stats>

<file path="~/Private/wicket/Sources/WicketCore/Markup/Parser.swift"/>
```

## Syntax

- A tag starts its own line (or follows another tag on it). A tag inside a sentence is text.
- Attributes are `name="value"`; single quotes and bare words are read too. `&amp;`, `&lt;`, `&quot;` and numeric references are decoded.
- A tag closes itself (`<stat …/>`) or wraps content up to its closing tag. A tag that is never closed ends with its parent; a closing tag with nothing to close is dropped.
- Between tags is Markdown: headings, emphasis, lists, links, code, quotes and tables. Inside a tag, the shared indentation is removed, so tags may be indented for reading.
- Code blocks are code: tags in a fenced or indented block are never read.
- Repeating a tag makes a group: adjacent stats form a strip, adjacent rows a list, adjacent images a gallery. A wrapper (`<stats>`, `<facts>`, `<list>`, `<timeline>`) only gives its group a title.

## Tolerance

An agent's reply never fails. A tag Wicket doesn't know (HTML such as `<b>`, a misspelling) shows as text; so does a tag missing a required attribute, or one past a limit. An unknown attribute is dropped. A few spellings models reach for are read as the real tag (`<img>` as `<image>`, `<link>` as `<url>`, `type` as a chart's `kind`), but never advertised.

`wicket check` holds an extension's markup to the same rules strictly: every problem the parser tolerates, aliases included, is an error naming the response's line.

## Selection and Copy Answer

The arrows select what has a target, in reading order: the answer, rows, and cards and events with an `href` or `path`. A document made only of rows is a list and behaves like one. Everything else scrolls. Copy Answer copies the whole document as plain text: Markdown as written, each component as the text shown under its example below.

In a list's summary nothing is selectable, since the arrows belong to the rows: tags that always select (rows, the answer) show as text there, and a card's or event's target is dropped.

## Adding a component

A component is one file in `Sources/WicketCore/Markup/Components/` conforming to `Component`: its tags and attributes, an example with its Copy Answer text, how it is built from a parsed element, its text and its targets. Registered in `Markup.components`, it appears in the agent's instructions, in this reference, in `wicket check` and in the tests without another change. Its view is one file in the app, registered by type.

## Reference

<!-- reference: generated from Markup.components -->

### `<answer>`

```
<answer value="62" detail="Keanu Reeves, born 2 September 1964"/>
```

Copy Answer copies:

```
62
Keanu Reeves, born 2 September 1964
```

**`<answer>`** One short answer to a direct question, first in the reply; one per reply. Closes itself. The arrows select it.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `value` | text | yes | The answer, shown large; Return copies it. |
| `detail` | text |  | A line under it: the context or source. |
| `icon` | SF Symbol name |  | An SF Symbol beside it. |

### `<stat>` and `<stats>`

```
<stats title="Today">
<stat value="12" label="Files"/>
<stat value="+340" label="Added" tone="positive"/>
</stats>
```

Copy Answer copies:

```
Today
Files: 12
Added: +340
```

**`<stat>`** A number worth seeing at a glance. Adjacent stats form a strip, up to four per line. Closes itself.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `value` | text | yes | The number or short value. |
| `label` | text |  | What it is. |
| `detail` | text |  | A line under it. |
| `icon` | SF Symbol name |  | An SF Symbol beside it. |
| `tone` | `positive`, `warning`, `negative` |  | Colors the value: good, a caution, bad. |

**`<stats>`** Optional: titles a strip of stats. Holds `<stat>`; anything else in it is placed as if it weren't there.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `title` | text |  | A title above the group. |

### `<fact>` and `<facts>`

```
<fact label="Born" value="2 Sep 1964"/>
<fact label="Birthplace" value="Beirut, Lebanon"/>
```

Copy Answer copies:

```
Born: 2 Sep 1964
Birthplace: Beirut, Lebanon
```

**`<fact>`** A labelled value: a property, a date, a setting. Adjacent facts form a table of labels and values. Closes itself.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `label` | text | yes | The name. |
| `value` | text | yes | The value. |

**`<facts>`** Optional: titles a table of facts. Holds `<fact>`; anything else in it is placed as if it weren't there.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `title` | text |  | A title above the group. |

### `<file>`, `<url>`, `<item>` and `<list>`

```
<list title="Sources">
<url href="https://en.wikipedia.org/wiki/Keanu_Reeves" title="Wikipedia"/>
<item title="Commit a1c94e2" copy="a1c94e2"/>
</list>
```

Copy Answer copies:

```
Sources
- Wikipedia · https://en.wikipedia.org/wiki/Keanu_Reeves
- Commit a1c94e2
```

**`<file>`** A file or folder to open, reveal or copy; Wicket adds its icon, folder and date. Adjacent rows (file, url, item) form a list. Closes itself. The arrows select it.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `path` | absolute or `~/` path, or `file:` URL | yes | An absolute or ~/ path, or a file: URL. |
| `title` | text |  | Defaults to the file's name. |
| `subtitle` | text |  | The second line. |
| `accessory` | text |  | A short text at the right. |
| `icon` | SF Symbol name |  | An SF Symbol instead of the Finder icon. |

**`<url>`** A web page or mail address to open: sources, results, references. Adjacent rows (file, url, item) form a list. Closes itself. The arrows select it. Also read as `<link>`, which `wicket check` asks to spell `<url>`.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `href` | http, https or mailto link | yes | An http, https or mailto link. |
| `title` | text |  | Defaults to the host. |
| `subtitle` | text |  | The second line. |
| `accessory` | text |  | A short text at the right. |
| `icon` | SF Symbol name |  | An SF Symbol instead of the globe. |

**`<item>`** A plain row: a commit, a contact, a result that is neither a file nor a link. Adjacent rows (file, url, item) form a list. Closes itself. The arrows select it. Takes one of `href`, `path` or `copy`.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `title` | text | yes | The row's text. |
| `subtitle` | text |  | The second line. |
| `accessory` | text |  | A short text at the right. |
| `icon` | SF Symbol name |  | An SF Symbol at its left. |
| `href` | http, https or mailto link |  | Return opens this link. |
| `path` | absolute or `~/` path, or `file:` URL |  | Return opens this file. |
| `copy` | text |  | Return copies this text (without a target: the title). |

**`<list>`** Optional: titles a list of rows. Holds `<file>`, `<url>` and `<item>`; anything else in it is placed as if it weren't there.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `title` | text |  | A title above the group. |

### `<callout>`

```
<callout tone="warning">Design review and a dentist reminder overlap at **10:00**.</callout>
```

Copy Answer copies:

```
Design review and a dentist reminder overlap at **10:00**.
```

**`<callout>`** A short note that must stand out: a caveat, a warning, a success. Wraps Markdown, without tags; a tag line ends it.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `tone` | `info`, `positive`, `warning`, `negative` |  | info (the default), positive, warning or negative. |

### `<columns>` and `<column>`

```
<columns>
<stat value="7°C" label="Now"/>
<column>
<fact label="Wind" value="24 km/h W"/>
<fact label="Rain" value="40%"/>
</column>
</columns>
```

Copy Answer copies:

```
Now: 7°C

Wind: 24 km/h W
Rain: 40%
```

**`<columns>`** Up to 3 things side by side, to compare them. Each child, or each `<column>`, is a column. Wraps any blocks.

**`<column>`** Optional, inside `<columns>`: puts several blocks in one column. Wraps any blocks.

### `<card>`

```
<card title="Pixel 11" href="https://store.google.com/product/pixel_11">
<stat value="$749" label="From"/>
</card>
```

Copy Answer copies:

```
Pixel 11 · https://store.google.com/product/pixel_11
From: $749
```

**`<card>`** Groups blocks about one subject, such as each side of a comparison. Wraps any blocks. The arrows select it when it has an `href` or `path`. Takes one of `href` or `path`.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `title` | text |  | Its heading. |
| `subtitle` | text |  | A line under the heading. |
| `icon` | SF Symbol name |  | An SF Symbol beside the heading. |
| `href` | http, https or mailto link |  | Return opens this link. |
| `path` | absolute or `~/` path, or `file:` URL |  | Return opens this file. |

### `<image>`

```
<image src="https://upload.wikimedia.org/keanu.jpg" alt="Keanu Reeves" caption="2019"/>
```

Copy Answer copies:

```
Keanu Reeves · 2019 · https://upload.wikimedia.org/keanu.jpg
```

**`<image>`** A picture that helps: a product, a person, a screenshot. Adjacent images form a gallery. Closes itself. The arrows select it. Also read as `<img>`, which `wicket check` asks to spell `<image>`.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `src` | https URL or path | yes | An https URL or a local path. |
| `alt` | text |  | What it shows, for VoiceOver and Copy Answer. |
| `caption` | text |  | A line under it. |

### `<chart>` and `<point>`

```
<chart kind="line" title="Daily high" unit="°C">
<point label="Mon" value="9"/><point label="Tue" value="8"/><point label="Wed" value="7"/>
</chart>
```

Copy Answer copies:

```
Daily high
Mon: 9 °C
Tue: 8 °C
Wed: 7 °C
```

**`<chart>`** Numbers across categories or time: one `<point>` per value, up to 200, in up to 4 series. Holds `<point>`; anything else in it is ignored.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `kind` | `bar`, `line`, `sparkline` |  | bar (the default), line or sparkline. Also read as `type`. |
| `title` | text |  | Above the chart. |
| `unit` | text |  | The values' unit, such as °C or €. |

**`<point>`** One value, inside `<chart>`. Closes itself.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `label` | text | yes | The category or time. |
| `value` | number | yes | The number. |
| `series` | text |  | Which line or bar group it belongs to, when there are several. |

### `<event>` and `<timeline>`

```
<event time="09:00" end="09:15" title="Standup" detail="Zoom" href="https://zoom.us/j/123"/>
<event time="10:00" title="Design review" detail="Room Elbe"/>
```

Copy Answer copies:

```
- 09:00–09:15 · Standup · Zoom
- 10:00 · Design review · Room Elbe
```

**`<event>`** Something at a time: a meeting, a commit, a step. Adjacent events form a timeline. Closes itself. The arrows select it when it has an `href` or `path`. Takes one of `href` or `path`.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `time` | text |  | When, as the user reads it: 09:00, Mon, 2 Nov. |
| `end` | text |  | When it ends. |
| `title` | text | yes | What happens. |
| `detail` | text |  | Where, who, how long. |
| `href` | http, https or mailto link |  | Return opens this link. |
| `path` | absolute or `~/` path, or `file:` URL |  | Return opens this file. |

**`<timeline>`** Optional: titles a timeline. Holds `<event>`; anything else in it is placed as if it weren't there.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `title` | text |  | A title above the group. |

### `<progress>`

```
<progress label="Converted" value="18" max="24"/>
```

Copy Answer copies:

```
Converted: 18 of 24
```

**`<progress>`** How far along something is. Closes itself.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `value` | number | yes | How far. |
| `max` | number |  | The whole; without it, a value up to 1 is a fraction and more a percentage. |
| `label` | text |  | What is progressing. |
| `tone` | `positive`, `warning`, `negative` |  | Colors the bar. |

### `<badge>`

```
<badge tone="positive">Free 11:00 to 15:00</badge>
<badge>4 events</badge>
```

Copy Answer copies:

```
Free 11:00 to 15:00 · 4 events
```

**`<badge>`** A short status label, on its own line. Adjacent badges form a row. Wraps its text; a tag line ends it.

| Attribute | Value | Required | Meaning |
|---|---|---|---|
| `tone` | `positive`, `warning`, `negative` |  | Colors it. |

### Limits

| Limit | Value |
|---|---|
| Markup per screen | 64 KiB |
| Tags per document | 500 |
| Columns and cards inside one another | 2 |
| `<answer>` per document | 1 |
| `<image>` per document | 20 |
| `<chart>` per document | 10 |

Past a limit the rest shows as text; the reply never fails.

<!-- end of reference -->
