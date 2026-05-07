#!/usr/bin/env python3
"""Convert NAFNet (denoise) from PyTorch to CoreML.

Default config targets NAFNet-SIDD-width64 — the standard real-image denoiser
trained on the SIDD dataset. Output: Resources/Models/denoise-nafnet.mlpackage.

Usage:
    source .venv-convert/bin/activate
    pip install -r scripts/requirements.txt
    python3 scripts/convert_nafnet.py

Tested with: Python 3.11, torch 2.4, coremltools 8.0, basicsr 1.4.2.

Notes:
- NAFNet's architecture is in basicsr.archs.nafnet_arch.NAFNet.
- The SIDD weights URL below is the official NAFNet release. If it 404s
  (project moved), grab from the NAFNet GitHub releases page and update
  WEIGHTS_URL.
- Denoise quality is somewhat input-distribution dependent — NAFNet-SIDD
  is tuned for real-world camera noise. For Gaussian-noise data swap to
  NAFNet-GoPro or train your own; the conversion script is unchanged.
"""

from pathlib import Path
import sys
import urllib.request

REPO_ROOT = Path(__file__).resolve().parent.parent
WEIGHTS_DIR = REPO_ROOT / "scripts" / "weights"
OUTPUT_DIR = REPO_ROOT / "Resources" / "Models"
OUTPUT_PATH = OUTPUT_DIR / "denoise-nafnet.mlpackage"

WEIGHTS_URL = "https://github.com/megvii-research/NAFNet/releases/download/v1.0.0/NAFNet-SIDD-width64.pth"
WEIGHTS_FILE = WEIGHTS_DIR / "NAFNet-SIDD-width64.pth"


def download_weights() -> None:
    if WEIGHTS_FILE.exists():
        print(f"weights already present: {WEIGHTS_FILE}")
        return
    WEIGHTS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"downloading {WEIGHTS_URL}")
    urllib.request.urlretrieve(WEIGHTS_URL, WEIGHTS_FILE)


def build_model():
    import torch
    from basicsr.archs.nafnet_arch import NAFNet

    model = NAFNet(
        img_channel=3,
        width=64,
        enc_blk_nums=[2, 2, 4, 8],
        middle_blk_num=12,
        dec_blk_nums=[2, 2, 2, 2],
    )
    state_dict = torch.load(WEIGHTS_FILE, map_location="cpu", weights_only=True)
    if "params" in state_dict:
        state_dict = state_dict["params"]
    elif "params_ema" in state_dict:
        state_dict = state_dict["params_ema"]
    model.load_state_dict(state_dict, strict=True)
    model.train(False)
    return model


def trace_and_convert(model):
    import torch
    import coremltools as ct
    from coremltools import RangeDim, TensorType

    # NAFNet's encoder downsamples 4 times; input dims must be divisible by 16.
    # 256 picks a clean multiple that traces fast and matches the Swift TileExecutor.
    example = torch.zeros(1, 3, 256, 256)
    with torch.no_grad():
        traced = torch.jit.trace(model, example)

    # Restrict input dims to multiples of 16 via a constrained RangeDim.
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
    mlmodel.short_description = "NAFNet-SIDD denoise"
    mlmodel.author = "Megvii Research (https://github.com/megvii-research/NAFNet)"
    mlmodel.license = "MIT"
    mlmodel.input_description["input"] = "Noisy RGB image, [0, 1] range, NCHW; H and W must be multiples of 16"
    return mlmodel


def main() -> int:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    if OUTPUT_PATH.exists():
        print(f"already exists: {OUTPUT_PATH} (delete to re-convert)")
        return 0
    try:
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


if __name__ == "__main__":
    sys.exit(main())
