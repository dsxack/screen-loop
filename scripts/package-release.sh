#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFO_PLIST="$ROOT_DIR/AppBundle/Info.plist"
APP_NAME="Screen Loop"
APP_BUNDLE="$ROOT_DIR/.build/app/$APP_NAME.app"
EXECUTABLE="$APP_BUNDLE/Contents/MacOS/ScreenRecorderApp"
DIST_DIR="$ROOT_DIR/dist"
PACKAGE_ARCHS="${PACKAGE_ARCHS:-arm64 x86_64}"
EXPECTED_TAG="${GITHUB_REF_NAME:-${1:-}}"
REQUIRE_UNIVERSAL_PACKAGE="${REQUIRE_UNIVERSAL_PACKAGE:-0}"

VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")"
if [[ -n "$EXPECTED_TAG" && "$EXPECTED_TAG" != "v$VERSION" ]]; then
    echo "Tag $EXPECTED_TAG does not match app version v$VERSION" >&2
    exit 1
fi

rm -rf "$DIST_DIR"
mkdir -p "$DIST_DIR"

build_app() {
    local archs="$1"
    CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$ROOT_DIR/.build/module-cache}" \
        ARCHS="$archs" \
        CONFIGURATION="${CONFIGURATION:-release}" \
        bash "$ROOT_DIR/scripts/build-app.sh"
}

archive_label() {
    local archs="$1"
    if [[ "$archs" == *" "* ]]; then
        echo "macos-universal"
    else
        echo "macos-$archs"
    fi
}

has_xcbuild() {
    xcrun -find xcbuild >/dev/null 2>&1 ||
        [[ -x "/Library/Developer/SharedFrameworks/XCBuild.framework/Versions/A/Support/xcbuild" ]]
}

REQUESTED_ARCHS="$PACKAGE_ARCHS"
HOST_ARCH="$(uname -m)"
ACTIVE_ARCHS="$REQUESTED_ARCHS"
BUILD_ARCHS="$REQUESTED_ARCHS"

if [[ "$REQUESTED_ARCHS" == "native" || "$REQUESTED_ARCHS" == "$HOST_ARCH" ]]; then
    ACTIVE_ARCHS="$HOST_ARCH"
    BUILD_ARCHS=""
fi

if [[ "$BUILD_ARCHS" == *" "* ]] && ! has_xcbuild; then
    if [[ "$REQUIRE_UNIVERSAL_PACKAGE" == "1" ]]; then
        echo "Universal SwiftPM builds require xcbuild from a full Xcode installation." >&2
        exit 1
    fi

    ACTIVE_ARCHS="$HOST_ARCH"
    BUILD_ARCHS=""
    echo "xcbuild is unavailable; falling back to native $ACTIVE_ARCHS package." >&2
    build_app "$BUILD_ARCHS"
elif ! build_app "$BUILD_ARCHS"; then
    if [[ "$REQUIRE_UNIVERSAL_PACKAGE" == "1" ]]; then
        exit 1
    fi

    ACTIVE_ARCHS="$HOST_ARCH"
    BUILD_ARCHS=""
    echo "Package build failed; falling back to native $ACTIVE_ARCHS package." >&2
    build_app "$BUILD_ARCHS"
fi

if [[ ! -d "$APP_BUNDLE" ]]; then
    echo "Missing app bundle: $APP_BUNDLE" >&2
    exit 1
fi

if command -v lipo >/dev/null 2>&1; then
    LIPO_INFO="$(lipo -info "$EXECUTABLE")"
    echo "$LIPO_INFO"
    for arch in $ACTIVE_ARCHS; do
        if [[ "$LIPO_INFO" != *"$arch"* ]]; then
            echo "Expected $EXECUTABLE to include $arch" >&2
            exit 1
        fi
    done
fi

ARCHIVE_NAME="ScreenLoop-$VERSION-$(archive_label "$ACTIVE_ARCHS").zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"

(
    cd "$APP_BUNDLE/.."
    COPYFILE_DISABLE=1 ditto --norsrc -c -k --keepParent "$APP_NAME.app" "$ARCHIVE_PATH"
)

shasum -a 256 "$ARCHIVE_PATH" > "$ARCHIVE_PATH.sha256"

echo "$ARCHIVE_PATH"
echo "$ARCHIVE_PATH.sha256"
