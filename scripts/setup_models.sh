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
# Requires: Python 3.11 exactly and Xcode CommandLineTools (for the C compiler
# basicsr needs to build).

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VENV="$REPO_ROOT/.venv-convert"
PYTHON="${PYTHON:-python3.11}"

python_minor_version() {
    "$1" -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' 2>/dev/null || true
}

python_install_hint() {
    echo "Install it with: brew install python@3.11" >&2
    echo 'Then run: PYTHON="$(brew --prefix python@3.11)/bin/python3.11" ./scripts/setup_models.sh' >&2
}

if ! command -v "$PYTHON" >/dev/null 2>&1; then
    echo "error: Latent model conversion requires Python 3.11 exactly; '$PYTHON' was not found." >&2
    python_install_hint
    exit 1
fi

PYTHON_VERSION="$(python_minor_version "$PYTHON")"
if [[ "$PYTHON_VERSION" != "3.11" ]]; then
    echo "error: Latent model conversion requires Python 3.11 exactly; '$PYTHON' is Python ${PYTHON_VERSION:-unknown}." >&2
    python_install_hint
    exit 1
fi

echo "==> Latent local-model setup"
echo "    Total download: ~1.2 GB. This is a one-time setup."
echo

# 1. Create the venv (idempotent — skip if already there).
if [[ -d "$VENV" ]]; then
    VENV_VERSION="$(python_minor_version "$VENV/bin/python")"
    if [[ "$VENV_VERSION" != "3.11" ]]; then
        echo "error: $VENV uses Python ${VENV_VERSION:-unknown}; remove it and rerun with Python 3.11." >&2
        exit 1
    fi
else
    echo "==> Creating venv at $VENV"
    "$PYTHON" -m venv "$VENV"
fi

# 2. Install pinned deps with the venv's Python.
VENV_PYTHON="$VENV/bin/python"

echo "==> Installing Python dependencies (pinned in scripts/requirements.txt)"
"$VENV_PYTHON" -m pip install --quiet --upgrade pip
"$VENV_PYTHON" -m pip install --quiet -r "$REPO_ROOT/scripts/requirements.txt"

# 3. Run each conversion. They each check for an existing .mlpackage and
#    skip if found, so re-running this script is cheap.
echo
echo "==> Converting Real-ESRGAN x2 (super-resolution)"
"$VENV_PYTHON" "$REPO_ROOT/scripts/convert_realesrgan.py"

echo
echo "==> Converting NAFNet (denoise — the answer to grainy photos)"
"$VENV_PYTHON" "$REPO_ROOT/scripts/convert_nafnet.py"

echo
echo "==> Converting FBCNN (JPEG artifact removal)"
"$VENV_PYTHON" "$REPO_ROOT/scripts/convert_fbcnn.py"

echo
echo "==> Converting GFPGAN v1.4 (face restoration)"
"$VENV_PYTHON" "$REPO_ROOT/scripts/convert_gfpgan.py"

echo
echo "==> Converting OpenCLIP ViT-B/32 (image + text encoders for search)"
"$VENV_PYTHON" "$REPO_ROOT/scripts/convert_openclip.py"

echo
echo "==> Done."
echo "    Installed models:"
ls -lh "$REPO_ROOT/Resources/Models/"*.mlpackage 2>/dev/null || echo "    (none — check the per-script logs above for failures)"
echo
echo "Restart Latent (Cmd-Q then re-open) and the disabled toggles in"
echo "the enhancement panel will light up green. Open a grainy photo,"
echo "expand Denoise, click Enabled, and you'll see real NAFNet output."
