#!/bin/bash
# Package the Swift Package executable into a real macOS .app bundle.
#
# Why this exists: `swift build` emits a unix-style binary, but the OS needs
# a proper .app structure (Contents/MacOS, Contents/Info.plist, ...) to
# register CFBundleDocumentTypes — i.e., to make photo-viewer appear in
# Finder's "Open With…" menu for image files.
#
# Output: ./build/PhotoViewerApp.app — drop into /Applications or run in place.
#
# When the project migrates to an Xcode workspace this script gets retired:
# Xcode produces the .app via xcodebuild and adds code signing + the QL
# extension target.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

APP_NAME="PhotoViewerApp"
APP_DIR="build/${APP_NAME}.app"
BINARY_NAME="PhotoViewerApp"
INFO_PLIST="Resources/AppBundle/Info.plist"

# 1. Build release. `--product` (not `--target`) is what actually links the
#    executable; `--target` would only compile the module sources.
echo "==> swift build -c release --product $APP_NAME"
swift build -c release --product "$APP_NAME"

BINARY_PATH="$(swift build -c release --show-bin-path)/$BINARY_NAME"
if [[ ! -x "$BINARY_PATH" ]]; then
    echo "error: built binary not found at $BINARY_PATH" >&2
    exit 1
fi

# 2. Build the bundle scaffold.
echo "==> assembling $APP_DIR"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$BINARY_PATH" "$APP_DIR/Contents/MacOS/$BINARY_NAME"
chmod +x "$APP_DIR/Contents/MacOS/$BINARY_NAME"
cp "$INFO_PLIST" "$APP_DIR/Contents/Info.plist"

# 3. Optional: copy app icon if present. AppIcon.icns isn't checked into the
#    repo yet — when one is added, drop it at Resources/AppBundle/AppIcon.icns
#    and uncomment the CFBundleIconFile entry in Info.plist.
ICON="Resources/AppBundle/AppIcon.icns"
if [[ -f "$ICON" ]]; then
    cp "$ICON" "$APP_DIR/Contents/Resources/AppIcon.icns"
fi

# 4. Touch the bundle so Launch Services re-reads it. Without this, Finder
#    sometimes serves a stale Info.plist from its cache and won't show the
#    app in "Open With…".
touch "$APP_DIR"

echo
echo "Built $APP_DIR"
echo "  - To run:        open $APP_DIR"
echo "  - To install:    cp -r $APP_DIR /Applications/"
echo "  - Register types: /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f $APP_DIR"
