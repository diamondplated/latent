#!/usr/bin/env python3
"""Convert NAFNet (denoise) from PyTorch to CoreML.

Targets NAFNet-SIDD-width64, the real-image denoiser trained on SIDD.
Output: Resources/Models/denoise-nafnet.mlpackage.

READ THIS FIRST — this script cannot fetch its own weights.

NAFNet publishes **no GitHub releases at all**; the pretrained models are
distributed through Google Drive and Baidu (see the upstream docs/SIDD.md).
There is no stable direct-download URL to automate, and neither of those hosts
serves a stable, checksummable artifact.

So you download the checkpoint yourself and put it at:

    scripts/weights/NAFNet-SIDD-width64.pth

The architecture comes from the NAFNet repository, which this script clones —
it is not in the `basicsr` PyPI package, despite what an earlier version of
this file assumed.

Usage:
    pip install -r scripts/requirements.txt
    # ...place the .pth as described above...
    python3 scripts/convert_nafnet.py
"""

from pathlib import Path
import subprocess
import sys
import urllib.request

REPO_ROOT = Path(__file__).resolve().parent.parent
WEIGHTS_DIR = REPO_ROOT / "scripts" / "weights"
OUTPUT_DIR = REPO_ROOT / "Resources" / "Models"
OUTPUT_PATH = OUTPUT_DIR / "denoise-nafnet.mlpackage"

# No WEIGHTS_URL: megvii-research/NAFNet has zero published releases, so the
# URL that used to live here always 404'd. Weights are supplied by hand.
WEIGHTS_FILE = WEIGHTS_DIR / "NAFNet-SIDD-width64.pth"
NAFNET_REPO_DIR = REPO_ROOT / "scripts" / "nafnet"
NAFNET_GIT = "https://github.com/megvii-research/NAFNet.git"
WEIGHTS_PAGE = "https://github.com/megvii-research/NAFNet/blob/main/docs/SIDD.md"


def ensure_repo() -> None:
    if NAFNET_REPO_DIR.exists():
        return
    print(f"cloning {NAFNET_GIT}")
    subprocess.run(["git", "clone", "--depth", "1", NAFNET_GIT, str(NAFNET_REPO_DIR)], check=True)


def download_weights() -> None:
    """Confirm the hand-placed checkpoint exists. Nothing to download."""
    from fetch import sha256_of

    if not WEIGHTS_FILE.exists():
        raise SystemExit(
            "\n".join([
                "",
                f"Missing weights: {WEIGHTS_FILE}",
                "",
                "NAFNet publishes no GitHub releases, so this cannot be fetched",
                "automatically. Download NAFNet-SIDD-width64.pth from the Google",
                "Drive or Baidu link on:",
                "",
                f"    {WEIGHTS_PAGE}",
                "",
                "then place it at the path above and re-run.",
                "",
            ])
        )
    # No pinned hash: with no canonical download there is nothing authoritative
    # to pin against. Print it so the file you are about to load is at least
    # visible, and so a changed checkpoint does not pass unnoticed.
    print(f"using {WEIGHTS_FILE}")
    print(f"  sha256 {sha256_of(WEIGHTS_FILE)}")


def build_model():
    import torch
    # basicsr on PyPI does NOT contain NAFNet — 1.4.2 ships 19 archs and this
    # is not among them. It lives in NAFNet's own vendored basicsr fork.
    sys.path.insert(0, str(NAFNET_REPO_DIR))
    from basicsr.models.archs.NAFNet_arch import NAFNet  # type: ignore[import-not-found]

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


if __name__ == "__main__":
    sys.exit(main())
