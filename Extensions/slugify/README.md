# Slugify

Slugify Text (`slug`): a `live` list with the URL slug and the snake_case name of what you type, each with paste and copy. Text in any script is transliterated to ASCII by [python-slugify](https://pypi.org/project/python-slugify/), so `Привет, мир!` becomes `privet-mir`.
The sample for Python with a dependency, run by uv: `main.py` declares it in its PEP 723 header and `main.py.lock` pins it (from `uv lock --script main.py`, which must run again after any change to the dependencies). Test it with `uv run --script --locked main.py`; `wicket check .` needs no network once uv has the packages.
