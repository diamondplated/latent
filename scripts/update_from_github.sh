#!/bin/bash
# Developer updater: fast-forward main from GitHub, rebuild, and reinstall.
# This is not Sparkle. It is the local-owner workflow for this checkout.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

if [[ -n "$(git status --porcelain)" ]]; then
    echo "error: working tree has local changes; commit or stash before updating" >&2
    git status --short
    exit 1
fi

git fetch origin
git checkout main
git pull --ff-only origin main

"$REPO_ROOT/scripts/install_app.sh"
