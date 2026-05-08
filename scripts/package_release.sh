#!/bin/bash
# Build Latent.app and produce a Sparkle-ready zip archive.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

"$REPO_ROOT/scripts/build_app.sh"

APP_DIR="build/Latent.app"
if [[ ! -d "$APP_DIR" ]]; then
    echo "error: expected $APP_DIR to exist" >&2
    exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_DIR/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP_DIR/Contents/Info.plist")"
DIST_DIR="${DIST_DIR:-dist/appcast}"
ARCHIVE_NAME="Latent-${VERSION}.zip"
ARCHIVE_PATH="$DIST_DIR/$ARCHIVE_NAME"
NOTES_PATH="$DIST_DIR/Latent-${VERSION}.md"

mkdir -p "$DIST_DIR"
rm -f "$ARCHIVE_PATH" "$NOTES_PATH"

echo "==> archiving $ARCHIVE_PATH"
ditto -c -k --sequesterRsrc --keepParent "$APP_DIR" "$ARCHIVE_PATH"

cat > "$NOTES_PATH" <<EOF
# Latent ${VERSION}

Build ${BUILD_NUMBER}.

See the GitHub release notes for details.
EOF

echo
echo "Release archive:"
echo "  $ARCHIVE_PATH"
echo "Release notes:"
echo "  $NOTES_PATH"
