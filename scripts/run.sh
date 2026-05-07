#!/bin/bash
# Build + kill-running + open. Use this instead of `open build/Latent.app`
# after a code change — `open` alone brings the existing instance to the
# front, so a stale binary keeps running and you never see your fix.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

echo "==> killing any running Latent"
killall Latent 2>/dev/null || true
sleep 0.3

echo "==> ./scripts/build_app.sh"
./scripts/build_app.sh

echo "==> open build/Latent.app"
open build/Latent.app
