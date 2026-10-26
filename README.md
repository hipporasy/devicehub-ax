# devicehub-ax

A tiny command-line tool that presses buttons in Xcode's **Device Hub** (and any other macOS app) through the accessibility API.

Xcode 27 replaced Simulator.app with Device Hub. Some simulator controls, such as the iPhone Duo poses (Closed, Partially Open, Open), have no `simctl` or `devicectl` equivalent. `ax` lets scripts and coding agents press them, and press buttons inside the app running on the simulator too.

```bash
ax pose open                      # unfold the iPhone Duo simulator
ax press "Rotate Right"           # any Device Hub button by its label
ax press Progress --role AXRadio  # a tab in the app running on the simulator
ax list | grep AXButton           # see what can be pressed
```

## Install

### Download

Grab `ax-macos-universal.zip` from the [latest release](https://github.com/hipporasy/devicehub-ax/releases/latest) (Apple silicon and Intel, macOS 13 or later):

```bash
curl -fL -o ax.zip https://github.com/hipporasy/devicehub-ax/releases/latest/download/ax-macos-universal.zip
unzip ax.zip && xattr -d com.apple.quarantine ax 2>/dev/null
mv ax /usr/local/bin/
```

The binary is ad-hoc signed, not notarized. Downloads made with `curl` are not quarantined; one saved from a browser is, which is what the `xattr` line clears.

### Build from source

Needs Swift 5.9 or later (Xcode's toolchain is fine).

```bash
git clone https://github.com/hipporasy/devicehub-ax.git
cd devicehub-ax
swift build -c release
cp .build/release/ax /usr/local/bin/   # or anywhere on your PATH
```

Then give the terminal app you run it from (Terminal, iTerm, Ghostty, your IDE) **Accessibility** access: System Settings > Privacy & Security > Accessibility. `ax` asks for it on first run.

## Usage

```
ax list [--app NAME | --pid PID] [--role ROLES]
ax press LABEL [--app NAME | --pid PID] [--role ROLES]
ax pose closed|partial|open [--app NAME | --pid PID]
```

- `list` prints the accessibility tree, one element per line: `role | title | description | identifier | help | value selected enabled`.
- `press` presses the first element whose title, description, identifier or help equals `LABEL` and whose role matches `--role` (default `Button|Radio`).
- `pose` presses Device Hub's Closed, Partially Open or Open button.
- `--app` takes an executable name or bundle identifier and defaults to `DeviceHub`. `--pid` targets a process directly.

Device Hub must have a device window open; a hidden or minimised window drops out of the accessibility tree.

### Device Hub controls seen so far

Home, Screenshot, Record, Rotate Right, Closed, Partially Open, Open, plus the app's own elements (tabs show up as `AXRadioButton`, buttons by their accessibility label). Run `ax list` to see what your version exposes.

When a Device Hub button and an app element share a label (Device Hub's **Home** button and an app's **Home** tab), pass `--role AXRadio` to pick the tab.

## Recipe: iPhone Duo screenshots of the inner display

`simctl io screenshot` captures the outer display by default, even after the Duo is opened. Capture the inner display by its ID:

```bash
DEVICE=<iPhone Duo simulator UDID>
ax pose open

# The inner display is the one 2007 points wide (2853 x 2007 landscape)
INNER=$(xcrun simctl io "$DEVICE" enumerate | awk '/UUID:/{id=$2} /Default width: 2007/{print id; exit}')

xcrun simctl status_bar "$DEVICE" override --time 9:41 --batteryState charged --batteryLevel 100
xcrun simctl io "$DEVICE" screenshot --display="$INNER" home.png
```

App Store Connect takes these as the `APP_IPHONE_DUO` display type (2853 x 2007 or 2007 x 2853). It rejects PNGs with an alpha channel, so convert first:

```bash
sips -s format jpeg -s formatOptions 95 home.png --out home.jpg
```

## Notes

- Tested with Xcode 27.1 (Device Hub) on macOS 27.
- Device Hub reports a process ID of -1 to `NSWorkspace`, so `ax` finds it in the process table by executable name.
- Swipes from tools such as AXe or `idb` land on the Duo's outer display; use accessibility presses for the inner display.

## License

MIT
