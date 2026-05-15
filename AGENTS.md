# AGENTS.md

## Scope
These instructions apply to the entire repository.

## Repository Shape
- Swift Package Manager project targeting macOS 14.
- Main package manifest: `Package.swift`.
- Core library sources: `Sources/ScreenRecorderCore`.
- App executable sources: `Sources/ScreenRecorderApp`.
- Tests target declared as `ScreenRecorderCoreTests`.

## Working Rules
- Prefer small, local changes that match the existing Swift style and package structure.
- Keep app-specific code in `Sources/ScreenRecorderApp` and reusable recording logic in `Sources/ScreenRecorderCore`.
- Do not introduce new dependencies unless they are necessary and justified.
- When changing package structure or linker settings, update `Package.swift` in the same change.

## Validation
- Use `make` targets as the project interface; do not call SwiftPM directly unless explicitly debugging the Makefile itself.
- Build with `make build`.
- Run tests with `make test`.
- For app-entry changes, prefer validating the app bundle with `make app`; use `make run` only when the environment allows launching the GUI app.

## Installed App Workflow
- When the user asks to restart or update the running app, build it with `make app` first.
- The user-facing installed app lives at `~/Applications/Screen Loop.app`; do not treat `.build/app/Screen Loop.app` as the installed app.
- To restart the user-facing app after a build, stop the existing `ScreenRecorderApp` process, replace `~/Applications/Screen Loop.app` with `.build/app/Screen Loop.app`, then open `~/Applications/Screen Loop.app`.
- If sandbox permissions block replacing or opening the installed app, request approval rather than silently launching the `.build/app` copy.

## Platform Notes
- This package targets macOS 14 and uses Apple frameworks including AppKit, AVFoundation, CoreGraphics, CoreMedia, CoreVideo, and ScreenCaptureKit.
- Screen capture and app-launch behavior may require a macOS session with the right permissions.
- Do not assume headless execution can fully validate screen-capture behavior.
