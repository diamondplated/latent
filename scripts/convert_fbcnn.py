#!/usr/bin/env python3
"""Convert FBCNN (JPEG artifact removal) from PyTorch to CoreML.

FBCNN's architecture lives in the upstream repo, not basicsr. The script
clones the repo to scripts/fbcnn/ on first run, then loads the architecture
from there.

Output: Resources/Models/artifact-removal-fbcnn.mlpackage.

Usage:
    source .venv-convert/bin/activate
    pip install -r scripts/requirements.txt
    python3 scripts/convert_fbcnn.py

Tested with: Python 3.11, torch 2.4, coremltools 8.0.

Notes:
- FBCNN takes color JPEG as input, predicts both a denoised image AND a
  quality factor (QF). We expose only the image output to CoreML — the QF
  prediction is internal to the model and not used downstream.
- The official FBCNN model has separate weights for color and grayscale.
  This script uses the color variant (`fbcnn_color.pth`).
"""

from pathlib import Path
import os
import subprocess
import sys
import urllib.request

REPO_ROOT = Path(__file__).resolve().parent.parent
WEIGHTS_DIR = REPO_ROOT / "scripts" / "weights"
FBCNN_REPO_DIR = REPO_ROOT / "scripts" / "fbcnn"
OUTPUT_DIR = REPO_ROOT / "Resources" / "Models"
OUTPUT_PATH = OUTPUT_DIR / "artifact-removal-fbcnn.mlpackage"

WEIGHTS_URL = "https://github.com/jiaxi-jiang/FBCNN/releases/download/v1.0/fbcnn_color.pth"
WEIGHTS_FILE = WEIGHTS_DIR / "fbcnn_color.pth"
FBCNN_GIT = "https://github.com/jiaxi-jiang/FBCNN.git"


def ensure_repo() -> None:
    if FBCNN_REPO_DIR.exists():
        return
    print(f"cloning {FBCNN_GIT}")
    subprocess.run(["git", "clone", "--depth", "1", FBCNN_GIT, str(FBCNN_REPO_DIR)], check=True)


def download_weights() -> None:
    if WEIGHTS_FILE.exists():
        return
    WEIGHTS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"downloading {WEIGHTS_URL}")
    urllib.request.urlretrieve(WEIGHTS_URL, WEIGHTS_FILE)


def build_model():
    sys.path.insert(0, str(FBCNN_REPO_DIR))
    import torch
    # The repo exposes its network in models/network_fbcnn.py.
    from models.network_fbcnn import FBCNN  # type: ignore[import-not-found]

    model = FBCNN(in_nc=3, out_nc=3, nc=[64, 128, 256, 512], nb=4)
    state_dict = torch.load(WEIGHTS_FILE, map_location="cpu", weights_only=True)
    model.load_state_dict(state_dict, strict=True)
    model.train(False)
    return model


def trace_and_convert(model):
    import torch
    import coremltools as ct
    from coremltools import RangeDim, TensorType

    # FBCNN downsamples 3 times → input must be divisible by 8.
    example = torch.zeros(1, 3, 256, 256)

    # FBCNN's forward returns (image, qf_estimate). Wrap so only the image
    # is exposed to the CoreML conversion.
    class ImageOnly(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, x):
            out = self.m(x)
            return out[0] if isinstance(out, tuple) else out

    wrapped = ImageOnly(model)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    inputs = [TensorType(name="input", shape=ct.Shape(shape=(1, 3, RangeDim(64, 1024), RangeDim(64, 1024))))]
    print("converting (1-3 minutes)…")
    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "FBCNN JPEG artifact removal (color)"
    mlmodel.author = "Jiaxi Jiang et al. (https://github.com/jiaxi-jiang/FBCNN)"
    mlmodel.license = "Apache-2.0"
    mlmodel.input_description["input"] = "JPEG-degraded RGB image, [0, 1], NCHW; H,W multiples of 8"
    return mlmodel


def main() -> int:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    if OUTPUT_PATH.exists():
        print(f"already exists: {OUTPUT_PATH}")
        return 0
    try:
        ensure_repo()
        download_weights()
        model = build_model()
        mlmodel = trace_and_convert(model)
        mlmodel.save(str(OUTPUT_PATH))
        print(f"saved {OUTPUT_PATH}")
        return 0
    except ModuleNotFoundError as e:
        print(f"missing dependency: {e}", file=sys.stderr)
        print("install with: pip install -r scripts/requirements.txt", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as e:
        print(f"git clone failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
