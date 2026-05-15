# Screen Recorder

Native macOS menu bar recorder that keeps a rolling 60-minute recorded-media buffer and can save the last 3, 5, 15, 30, 45, or 60 minutes.

The default recording profile is `Low Power` (`720p`, `15fps`). The menu includes a `Recording` toggle for pausing/resuming capture; advanced items are available by holding `Option`/`Alt` while the menu is open.

## Build

```sh
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift build
env CLANG_MODULE_CACHE_PATH=.build/module-cache swift test
bash scripts/build-app.sh
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

- `Recording`: pause or resume capture.
- `Save Last 3/5/15/30/45/60 Minutes`: export a clip from the rolling buffer.
- Hold `Option`/`Alt` while the menu is open to show `Available History`, `Profile`, `Launch at Login`, and `Open Buffer Folder`.

If less history is available than requested, the app saves the available history and names the file with the actual exported duration.

After a clip is saved, `Trim Clip` opens automatically. Use the preview with `Start` and `End` controls, then choose `Create New` or `Replace Original`.

The recorder listens for macOS sleep/wake and active-session notifications. If recording was enabled before sleep, capture is restarted automatically after wake.

Saved clips go to:

```text
~/Movies/Screen Recorder
```

Temporary ring-buffer segments are stored in:

```text
~/Library/Application Support/ScreenRecorder/Buffer
```

On launch, the app recovers finalized buffer segments that still fit inside the last 60 minutes of recorded media. Older, invalid, or unfinished temporary segments are removed.
