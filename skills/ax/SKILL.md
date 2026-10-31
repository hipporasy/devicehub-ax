---
name: ax
description: Fold, unfold and rotate iOS simulators in Xcode 27's Device Hub, tap the app on the iPhone Duo's inner screen, wait for elements and take App Store–ready screenshots, using the `ax` command-line tool. Use when a task needs the iPhone Duo open or closed, a simulator rotated, or the app on the simulator driven by its accessibility labels, especially on the Duo's inner display, where AXe, idb and simctl-based taps land on the outer screen.
---

# ax

`ax` drives Device Hub and the app on the simulator through the macOS accessibility API. Every command takes `--json`, confirms its action, and on failure returns an `error`, a `hint` and the closest labels on the screen.

## Before anything

```bash
command -v ax || {
  curl -fL -o /tmp/ax.zip https://github.com/hipporasy/devicehub-ax/releases/latest/download/ax-macos-universal.zip
  unzip -o /tmp/ax.zip -d ~/.local/bin && export PATH="$HOME/.local/bin:$PATH"
}
ax doctor
```

If `ax doctor` reports `accessibility` as failing, stop and ask the user to enable their terminal app in System Settings > Privacy & Security > Accessibility. Do not work around it. For any other failing check, follow its `fix:` line.

## Drive the app

```bash
ax screen                          # what is on the device's screen
ax tap "Continue"                  # press by label or identifier
ax wait "Welcome"                  # wait for the next screen (default 10 s)
ax wait "Loading" --gone --timeout 30
ax scroll --to "Settings"          # page down until the row is on the screen (--in LABEL picks the list)
ax type "hello" --into Search      # set a text field's text, read back to confirm
ax screenshot shot.jpg             # the active display, no alpha channel
```

Read labels from `ax screen`; do not guess them. When `tap` fails, its `hint` lists the closest labels. When it reports `ambiguous`, use the exact label or add `--role AXRadio` (tabs) or `--role AXButton`.

## Device

```bash
ax state                           # pose, orientation, displays
ax pose open                       # closed | partial | open; returns once the matching display is on
ax rotate                          # one quarter turn right, confirmed
ax control Home                    # Device Hub's own buttons: see `ax controls`
```

With several simulators booted and more than one Device Hub window open, run `export AX_DEVICE=<UDID>` once, or pass `--device <UDID>` to each command.

## Exit codes

0 done · 1 not found · 2 fix the command · 3 ask for Accessibility access · 4 Device Hub, window or simulator missing · 5 action not confirmed · 6 simctl or devicectl failed.

## Limits

- `tap` performs the accessibility press and `scroll` moves whole pages: no swipes, drags or long presses. Off-screen rows of a lazy list are not in the tree until `ax scroll --to` brings them in.
- `type` sets the value and cannot press Return. If it fails with `type_not_confirmed`, `ax tap` the field first to put it in edit mode.
- The Device Hub window must stay on screen (not minimised, not on another Space, Mac unlocked).
- `partial` and `open` both read as `unfolded` in `ax state`.

Full guide: https://github.com/hipporasy/devicehub-ax/blob/main/AGENTS.md
