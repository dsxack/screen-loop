#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 3 || $# -gt 4 ]]; then
    echo "Usage: $0 TAP_REPO VERSION SHA256 [ARCHIVE_NAME]" >&2
    exit 2
fi

TAP_REPO="$1"
VERSION="$2"
SHA256="$3"
ARCHIVE_NAME="${4:-ScreenLoop-$VERSION-macos-universal.zip}"
CASK_DIR="$TAP_REPO/Casks"
CASK_PATH="$CASK_DIR/screen-loop.rb"

mkdir -p "$CASK_DIR"

cat > "$CASK_PATH" <<RUBY
# typed: false
# frozen_string_literal: true

cask "screen-loop" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/dsxack/screen-loop/releases/download/v#{version}/$ARCHIVE_NAME",
      verified: "github.com/dsxack/screen-loop/"
  name "Screen Loop"
  desc "Menu bar screen recorder with a rolling buffer for saving recent history"
  homepage "https://github.com/dsxack/screen-loop"

  depends_on macos: :sonoma

  app "Screen Loop.app"

  uninstall quit:       "com.dsxack.screen-loop",
            login_item: "Screen Loop"

  zap trash: [
    "~/Library/Application Support/Screen Loop",
    "~/Library/Preferences/com.dsxack.screen-loop.plist",
    "~/Movies/Screen Loop",
  ]

  caveats <<~EOS
    Screen Loop is not signed or notarized yet. If macOS blocks the first launch,
    remove quarantine manually:

      xattr -dr com.apple.quarantine "#{appdir}/Screen Loop.app"
  EOS
end
RUBY

ruby -c "$CASK_PATH"
echo "$CASK_PATH"
