#!/bin/bash
# Build and install Latent into /Applications.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

"$REPO_ROOT/scripts/build_app.sh"

APP_NAME="Latent"
APP_DIR="build/${APP_NAME}.app"
DEST="/Applications/${APP_NAME}.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister"

echo "==> installing $DEST"
rm -rf "$DEST"
cp -R "$APP_DIR" "/Applications/"

echo "==> registering document types"
"$LSREGISTER" -f "$DEST"

if [[ "${OPEN_AFTER_INSTALL:-1}" == "1" ]]; then
    open "$DEST"
fi

echo
echo "Installed $DEST"
