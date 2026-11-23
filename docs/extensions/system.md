# System extension

**Parked.** The owner parked System until its permissions (Automation, and permission checks per action) are discussed; see [Official extensions](README.md). Its shared-work numbers refer to an earlier list.

## 1. Summary

System puts macOS actions and Settings panes within a few keystrokes. It is a tier 1 catalog extension under the [official extension decisions](README.md). It reads the state needed for each action on demand. Monitor owns ongoing CPU, memory and network measurements.

## 2. User experience

| What the user types | What happens |
| --- | --- |
| `system` | Opens a native list that filters as the user types. Its items are also searchable at the root. |
| `lock`, `sleep` or `sleep displays` | Return hides Wicket and performs the chosen action. |
| `restart`, `shut down` or `log out` | Return hands off directly to the native macOS confirmation dialog and any unsaved-work prompts. |
| `empty trash` | If Finder can count its Trash, open a review that shows the count and requires choosing **Empty Trash**. If the count is unavailable, invoke Finder directly. Finder may show its own warning. |
| `eject` | Lists eligible devices and their mounted volumes. Choose a device or **Eject All** to eject in one step and see the result per device. |
| `volume` or `mute` | The Volume canvas shows the current output, a percentage slider and a mute switch. Return advances the slider by 6.25 percentage points (16 steps across the range). Dragging applies on release. **Mute Output** and **Unmute Output** are also root actions. |
| `appearance` or `dark mode` | Shows Light, Dark or Auto, including the effective style in Auto when known. Offer a Dark mode switch in fixed mode and explicit **Use Dark** or **Use Light** actions in Auto. **Open Appearance Settings** gives access to Auto. |
| `hidden files` | Shows one row, **Show Hidden Files** or **Hide Hidden Files**, based on Finder's current preference. The subtitle says that relaunching Finder interrupts Finder copies in progress. |
| `focus` or `dnd` | Shows the active Focus or Off. With the optional Shortcut configured, offer a Do Not Disturb switch when DND is on or no Focus is active. If another Focus is active, name it in the action that replaces it. Turning DND off clears only DND. |
| `wi-fi` | Shows a Wi-Fi on/off switch and a link to Wi-Fi settings. |
| `sound settings`, `wifi settings`, `bluetooth settings`, `accessibility settings` | Opens the named pane in macOS System Settings. |

Stateful pages read again on open, Refresh and after a write. When a control is unavailable, say why and offer the relevant Settings pane. Disk results distinguish successes from busy devices and other failures.

Users can bind a manifest item with **Set Hotkey…**. The hotkey does what Return on the item does, including opening a control or review when appropriate. No hotkeys ship preassigned.

For “Turn on my work VPN with Control–Option–V,” the agent writes an item and script in `extensions/work-vpn` and adds a hotkey to `wicket://work-vpn?item=connect` in `config.json`. The script uses the configured VPN's supported CLI or Shortcut.

## 3. Design

### Folders and requests

- **`system`** is items only. Settings rows use fixed `open` URLs. The other rows use cross-extension `run` actions into the two programs.
- **`system-controls`** starts with no permissions and owns Sleep, Sleep Displays, volume, mute and eject. It adds appearance and declares System Events when shared work 2 lands. With a folder-wide gate, this declaration also gates its other controls.
- **`system-session`** declares `"permissions":["accessibility"]` for Lock and later adds the loginwindow and Finder Automation targets for the session dialogs and Trash. The hidden-files adapter lives here and requires no permission itself.

Use Swift 6 programs with contract 2 manifests. Use visible runs for pages and disk results, and hidden runs when the effect provides its own feedback. Effects require `submitted:true`, a recognized named action, and validated fields. Pages use canvas fields for controls. Volume writes use absolute values. If the output changed while the page was open, show the new output before accepting a write. Show the actual percentage beside the slider and initialize the slider on its 6.25-point grid.

Root search and the System list filter indexed manifest rows. Read macOS state only on page entry, Refresh or a targeted action. Measure root latency and time to first usable view when building those paths.

### macOS adapters

Use [shared work 2, Permission checks and Automation](README.md#shared-work). Wicket's process calls `AEDeterminePermissionToAutomateTarget` for the target, with `askUserIfNeeded` enabled when the user chooses Allow. [Apple's Automation API guidance](https://developer.apple.com/videos/play/wwdc2019/701/)

| Action | Backend |
| --- | --- |
| Sleep | Call `IOPMSleepSystem` as the console user. |
| Sleep Displays | Run `/usr/bin/pmset displaysleepnow`. No permission is required. |
| Lock | After Wicket hides, post ⌃⌘Q with Quartz from a `.privateState` event source and set the flags explicitly so held hotkey modifiers cannot carry through. Posting requires Accessibility. |
| Restart, Shut Down, Log Out | Send loginwindow `rrst`, `rsdn` or `logo` respectively to show the native session dialogs. [Apple's session lifecycle](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/Lifecycle.html) |
| Empty Trash | Ask Finder to `count items of trash` and use Finder's `empty trash` command when submitted. Finder determines scope and handles its warning and protected or busy items. |
| Eject | Enumerate mounted volumes on external ejectable media and call `NSWorkspace.unmountAndEjectDevice(at:)` per volume. Group by whole disk for display only because `DADiskCopyWholeDisk` can return the synthesized APFS container. Include eligible Time Machine targets and report a busy failure. Exclude internal and startup media, network mounts and disk images. [NSWorkspace ejection API](https://developer.apple.com/documentation/appkit/nsworkspace/unmountandejectdevice%28at%3A%29) |
| Volume and mute | Use the settable Core Audio HAL volume and mute properties on the default output. Treat unsupported properties independently. Read back the result. |
| Appearance | Read and set `dark mode` in System Events' appearance preferences. Verify the global `AppleInterfaceStyleSwitchesAutomatically` preference for identifying Auto. Offer the Appearance pane if the mode is unavailable. |
| Hidden files | Read Finder's `AppleShowAllFiles` with `CFPreferencesCopyAppValue` for `com.apple.finder`. Write the requested preference and relaunch Finder. Report a write or relaunch failure. No permission is required by this adapter. |
| Settings panes | Use fixed `x-apple.systempreferences:` URLs and verify each route on supported macOS. Use the parent Settings section if the pane route fails. |
| Focus | Use one user-imported Shortcut, configured by name, with separate read and set operations through `/usr/bin/shortcuts run`. Check the active Focus before clearing DND or replacing the named Focus. Offer Focus settings if the Shortcut is unavailable. |
| Wi-Fi | Use `CWInterface.powerOn()` and `setPower(_:)` via `CWWiFiClient`. Apple documents possible administrator authentication for writes and lists no Location requirement for these power APIs. Verify both directions with Location denied on current macOS before deciding where the toggle belongs. [CoreWLAN power API](https://developer.apple.com/documentation/corewlan/cwinterface/setpower%28_%3A%29?language=objc) · [Administrator power setting](https://developer.apple.com/documentation/corewlan/cwconfiguration/requireadministratorforpower) |

Candidate Settings pane IDs from installed bundle metadata are `com.apple.Sound-Settings.extension`, `com.apple.wifi-settings-extension`, `com.apple.BluetoothSettings`, `com.apple.Focus-Settings.extension`, `com.apple.Appearance-Settings.extension`, `com.apple.Network-Settings.extension` and `com.apple.Accessibility-Settings.extension`.

## 4. What exists today

- [ExtensionScreen](../../Sources/WicketApp/CommandDirectory.swift) filters items-only manifests against the current input. [Canvas fields](../../Sources/WicketApp/PageField.swift) already support switches, fractional slider steps and named actions.
- [LauncherModel.press](../../Sources/WicketApp/LauncherModel.swift) resolves the item in its owning manifest and passes its first hidden `run` to [Navigator.runHidden](../../Sources/WicketApp/Navigator.swift). An explicit extension target resolves to the destination program, whose enablement and permission gate apply before the submitted run. A hotkey on a `system` item can already run an action in either program.

## 5. Gaps

Automation depends on shared work 2. On a signed build on a real Mac, check whether sending the session events to loginwindow prompts for consent at all. Verify the Wi-Fi power read and write requirements before placing the toggle.

## 6. Implementation plan

1. Build the `system` items and verify the Settings links. Add `system-controls` with Sleep, Sleep Displays, volume and eject.
2. Add `system-session` with Lock and hidden files.
3. Land shared work 2, then add the native session dialogs, Empty Trash and appearance.
4. Add Focus.
5. Add Wi-Fi in the folder that fits its verified permission requirements.

Test effects with `@testable import` and injected closures, as [ShellTests](../../Tests/WicketTests/ShellTests.swift) does. Cover submitted-action gating, hotkey dispatch, field values, unavailable controls and partial ejects. Use headless runs only for unsubmitted reads and `--query`, with a temporary `WICKET_CONFIG_DIR`. The owner verifies effects on a real Mac.

## 7. Open questions

Should Lock also try the private `SACLockScreenImmediate` symbol in `login.framework`? A direct call avoids keyboard layout and shortcut delivery issues, but the private symbol may disappear or change on a macOS update. Start with the shortcut. If the owner accepts the private call, resolve it optionally with `dlsym` and fall back to the shortcut when unavailable, following [GlassBlur's rules](../../AGENTS.md).
