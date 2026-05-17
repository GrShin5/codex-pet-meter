# Codex Pet Meter User Guide

Codex Pet Meter is an unofficial macOS helper app that shows usage-limit rings around Codex Pet.

It does not modify Codex or Codex Pet images. It reads local Codex state and usage information on your Mac, then draws a transparent overlay that follows the pet.

## 1. Requirements

- macOS
- Codex desktop app
- Codex Pet visible on screen
- Xcode Command Line Tools
- This repository folder

If Xcode Command Line Tools are not installed, run:

```bash
xcode-select --install
```

## 2. Install

Open Terminal in this folder and run:

```bash
tools/install-hunger-meter.sh
```

The installer:

- Builds the app
- Copies it to `~/Applications/CodexPetHungerMeter.app`
- Creates `~/Library/LaunchAgents/com.codex-pet.hunger-meter.plist`
- Starts the app immediately
- Writes stdout to `/tmp/codex-pet-hunger-meter.out.log`
- Writes stderr to `/tmp/codex-pet-hunger-meter.err.log`

When it launches, `Pet Meter` appears in the macOS menu bar. The app also starts automatically when you log in to macOS.

## 3. Quit and Reopen

To stop temporarily, choose `Quit` from the `Pet Meter` menu.

To reopen, open `Home > Applications > CodexPetHungerMeter.app` in Finder, or search for `Pet Meter` in Spotlight. The app does not stay in the Dock; when it launches, `Pet Meter` appears again in the macOS menu bar.

## 4. Update

If you installed with Git:

```bash
cd codex-pet-meter
git pull
tools/install-hunger-meter.sh
```

If you downloaded a ZIP, download the latest ZIP from GitHub again, unzip it, open Terminal in the new folder, and run:

```bash
tools/install-hunger-meter.sh
```

Running the installer again replaces the installed app in `~/Applications/CodexPetHungerMeter.app` and reloads the login item.

## 5. Uninstall

To remove the installed app and login item:

```bash
tools/uninstall-hunger-meter.sh
```

This removes:

- `~/Library/LaunchAgents/com.codex-pet.hunger-meter.plist`
- `~/Applications/CodexPetHungerMeter.app`
- The app preference domain `com.codex-pet.hunger-meter`

It does not delete or modify Codex, Codex Pet, `~/.codex/auth.json`, or `~/.codex/logs_2.sqlite`.

## 6. Reading the Display

- Outer ring: weekly limit remaining
- Inner ring: 5-hour limit remaining
- Top badge: reset times
- Food bowl: click to refresh manually

The percentages show remaining capacity, not used capacity. The app converts `used_percent` from the live endpoint or local log into `100 - used_percent`.

## 7. Size Adjustment

The ring size automatically follows the current Codex Pet size.

To fine-tune it, hover over the food-bowl image. A small bar appears below the bowl. Drag the bar left or right to adjust the ring scale relative to the pet size. The adjustment is saved in the app settings and reused on the next launch.

Clicking the food bowl still triggers manual refresh. Only dragging the bar is treated as a size adjustment.

## 8. Menu

The `Pet Meter` menu includes:

- `Hide Hunger Meter`: hides the overlay
- `Show Hunger Meter`: shows the overlay again
- `Refresh Now`: refreshes usage and reset times
- `Outer Weekly`: same value as the outer weekly ring
- `Inner 5h`: same value as the inner 5-hour ring
- `Weekly Reset`: weekly reset date and time
- `5h Reset`: 5-hour reset time
- `Data Updated`: when the displayed data was obtained
- `Data Source`: `Live` / `Cached` / `Unavailable`
- `Quit`: quits the app

`Hide Hunger Meter` only hides the overlay. It does not quit the app.

## 9. Mouse Behavior

The overlay normally passes mouse input through to Codex Pet and the chat UI behind it.

The only exception is the food-bowl image and the size bar while it is visible. Clicking the bowl refreshes usage data. Dragging the size bar changes the ring scale. Everywhere else continues to pass input through.

If you cannot drag the pet or type in chat, an old running process may still be active. Choose `Quit` from the `Pet Meter` menu, then start the app again.

## 10. Ask Codex to Install It

If you are not comfortable using Terminal, give Codex this repository URL and ask it to install the app for you.

Recommended prompt:

```text
Please install and set up this macOS Codex Pet Meter from the repository below:

https://github.com/GrShin5/codex-pet-meter

Please inspect the README first, install only from this repository, explain each step in plain language, run the verification script if possible, and do not print, copy, or upload any local tokens or Codex account files.
```

Codex should download or clone the repository, run `tools/install-hunger-meter.sh`, confirm that `Pet Meter` appears in the macOS menu bar, and explain how to uninstall it.

## 11. Status and Preview Commands

To check parsed usage without opening the overlay:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status
```

To check the cached no-network path only:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --status --cached-only
```

To generate a preview image:

```bash
tools/build-hunger-meter.sh
build/codex-pet-hunger-meter --preview build/hunger-meter-preview.png --size 180
```

The preview `--size` value is treated as the Codex Pet width. Codex Pet currently clamps width to roughly `80`-`224` px.

## 12. Data and Privacy

For live refresh, the app reads the Codex OAuth token from `~/.codex/auth.json` in memory and calls the ChatGPT usage endpoint.

If live refresh fails, it reads only usage-limit events from the local `~/.codex/logs_2.sqlite` log.

This tool does not:

- Modify Codex
- Modify Codex Pet images
- Modify Codex Pet size settings
- Print, save, export, or transmit tokens
- Save usage responses
- Save screenshots
- Save pet position history

The only saved app settings are overlay visibility and the ring size fine-tune value.

See [SECURITY.md](../SECURITY.md) for details.

## 13. Troubleshooting

### The overlay does not appear

- Make sure Codex Pet is visible on screen.
- If the menu says `Show Hunger Meter`, choose it to turn the overlay back on.
- Restart with `tools/run-hunger-meter.sh`.

### The data looks stale

- Check `Data Source` and `Data Updated` in the `Pet Meter` menu.
- If the source is `Cached`, live refresh failed and the app is using the local log.
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

## 14. Create a Release ZIP

To create a distributable ZIP:

```bash
scripts/package-release.sh
```

The ZIP is written to `dist/`.
