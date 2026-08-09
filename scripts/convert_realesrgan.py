#!/usr/bin/env python3
"""Convert Real-ESRGAN x2plus from PyTorch to CoreML (.mlpackage).

Run once to populate Resources/Models/upscale-realesrgan-x2.mlpackage. The
Swift app's ModelRegistry picks it up automatically from there. Without this
file Upscale falls back to Lanczos resize.

Usage:
    python3 -m venv .venv-convert
    source .venv-convert/bin/activate
    pip install -r scripts/requirements.txt
    python3 scripts/convert_realesrgan.py

Verified with Python 3.12, torch 2.7.1, coremltools 9.0 — converted end to
end and the CoreML output matched the PyTorch reference to within fp16
tolerance (max abs diff 0.0015).

The RRDBNet architecture is vendored in scripts/archs/ rather than imported
from basicsr; see that file for why.

Notes:
- Tracing happens at a fixed example resolution; the resulting CoreML model
  accepts the same range of dimensions via flexible-shape inputs (configured
  below). For tile-based execution at 512x512 (Swift TileExecutor default),
  any input <= 512 in both dims will work.
- We convert with FP16 weights for ~half the file size and faster ANE inference.
- Output color order is RGB, range [0, 1], matching the Swift TensorSpec.
"""

from pathlib import Path
import sys
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
REPO_ROOT = Path(__file__).resolve().parent.parent
WEIGHTS_DIR = REPO_ROOT / "scripts" / "weights"
OUTPUT_DIR = REPO_ROOT / "Resources" / "Models"
OUTPUT_PATH = OUTPUT_DIR / "upscale-realesrgan-x2.mlpackage"

WEIGHTS_URL = "https://github.com/xinntao/Real-ESRGAN/releases/download/v0.2.1/RealESRGAN_x2plus.pth"
# sha256 of the file at WEIGHTS_URL, verified on download. See scripts/fetch.py.
WEIGHTS_SHA256 = "49fafd45f8fd7aa8d31ab2a22d14d91b536c34494a5cfe31eb5d89c2fa266abb"
WEIGHTS_FILE = WEIGHTS_DIR / "RealESRGAN_x2plus.pth"


def download_weights() -> None:
    from fetch import download_verified

    download_verified(WEIGHTS_URL, WEIGHTS_FILE, WEIGHTS_SHA256)


def build_model():
    """RRDBNet architecture matching Real-ESRGAN x2plus weights."""
    import torch
    from archs.rrdbnet import RRDBNet

    model = RRDBNet(
        num_in_ch=3,
        num_out_ch=3,
        num_feat=64,
        num_block=23,
        num_grow_ch=32,
        scale=2,
    )
    state_dict = torch.load(WEIGHTS_FILE, map_location="cpu", weights_only=True)
    if "params" in state_dict:
        state_dict = state_dict["params"]
    elif "params_ema" in state_dict:
        state_dict = state_dict["params_ema"]
    model.load_state_dict(state_dict, strict=True)
    model.train(False)  # equivalent to model.eval(): inference mode, no dropout/BN updates
    return model


def trace_model(model):
    import torch

    # Trace at a representative tile size. The traced graph is flexible enough
    # for coremltools to accept a range of input dimensions via RangeDim.
    example_input = torch.zeros(1, 3, 128, 128)
    with torch.no_grad():
        traced = torch.jit.trace(model, example_input)
    return traced, example_input


def convert(traced, example_input):
    import coremltools as ct
    from coremltools import RangeDim, TensorType

    # Allow any dim from 64 to 1024 — covers TileExecutor's typical 256/512
    # tile sizes plus headroom for non-square edge tiles.
    input_shape = ct.Shape(shape=(1, 3, RangeDim(64, 1024), RangeDim(64, 1024)))
    inputs = [TensorType(name="input", shape=input_shape)]

    print("converting to CoreML (this can take 1-3 minutes)…")
    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "Real-ESRGAN x2plus super-resolution"
    mlmodel.author = "Xintao Wang et al. (https://github.com/xinntao/Real-ESRGAN)"
    mlmodel.license = "BSD"
    mlmodel.input_description["input"] = "RGB image, [0, 1] range, NCHW"
    return mlmodel


def main() -> int:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    if OUTPUT_PATH.exists():
        print(f"already exists: {OUTPUT_PATH}")
        print("delete it first if you want to re-convert")
        return 0

    try:
        download_weights()
        model = build_model()
        traced, example = trace_model(model)
        mlmodel = convert(traced, example)
        mlmodel.save(str(OUTPUT_PATH))
        print(f"\nsaved {OUTPUT_PATH}")
        print("Restart the app (or call ModelManager.shared.reset()) to pick it up.")
        return 0
    except ModuleNotFoundError as e:
        print(f"missing dependency: {e}", file=sys.stderr)
        print("install with: pip install -r scripts/requirements.txt", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
