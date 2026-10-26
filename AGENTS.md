# ax: agent notes

`ax` is a small macOS command-line tool that presses buttons in Xcode's Device Hub and in the app running on a simulator, through the accessibility API. Use it when a simulator control has no `simctl` or `devicectl` equivalent, most of all the iPhone Duo poses.

Repo: https://github.com/hipporasy/devicehub-ax (public, MIT). Release v0.1.0 has a universal binary.

## Install

```bash
curl -fL -o ax.zip https://github.com/hipporasy/devicehub-ax/releases/latest/download/ax-macos-universal.zip
unzip ax.zip && mv ax /usr/local/bin/
```

Or build from source: `swift build -c release`, binary at `.build/release/ax`.

The terminal app running `ax` needs Accessibility access (System Settings > Privacy & Security > Accessibility). If it is missing, `ax` exits with a message saying so; ask the user to grant it, do not try to work around it.

## Commands

```bash
ax list                            # dump the accessibility tree of Device Hub
ax pose open                       # iPhone Duo: closed | partial | open
ax press "Rotate Right"            # press a Device Hub button by label
ax press Progress --role AXRadio   # press a tab in the app on the simulator
ax press "Start Reading"           # press a button in the app on the simulator
```

- `list` prints one element per line: `role | title | description | identifier | help | value selected enabled`. Grep it for `AXButton` or `AXRadioButton` to find labels.
- `press` matches the label against title, description, identifier and help, and presses the first match whose role contains one of `--role` (default `Button|Radio`). Exit code 1 with "Nothing matched" when no element matches.
- `--app NAME` targets another app (executable name or bundle id); `--pid PID` targets a process directly. Default is Device Hub.

## Device Hub labels (Xcode 27.1)

Device window buttons: `Home` (device home screen), `Screenshot`, `Record`, `Rotate Right`, `Closed`, `Partially Open`, `Open`.

The app running on the simulator appears in the same tree: tab bar items as `AXRadioButton` with their tab titles, buttons by their accessibility labels.

Label clash: Device Hub's `Home` button sends the simulator to its home screen. To press an app tab called Home, use `ax press Home --role AXRadio`.

## Gotchas

1. **Device Hub needs a visible device window.** A hidden or minimised window drops out of the accessibility tree and `ax list` comes back nearly empty. Run `open -a /Applications/Xcode.app/Contents/Applications/DeviceHub.app` to bring it forward.
2. **The pose thumbnail lies.** The sidebar image can still read `Closed` after `ax pose open`. Check the displays instead (next point).
3. **Duo screenshots: name the inner display.** `xcrun simctl io <udid> screenshot` captures the outer display even when the Duo is open. Get the inner display's id and pass it:
   ```bash
   INNER=$(xcrun simctl io "$DEVICE" enumerate | awk '/UUID:/{id=$2} /Default width: 2007/{print id; exit}')
   xcrun simctl io "$DEVICE" screenshot --display="$INNER" shot.png   # 2853 x 2007
   ```
   Outer display captures are 1398 x 2034 (or 2034 x 1398 rotated).
4. **Swipes go to the outer display.** AXe, `xcui swipe` and similar tools land on the Duo's outer screen. Use `ax press` for the inner screen. Content off screen in a lazy list is not in the tree, so it cannot be pressed until it scrolls into view.
5. **Device Hub's pid is -1 in NSWorkspace.** `ax` already handles this by reading the process table; if you script around it, use `pgrep -x DeviceHub`.
6. **App Store Connect.** `APP_IPHONE_DUO` takes 2853 x 2007 or 2007 x 2853. PNGs with an alpha channel are rejected; convert with `sips -s format jpeg -s formatOptions 95 in.png --out out.jpg`.

## Example: Duo screenshot pass

```bash
DEVICE=<iPhone Duo UDID>
ax pose open
xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100
INNER=$(xcrun simctl io "$DEVICE" enumerate | awk '/UUID:/{id=$2} /Default width: 2007/{print id; exit}')
ax press Home --role AXRadio && sleep 2 && xcrun simctl io "$DEVICE" screenshot --display="$INNER" 1-home.png
ax press Activities --role AXRadio && sleep 2 && xcrun simctl io "$DEVICE" screenshot --display="$INNER" 2-activities.png
```

## Limits

- Tested only with Xcode 27.1 on macOS 27. Labels can change between Xcode versions; run `ax list` first.
- No swipe, scroll or typing; press only.
- The release binary is ad-hoc signed, not notarized. A copy saved from a browser needs `xattr -d com.apple.quarantine ax` once; `curl` downloads do not.
