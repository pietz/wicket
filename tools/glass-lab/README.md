# Glass Lab

A throwaway window with Wicket's panel (pill, list, canvas) for judging surface looks by eye, live, over real wallpapers. Not part of the app or `Scripts/check.sh`.

```sh
cd tools/glass-lab && swift run
```

↑/↓ switch look · ←/→ transparency · ⇧←/→ blur · ⌘D light/dark/system · ⌘J join pill and card · drag to move · ⌘Q quit.

Add a look by appending to `looks` in `main.swift`. The "Glass" look is the one Wicket ships (`Sources/WicketApp/GlassSurface.swift`); it patches a private Core Animation filter, as the app does.
