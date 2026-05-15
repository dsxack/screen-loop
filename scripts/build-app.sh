#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-release}"
APP_NAME="Screen Loop"
APP_BUNDLE="$ROOT_DIR/.build/app/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}"

BUILD_ARGS=(-c "$CONFIGURATION" --product ScreenRecorderApp)
if [[ -n "${ARCHS:-}" ]]; then
    for arch in $ARCHS; do
        BUILD_ARGS+=(--arch "$arch")
    done
fi

swift build "${BUILD_ARGS[@]}"
BIN_DIR="$(swift build "${BUILD_ARGS[@]}" --show-bin-path)"
EXECUTABLE="$BIN_DIR/ScreenRecorderApp"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$EXECUTABLE" "$MACOS_DIR/ScreenRecorderApp"
cp "$ROOT_DIR/AppBundle/Info.plist" "$CONTENTS_DIR/Info.plist"

if command -v codesign >/dev/null 2>&1; then
    codesign \
        --force \
        --sign - \
        --requirements '=designated => identifier "com.dsxack.screen-loop"' \
        "$APP_BUNDLE" >/dev/null 2>&1 || true
fi

echo "$APP_BUNDLE"
