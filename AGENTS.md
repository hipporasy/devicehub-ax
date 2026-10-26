# ax: agent guide

`ax` drives Xcode's Device Hub and the app running on a simulator through the macOS accessibility API. Use it for what `simctl` and `devicectl` cannot do: fold and unfold the iPhone Duo, rotate, and tap the app on the Duo's inner screen, where touch-injection tools such as AXe and idb land on the outer screen.

It uses no private frameworks: only the accessibility API, `simctl` and `devicectl`. Every action is confirmed, every command takes `--json`, and failures say what to do next.

Repo: https://github.com/hipporasy/devicehub-ax

## Setup

```bash
curl -fL -o ax.zip https://github.com/hipporasy/devicehub-ax/releases/latest/download/ax-macos-universal.zip
unzip -o ax.zip && mkdir -p ~/.local/bin && mv ax ~/.local/bin/   # or anywhere on PATH
ax doctor
```

To build from source instead, run `swift build -c release`; the binary is at `.build/release/ax`.

Run `ax doctor` first. It checks Xcode, Accessibility access, Device Hub, its device windows and the booted simulators, and prints a `fix:` for each failure. If Accessibility access is missing, ask the user to grant it to their terminal app (System Settings > Privacy & Security > Accessibility). Do not try to work around it.

## Loop

1. `ax screen` lists what is on the device's screen.
2. `ax tap LABEL` presses an element by its label.
3. `ax wait LABEL` waits until the next screen has loaded.
4. `ax screenshot out.png` captures it.

```bash
ax pose open                         # unfold; returns once the inner display is on
ax tap Progress                      # a tab, a button, a row: anything with that label
ax wait "PAST 7 DAYS"                # the next screen has loaded
ax screenshot progress.png           # captures the active display, no alpha channel
ax tap "Start Reading" && ax wait "End session"
ax wait "Loading" --gone --timeout 20
```

## Commands

| Command | What it does |
|---|---|
| `ax doctor` | Checks the setup, with a fix for each failure. |
| `ax state` | Device, pose (`closed`, `unfolded` or `n/a`), orientation and displays. |
| `ax screen` | Elements on the device's screen: `role \| label \| identifier \| value \| flags`. Duplicates and unnamed containers are dropped. |
| `ax tap LABEL` | Presses an element on the screen. It matches title, description, identifier and help exactly; `--contains` matches a case-insensitive substring. Buttons and tabs win over text with the same label. Different elements that match is an error, not a guess. |
| `ax wait LABEL` | Waits until the element is on the screen (default 10 s); with `--gone`, until it is not. |
| `ax pose closed\|partial\|open` | Presses the pose button and waits until the matching display is on. |
| `ax rotate [N]` | Presses Rotate Right N times, confirming each quarter turn. |
| `ax screenshot PATH` | Captures the active display (`--display inner\|outer\|ID` to pick one). A `.jpg` path writes JPEG; any other path writes PNG. Neither has an alpha channel. |
| `ax controls` / `ax control LABEL` | Lists or presses Device Hub's own buttons under the device: Home, Screenshot, Record, Rotate Right, Closed, Partially Open, Open. |
| `ax list` / `ax press LABEL` | The raw accessibility tree, and a press anywhere in it. Use these for apps other than Device Hub (`--app`, `--pid`). |

Options: `--json`, `--device UDID|name`, `--timeout SECS`, `--contains`, `--role ROLES`, `--display WHICH`, `--no-verify`.

With one simulator booted, `ax` uses it. With several, pass `--device`: `ax` refuses rather than guess.

## Output and exit codes

With `--json`, every command prints one JSON object on stdout. On success it has `"ok": true` and the result. On failure it has `"ok": false`, `error`, `message`, and usually `hint`. A failure also carries `candidates` (the closest labels on the screen) or `matches` (the elements a label matched).

| Code | `error` | Meaning |
|---|---|---|
| 0 | | Done and confirmed |
| 1 | `not_found` | No element matched; try one of `candidates` |
| 2 | `usage`, `ambiguous`, `ambiguous_device`, `unknown_device` | Fix the command |
| 3 | `accessibility_denied` | Ask the user for Accessibility access |
| 4 | `app_not_running`, `no_device_window`, `no_booted_simulator`, `app_not_responding` | Device Hub, its window or the simulator is missing |
| 5 | `pose_not_confirmed`, `rotation_not_confirmed`, `disabled`, `still_present`, `press_failed` | The action did not take effect |
| 6 | `simulator_tool_failed` | `simctl` or `devicectl` failed |

## Gotchas

1. **Device Hub's window must be on screen.** A window that is minimised, on another Space, or behind a locked Mac drops out of the accessibility tree. `ax` reports `no_device_window`. Run `open -a DeviceHub` and select the simulator.
2. **`tap` presses; it does not touch.** It performs the element's accessibility action, so it cannot swipe, scroll, long-press or type. An element of a lazy list that is off screen is not in the tree until it scrolls into view.
3. **Swipes from other tools land on the outer screen.** AXe, idb and `xcui swipe` touch the Duo's outer display even when it is open.
4. **`partial` and `open` look the same in `ax state`.** Both turn the inner display on, and devicectl reports no hinge angle. The sidebar thumbnail in Device Hub is not reliable either.
5. **Labels can change between Xcode versions.** `ax controls` shows the current Device Hub buttons.
6. **App Store Connect.** `APP_IPHONE_DUO` takes the inner display: 2853 x 2007 or 2007 x 2853. `ax screenshot` writes no alpha channel, which App Store Connect requires.

## Duo screenshot pass

```bash
ax doctor || exit 1
xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100
ax pose open
# Labels below come from the app under test; read them from `ax screen`.
ax tap Home && ax wait "THIS WEEK" && ax screenshot shots/1-home.jpg
ax tap Activities && ax wait "START A SESSION" && ax screenshot shots/2-activities.jpg
ax pose closed && ax screenshot shots/3-cover.jpg   # the outer display, 1398 x 2034
```

`tap` only looks at the device's screen, so the app's Home tab never clashes with Device Hub's Home button. Use `ax control Home` for the Device Hub button.

## Limits

- Tested with Xcode 27.1 on macOS 27 and the iOS 27.1 iPhone Duo simulator.
- Simulators only. Device Hub must be running with the device's window open.
- The release binary is ad-hoc signed, not notarized. A copy downloaded with a browser needs `xattr -d com.apple.quarantine ax` once; one downloaded with `curl` does not.
