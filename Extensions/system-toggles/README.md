# System Toggles

Toggle Dark Mode, Toggle Mute and Sleep Displays: `once` commands that change a setting and answer with `close`.
Dark mode goes through System Events, so macOS asks once for the Automation permission; mute fails with a clear message on outputs without volume control (such as DisplayPort monitors).
The fixture only covers the error path, since every command changes the machine; `wicket check .` runs it.
