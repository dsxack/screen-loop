# Screen Recorder

Native macOS menu bar recorder that keeps a rolling 60-minute recorded-media buffer for the main display or all displays and can save the last 1, 3, 5, 15, 30, 45, or 60 minutes.

The default recording profile is `Readable Text` (`1080p-ish`, `15fps`). The main menu chooses between `Record Main Display`, `Record All Displays`, and `Recording Off`; the choice persists across app restarts. Advanced items are available by holding `Option`/`Alt` while the menu is open.

## Build

```sh
make build
make test
make app
```

The app bundle is created at:

```text
.build/app/Screen Recorder.app
```

## Run

```sh
open ".build/app/Screen Recorder.app"
```

The app runs as a menu bar item without a Dock icon. On first launch, use the menu item to grant Screen Recording permission if macOS has not already granted it. If macOS applies the permission but the system "Quit & Reopen" button does not bring the menu bar item back, the app schedules its own relaunch; `Relaunch Screen Recorder` is also available in the app menu while permission is pending.

The app enables `Launch at Login` by default on first launch. You can turn it off from the `Option`/`Alt` menu.

Local builds are ad-hoc signed with a stable designated requirement so macOS privacy permissions survive app rebuilds more reliably. If an older build left Screen Recording permissions stuck, reset the old entry once:

```sh
tccutil reset ScreenCapture local.screen-recorder
```

Menu actions:

- `Record Main Display`: record only the main display.
- `Record All Displays`: record each connected display into its own rolling buffer.
- `Recording Off`: stop recording while keeping existing buffers available for saving.
- `Save Last` > `1 Minute` or `3/5/15/30/45/60 Minutes`: export a clip from the rolling buffer. In `All Displays` mode, the app creates a timestamped folder with one `.mov` per display, and each display is exported up to its own available history.
- Hold `Option`/`Alt` while the menu is open to show `Available History`, `Buffer Size`, the current `Profile`, `Launch at Login`, `Open Buffer Folder`, and `Save and Trim Last`.

If less history is available than requested, the app saves the available history and names the file or all-display folder with the longest actual exported duration. In `All Displays` mode, the `Option`/`Alt` menu shows one history row per display.

To trim immediately after saving, hold `Option`/`Alt` and choose a duration under `Save and Trim Last`. For all-display recordings, the app saves every display first, then opens the `Trim Clip` window with a display picker. `Replace Original` and `Create New` affect only the selected display file.

The recorder listens for macOS sleep/wake and active-session notifications. If recording was enabled before sleep, capture is restarted automatically after wake.

Saved clips go to:

```text
~/Movies/Screen Recorder
```

Temporary ring-buffer segments are stored under:

```text
~/Library/Application Support/ScreenRecorder/Buffer
```

On launch, the app recovers finalized per-display buffer segments that still fit inside the last 60 minutes of recorded media. Older, invalid, or unfinished temporary segments are removed.
