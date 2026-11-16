# Codex Pet Hunger Meter User Guide

Codex Pet Hunger Meter is a local macOS companion overlay that draws usage-limit rings around Codex Pet. It does not modify Codex or pet assets. It reads local Codex state and usage information, then draws a transparent overlay that follows the pet.

## 1. Requirements

- macOS 13 or later (tested on macOS 27.0.1; older versions have not been runtime-tested)
- Xcode Command Line Tools
- Codex desktop app
- Codex Pet enabled and visible on screen
- Commands run from this repository root

## 2. Run Without Installing

For temporary use:

```bash
tools/run-hunger-meter.sh
```

This command builds the app every time, then runs the executable inside `build/CodexPetHungerMeter.app`. It is best for development and quick checks.

To stop it, choose `Quit` from the `Pet Meter` menu in the macOS menu bar.

## 3. Install

To install it as a login item:

```bash
tools/install-hunger-meter.sh
```

The installer does the following:

- Builds the app
- Copies it to `~/Applications/CodexPetHungerMeter.app`
- Creates `~/Library/LaunchAgents/com.codex-pet.hunger-meter.plist`
- Loads and starts the LaunchAgent with `launchctl`
- Writes stdout to `/tmp/codex-pet-hunger-meter.out.log`
- Writes stderr to `/tmp/codex-pet-hunger-meter.err.log`

After installation, the app starts automatically when you log in to macOS.

To start it again after choosing `Quit`, open `Home > Applications > CodexPetHungerMeter.app` in Finder, or search for `Pet Meter` in Spotlight. The app does not stay in the Dock; when it launches, `Pet Meter` appears again in the macOS menu bar.

## 4. Uninstall

To remove the installed app and login item:

```bash
tools/uninstall-hunger-meter.sh
```

The uninstaller removes:

- `~/Library/LaunchAgents/com.codex-pet.hunger-meter.plist`
- `~/Applications/CodexPetHungerMeter.app`
- The app preference domain `com.codex-pet.hunger-meter`

It does not delete or modify Codex, Codex Pet, `~/.codex/auth.json`, or `~/.codex/logs_2.sqlite`.

## 5. Turn ON / OFF

When the app is running, `Pet Meter` appears in the macOS menu bar.

- `Hide Hunger Meter`: hides the overlay
- `Show Hunger Meter`: shows the overlay again
- `Refresh Now`: manually refreshes usage and reset-time data
- `Quit`: quits the app

`Hide Hunger Meter` only turns the overlay display off. It does not quit the app. The visibility setting is saved and reused on the next launch.

To fully stop the app, choose `Quit`. To also stop login-time startup, run `tools/uninstall-hunger-meter.sh`.

## 6. Reading the Display

### Rings

- Outer ring: weekly limit remaining
- Inner ring: 5-hour limit remaining
- Longer ring means more remaining capacity
- Shorter ring means less remaining capacity

For recognized personal Pro plans, a successful live weekly response with no 5h window and no malformed/conflicting window shows `5h No Limit`: a static full pastel rainbow and `5h ---`. A real 5h window always takes priority. Unknown data shows a gray ring and `—`, never a false 0%.

The percentages show remaining capacity, not used capacity. The app converts `used_percent` from the live endpoint into `100 - used_percent`.

### Badges

- `Weekly 82%`: weekly limit remaining
- `5h 83%`: 5-hour limit remaining
- Top `W yyyy/MM/dd HH:mm`: weekly reset date and time
- Top `5h HH:mm`: 5-hour reset time

Dates and times are shown in local time.

### Size Adjustment

The ring size automatically follows the current Codex Pet size.

To fine-tune it, hover over the food-bowl image. A small bar appears below the bowl. Drag the bar left or right to adjust the ring scale relative to the pet size. The adjustment is saved in the app settings and reused on the next launch.

Clicking the food bowl still triggers manual refresh. Only dragging the bar is treated as a size adjustment.

### Menu Status

The `Pet Meter` menu shows:

- `Outer Weekly`: same value as the outer weekly ring
- `Inner 5h`: same value as the inner 5-hour ring
- `Weekly Reset`: weekly reset date and time
- `5h Reset`: 5-hour reset time
- `Last Success`: when the last successful response was obtained
- `Data Source`: `Live` / `Cached` / `Unavailable`

`Data Source` meanings:

- `Live`: directly fetched from the ChatGPT usage endpoint
- `Cached`: the last successful live response held in memory for this account (at most 300 seconds old, with passed reset periods marked unknown)
- `Unavailable`: no usable response is available; unknown periods show a gray ring and `—`

## 7. Refresh Behavior

The app automatically refreshes every 20 seconds and when macOS wakes. Overlapping refresh requests coalesce. Changing accounts clears previous data.

Automatic refresh does not hide or replay the rings and badges. It only updates the values and ring amounts.

Manual refresh methods:

- Click the food-bowl image
- Choose `Refresh Now` from the `Pet Meter` menu

Manual refresh plays a short visual confirmation animation. The rings briefly refill and the information badges fade back in. The food-bowl image remains visible.

## 8. Mouse Behavior

The overlay normally passes mouse input through to Codex Pet and the chat UI behind it.

The only exception is the food-bowl image. Clicking the bowl triggers manual refresh.

When the size bar is visible, only the food bowl and the bar receive mouse input. Everywhere else continues to pass input through to Codex Pet and the chat UI.

If you cannot drag the pet or type in chat, an old running process may still be active. Choose `Quit` from the `Pet Meter` menu, then start the app again.

## 9. Status and Preview Commands

To check parsed usage without opening the overlay:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status
```

For the optional, unverified legacy log diagnostic only (account identity unknown; never used by the overlay):

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status --cached-only
```

To generate a preview image:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --preview build/hunger-meter-preview.png --preview-fixture pro-no-limit --size 180 --side right --adjustment 1.0
```

The preview `--size` value is treated as the Codex Pet width. Codex Pet currently clamps width to roughly `80`-`224` px.

## 10. Data and Privacy

For live refresh, the app reads the Codex OAuth token from `~/.codex/auth.json` in memory and calls the ChatGPT usage endpoint `/backend-api/wham/usage`.

If live refresh fails, it reuses only a same-account successful response held in memory for up to 300 seconds. A passed reset makes that period unknown. There is no persisted usage cache and no automatic log fallback.

The app does not:

- Modify Codex
- Modify Codex Pet images
- Print, save, or export tokens (the access token is sent only to the HTTPS usage endpoint)
- Save usage responses
- Save screenshots while running (explicit preview commands write synthetic images)
- Save pet position history

The only saved app settings are overlay visibility and the ring size fine-tune value.

See `SECURITY.md` for more details.

## 11. Troubleshooting

### The overlay does not appear

- Make sure Codex Pet is visible on screen.
- If the menu says `Show Hunger Meter`, choose it to turn the overlay back on.
- Restart with `tools/run-hunger-meter.sh`.

### The data looks stale

- Check `Data Source` and `Last Success` in the `Pet Meter` menu.
- If the source is `Cached`, live refresh failed and the app is temporarily using the last same-account success in memory. The compact `Cached HH:mm` badge shows its time.
- Use `Refresh Now` or click the food bowl to manually refresh.

### The login item does not start

Reinstall:

```bash
tools/install-hunger-meter.sh
```

If it still does not start, inspect the logs:

```bash
tail -n 100 /tmp/codex-pet-hunger-meter.err.log
tail -n 100 /tmp/codex-pet-hunger-meter.out.log
```

### Remove everything installed by this tool

```bash
tools/uninstall-hunger-meter.sh
```

Developer verification: `tools/verify-hunger-meter.sh` builds and runs deterministic self-tests and synthetic PNG previews without auth, network, real logs, or preference writes. Fixtures: `normal`, `pro-no-limit`, `unknown`, `cached`. `--anchor-status` reads only pet geometry and reports the resolved screen/layout. Current bounds use global x/y; legacy mascot offsets and explicit sizes remain supported. Width follows the active owner’s pet-width override, then `[desktop]` in `~/.codex/config.toml`, then the 112 px default. The width is rounded and clamped to 80–224 px; height uses the current 192:208 aspect ratio. Each source file has its own change signature, so resizing follows after its setting save completes without restarting. A transient unreadable or partial config retains the last known width; a valid Reset/removal restores the default. Legacy explicit mascot dimensions remain supported.

Current pet centering: when one screen exposes a unique native Codex pet window matching the shipped physics layout, the overlay resolves its live center from owner/layer/bounds metadata. This follows resizes even when saved x/y has not changed. If geometry is unsupported or ambiguous, it keeps a known center through size-only changes and uses actual saved position changes for moves; a cold start in that fallback cannot prove a stale saved center. No screenshots, titles, accessibility control, or process attachment are used. Legacy measured dimensions remain separate. `--anchor-status` reports native geometry versus saved/size-tracking fallback.


The release app ZIP, `codex-pet-meter-0.1.1-macos-arm64.zip`, is separate from the source ZIP and targets Apple silicon. There is no Intel prebuilt. It is ad-hoc signed, not Developer ID signed or notarized, and comes with a SHA-256 checksum. Use the scripts above to install from the source ZIP.
