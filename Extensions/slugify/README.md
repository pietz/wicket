# Slugify

Slugify Text (`slug`): a `live` list with the URL slug and the snake_case name of what you type, each with paste and copy. Text in any script is transliterated to ASCII by [python-slugify](https://pypi.org/project/python-slugify/), so `Привет, мир!` becomes `privet-mir`.
The sample for Python with a dependency: python-slugify and text-unidecode are vendored in `vendor/` (`pip install --target vendor python-slugify`), which `main.py` puts on `sys.path`, so plain `python3` runs it and nothing is installed at run time. Try it with `wicket run . slug "Ærøskøbing Straße 5"`.
