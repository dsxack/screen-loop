# Contributing

Screen Loop is a Swift Package Manager project targeting macOS 14.

Use the Makefile targets as the project interface:

```sh
make build
make test
make app
```

For release packaging:

```sh
make package
```

Keep reusable recording logic in `Sources/ScreenRecorderCore` and app-specific AppKit or ScreenCaptureKit behavior in `Sources/ScreenRecorderApp`. Avoid new dependencies unless they are necessary for the change.

Screen capture, login-item behavior, and permission prompts need a real macOS session for full validation. Headless CI can build and run unit tests, but it cannot fully prove the capture workflow.
