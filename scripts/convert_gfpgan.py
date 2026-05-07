#!/usr/bin/env python3
"""Convert GFPGAN (face restoration) from PyTorch to CoreML.

GFPGAN's architecture lives in the upstream repo (TencentARC/GFPGAN). The
script clones the repo on first run and uses its GFPGANv1Clean network
(the StyleGAN2-based variant the official inference scripts use).

Output: Resources/Models/face-restore-gfpgan.mlpackage.

Usage:
    source .venv-convert/bin/activate
    pip install -r scripts/requirements.txt
    python3 scripts/convert_gfpgan.py

Tested with: Python 3.11, torch 2.4, coremltools 8.0.

Notes:
- GFPGAN operates on 512×512 face crops normalized to [-1, 1] (see Swift
  TensorSpec.gfpgan). Don't change the input size — the model is hard-coded
  to it via internal upsampling layers.
- We export only the restored-image output; the StyleGAN latent codes the
  PyTorch model also returns aren't useful downstream.
- GFPGAN bundles GFPGANv1.4.pth; this script uses v1.4 for the cleanest
  identity preservation. Other variants (v1.3, RestoreFormer) require
  different architectures and aren't covered here.
"""

from pathlib import Path
import subprocess
import sys
import urllib.request

REPO_ROOT = Path(__file__).resolve().parent.parent
WEIGHTS_DIR = REPO_ROOT / "scripts" / "weights"
GFPGAN_REPO_DIR = REPO_ROOT / "scripts" / "GFPGAN"
OUTPUT_DIR = REPO_ROOT / "Resources" / "Models"
OUTPUT_PATH = OUTPUT_DIR / "face-restore-gfpgan.mlpackage"

WEIGHTS_URL = "https://github.com/TencentARC/GFPGAN/releases/download/v1.3.0/GFPGANv1.4.pth"
WEIGHTS_FILE = WEIGHTS_DIR / "GFPGANv1.4.pth"
GFPGAN_GIT = "https://github.com/TencentARC/GFPGAN.git"


def ensure_repo() -> None:
    if GFPGAN_REPO_DIR.exists():
        return
    print(f"cloning {GFPGAN_GIT}")
    subprocess.run(["git", "clone", "--depth", "1", GFPGAN_GIT, str(GFPGAN_REPO_DIR)], check=True)


def download_weights() -> None:
    if WEIGHTS_FILE.exists():
        return
    WEIGHTS_DIR.mkdir(parents=True, exist_ok=True)
    print(f"downloading {WEIGHTS_URL}")
    urllib.request.urlretrieve(WEIGHTS_URL, WEIGHTS_FILE)


def build_model():
    sys.path.insert(0, str(GFPGAN_REPO_DIR))
    import torch
    from gfpgan.archs.gfpganv1_clean_arch import GFPGANv1Clean  # type: ignore[import-not-found]

    model = GFPGANv1Clean(
        out_size=512,
        num_style_feat=512,
        channel_multiplier=2,
        decoder_load_path=None,
        fix_decoder=False,
        num_mlp=8,
        input_is_latent=True,
        different_w=True,
        narrow=1,
        sft_half=True,
    )
    sd = torch.load(WEIGHTS_FILE, map_location="cpu", weights_only=True)
    keyname = "params_ema" if "params_ema" in sd else "params"
    model.load_state_dict(sd[keyname], strict=True)
    model.train(False)
    return model


def trace_and_convert(model):
    import torch
    import coremltools as ct
    from coremltools import TensorType

    example = torch.zeros(1, 3, 512, 512)

    # GFPGAN's forward returns (image, latent_codes). Wrap to expose only the image.
    class ImageOnly(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, x):
            out = self.m(x, return_rgb=False)
            return out[0] if isinstance(out, tuple) else out

    wrapped = ImageOnly(model)
    with torch.no_grad():
        traced = torch.jit.trace(wrapped, example)

    # Fixed 512×512 input — GFPGAN's StyleGAN backbone has hard-coded resolutions.
    inputs = [TensorType(name="input", shape=ct.Shape(shape=(1, 3, 512, 512)))]
    print("converting (2-5 minutes — GFPGAN is the heaviest of the bundled models)…")
    mlmodel = ct.convert(
        traced,
        inputs=inputs,
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "GFPGAN v1.4 face restoration"
    mlmodel.author = "Tencent ARC (https://github.com/TencentARC/GFPGAN)"
    mlmodel.license = "Apache-2.0"
    mlmodel.input_description["input"] = "Face crop, 512×512 RGB, [-1, 1] range, NCHW"
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
        return 1
    except subprocess.CalledProcessError as e:
        print(f"git clone failed: {e}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
