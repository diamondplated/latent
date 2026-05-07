#!/bin/bash
# One-shot installer for Latent's CoreML models.
#
# Without this run, the model-dependent stages (Denoise, Artifact Removal,
# Face Restore, plus Real-ESRGAN super-resolution for Upscale) are
# placebos / fall back to Lanczos. After this run they're real ML.
#
# Models converted (and their sizes):
#   - Real-ESRGAN x2 super-resolution     ~64 MB
#   - NAFNet-SIDD denoiser                ~280 MB
#   - FBCNN JPEG artifact removal         ~340 MB
#   - GFPGAN v1.4 face restoration        ~340 MB
#   - OpenCLIP ViT-B/32 image+text        ~150 MB (each encoder)
#
# Total: ~1.2 GB, all stored in Resources/Models/. None of this gets
# committed to git (the .mlpackage extension is in .gitignore).
#
# Runs in a one-shot virtualenv so we don't pollute the system Python.
# Requires: Python 3.11+ and Xcode CommandLineTools (for the C compiler
# basicsr needs to build).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VENV="$REPO_ROOT/.venv-convert"
PYTHON="${PYTHON:-python3}"

echo "==> Latent local-model setup"
echo "    Total download: ~1.2 GB. This is a one-time setup."
echo

# 1. Create the venv (idempotent — skip if already there).
if [[ ! -d "$VENV" ]]; then
    echo "==> Creating venv at $VENV"
    "$PYTHON" -m venv "$VENV"
fi

# 2. Activate and install pinned deps.
# shellcheck disable=SC1091
source "$VENV/bin/activate"

echo "==> Installing Python dependencies (pinned in scripts/requirements.txt)"
pip install --quiet --upgrade pip
pip install --quiet -r "$REPO_ROOT/scripts/requirements.txt"

# 3. Run each conversion. They each check for an existing .mlpackage and
#    skip if found, so re-running this script is cheap.
echo
echo "==> Converting Real-ESRGAN x2 (super-resolution)"
"$PYTHON" "$REPO_ROOT/scripts/convert_realesrgan.py"

echo
echo "==> Converting NAFNet (denoise — the answer to grainy photos)"
"$PYTHON" "$REPO_ROOT/scripts/convert_nafnet.py"

echo
echo "==> Converting FBCNN (JPEG artifact removal)"
"$PYTHON" "$REPO_ROOT/scripts/convert_fbcnn.py"

echo
echo "==> Converting GFPGAN v1.4 (face restoration)"
"$PYTHON" "$REPO_ROOT/scripts/convert_gfpgan.py"

echo
echo "==> Converting OpenCLIP ViT-B/32 (image + text encoders for search)"
"$PYTHON" "$REPO_ROOT/scripts/convert_openclip.py"

echo
echo "==> Done."
echo "    Installed models:"
ls -lh "$REPO_ROOT/Resources/Models/"*.mlpackage 2>/dev/null || echo "    (none — check the per-script logs above for failures)"
echo
echo "Restart Latent (Cmd-Q then re-open) and the disabled toggles in"
echo "the enhancement panel will light up green. Open a grainy photo,"
echo "expand Denoise, click Enabled, and you'll see real NAFNet output."
