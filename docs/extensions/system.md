# System extension

**Parked.** Waiting on Automation and per-action permission design; see [Official extensions](README.md). Shared-work numbers below refer to an earlier list (shared work 2 = Automation / per-action permission checks).

## 1. Summary

Tier 1 catalog extension for on-demand macOS actions and System Settings panes (ongoing CPU/memory/network metrics belong to Monitor).

## 2. User experience

| Query | Behavior |
| --- | --- |
| `system` | Native filterable list; items are also root-searchable and hotkey-bindable (no default hotkeys). |
| `lock`, `sleep`, `sleep displays` | Hidden run: hides Wicket and acts. |
| `restart`, `shut down`, `log out` | Hands off directly to native macOS confirmation dialogs. |
| `empty trash` | If Finder can count Trash, opens a review showing count + **Empty Trash** action; else invokes Finder directly. |
| `eject` | Lists eligible external devices/volumes; choose one or **Eject All** and view per-device results. |
| `volume`, `mute` | Canvas with current output, percentage slider (16 steps of 6.25%, applies on release), and mute switch; **Mute/Unmute Output** also at root. |
| `appearance`, `dark mode` | Shows Light/Dark/Auto (with effective style); switch in fixed mode or explicit **Use Dark**/**Use Light** in Auto + Settings link. |
| `hidden files` | Single row (**Show/Hide Hidden Files**) noting that relaunching Finder interrupts copies in progress. |
| `focus`, `dnd` | Shows active Focus or Off; with optional named Shortcut configured, offers DND toggle (naming any active Focus it would replace; off clears only DND). |
| `wi-fi` | On/off switch and Wi-Fi settings link. |
| `<pane> settings` | Opens the matching System Settings pane (`sound`, `wifi`, `bluetooth`, `accessibility`). |

Stateful pages reread on open, Refresh, and write; unavailable controls explain why and link to Settings. For custom user automations (e.g. work VPN), the agent writes a separate extension + hotkey rather than modifying System.

## 3. Design

### Packages and requests

- **`system`** (items-only): fixed `open` URLs for Settings panes; cross-extension `run` actions into the two Swift 6 contract 2 programs below.
- **`system-controls`** (no initial permissions): Sleep, Sleep Displays, volume, mute, eject; adds appearance once Automation lands.
- **`system-session`** (`"permissions":["accessibility"]`): Lock and hidden files; adds loginwindow/Finder Automation for session dialogs and Trash.

Gate all effects on `submitted:true`, exact `action`, and validated fields. Volume writes use absolute values and re-check if the default output changed while open. Root search filters static manifest rows only—read macOS state only on open, Refresh, or action.

### macOS adapters

Automation uses `AEDeterminePermissionToAutomateTarget` (with `askUserIfNeeded` on Allow).

| Action | Backend |
| --- | --- |
| Sleep | `IOPMSleepSystem` as console user. |
| Sleep Displays | `/usr/bin/pmset displaysleepnow` (no permission). |
| Lock | After hiding Wicket, post ⌃⌘Q via Quartz `.privateState` source with explicit flags (needs Accessibility). |
| Restart / Shut Down / Log Out | Apple Events `rrst`, `rsdn`, `logo` to `loginwindow`. |
| Empty Trash | Finder `count items of trash` and `empty trash` on submit. |
| Eject | Enumerate external ejectable volumes, call `NSWorkspace.unmountAndEjectDevice(at:)` per volume; group by whole disk for display only; include Time Machine, exclude internal/startup/network/disk images. |
| Volume & mute | Core Audio HAL settable volume/mute on default output (independent capability checks, read back). |
| Appearance | System Events `dark mode` + `AppleInterfaceStyleSwitchesAutomatically` for Auto. |
| Hidden files | `CFPreferencesCopyAppValue`/`Set` `AppleShowAllFiles` for `com.apple.finder` + relaunch Finder (no permission). |
| Settings panes | Fixed `x-apple.systempreferences:` URLs (`com.apple.Sound-Settings.extension`, `com.apple.wifi-settings-extension`, `com.apple.BluetoothSettings`, `com.apple.Focus-Settings.extension`, `com.apple.Appearance-Settings.extension`, `com.apple.Network-Settings.extension`, `com.apple.Accessibility-Settings.extension`), falling back to parent section. |
| Focus | User-configured Shortcut via `/usr/bin/shortcuts run` (read + set). |
| Wi-Fi | `CWInterface.powerOn()` / `setPower(_:)` via `CWWiFiClient` (verify behavior with Location denied and `requireAdministratorForPower` before placing). |

## 4. What exists today & gaps

- Items-only filtering ([CommandDirectory.swift](../../Sources/WicketApp/CommandDirectory.swift)), canvas fields ([PageField.swift](../../Sources/WicketApp/PageField.swift)), and cross-extension item hotkeys ([LauncherModel.swift](../../Sources/WicketApp/LauncherModel.swift), [Navigator.swift](../../Sources/WicketApp/Navigator.swift)) already work.
- Gaps: Automation permission gate; real-Mac verification of loginwindow consent and Wi-Fi power permissions.

## 5. Implementation plan (when unparked)

1. `system` items + verified Settings links + `system-controls` (Sleep, Sleep Displays, volume, eject).
2. `system-session` (Lock, hidden files).
3. Automation gate → session dialogs, Empty Trash, appearance.
4. Focus.
5. Wi-Fi (in whichever folder matches verified permissions).

Unit-test effects with `@testable import` and injected closures (like [ShellTests.swift](../../Tests/WicketTests/ShellTests.swift)); run headless only for unsubmitted reads and `--query` with a temporary `WICKET_CONFIG_DIR`.

## 6. Open question

Should Lock optionally call private `SACLockScreenImmediate` (`login.framework` via `dlsym`, falling back to ⌃⌘Q under [GlassBlur's private-API rules](../../AGENTS.md))? Start with ⌃⌘Q unless the owner approves the private symbol.
