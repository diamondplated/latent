#!/usr/bin/env python3
"""Convert OpenCLIP ViT-B/32 (image + text encoders) to CoreML.

Outputs:
- Resources/Models/openclip-vitb32-image.mlpackage   (used by CLIPImageEncoder)
- Resources/Models/openclip-vitb32-text.mlpackage    (used by CLIPTextEncoder)

The image encoder bakes CLIP's per-channel mean/std normalization in so the
Swift side only sends [0, 1] images. The text encoder takes pre-tokenized
77-element token-ID tensors — Swift must run BPE tokenization first.

Usage:
    source .venv-convert/bin/activate
    pip install -r scripts/requirements.txt
    python3 scripts/convert_openclip.py

Tested with: Python 3.11, torch 2.4, coremltools 8.0, open_clip_torch 2.24.

Notes:
- ViT-B/32 is the smallest "good" CLIP variant — 86M params, 224×224 input,
  512-dim embedding. Larger variants (ViT-L/14, ViT-H/14) give better
  retrieval accuracy at much higher inference cost. ViT-B/32 is the sweet
  spot for on-device search at folder-walk scale.
- The text encoder requires BPE tokenization (77-token context). The Swift
  side currently doesn't ship a tokenizer; image-to-image search works,
  text queries throw `tokenizerNotImplemented`. Porting `simple_tokenizer.py`
  is the next milestone for search.
"""

from pathlib import Path
import sys

REPO_ROOT = Path(__file__).resolve().parent.parent
OUTPUT_DIR = REPO_ROOT / "Resources" / "Models"
TOKENIZER_DIR = REPO_ROOT / "Resources" / "Tokenizer"
IMAGE_OUT = OUTPUT_DIR / "openclip-vitb32-image.mlpackage"
TEXT_OUT = OUTPUT_DIR / "openclip-vitb32-text.mlpackage"
MERGES_OUT = TOKENIZER_DIR / "clip-bpe-merges.txt"

CLIP_MEAN = (0.48145466, 0.4578275, 0.40821073)
CLIP_STD = (0.26862954, 0.26130258, 0.27577711)
IMAGE_SIZE = 224
CONTEXT_LENGTH = 77
EMBED_DIM = 512


def build_image_module(model):
    import torch

    class ImageEncoder(torch.nn.Module):
        def __init__(self, clip_visual):
            super().__init__()
            self.visual = clip_visual
            mean = torch.tensor(CLIP_MEAN).view(1, 3, 1, 1)
            std = torch.tensor(CLIP_STD).view(1, 3, 1, 1)
            self.register_buffer("mean", mean)
            self.register_buffer("std", std)

        def forward(self, x):
            # Input: [1, 3, H, W] in [0, 1].
            x = (x - self.mean) / self.std
            return self.visual(x)

    return ImageEncoder(model.visual)


def build_text_module(model):
    import torch

    class TextEncoder(torch.nn.Module):
        def __init__(self, clip):
            super().__init__()
            self.clip = clip

        def forward(self, tokens):
            # tokens: [1, 77] LongTensor of BPE IDs.
            return self.clip.encode_text(tokens)

    return TextEncoder(model)


def convert_image(model_module):
    import torch
    import coremltools as ct
    from coremltools import TensorType

    example = torch.zeros(1, 3, IMAGE_SIZE, IMAGE_SIZE)
    with torch.no_grad():
        traced = torch.jit.trace(model_module, example)

    print("converting image encoder…")
    mlmodel = ct.convert(
        traced,
        inputs=[TensorType(name="image", shape=(1, 3, IMAGE_SIZE, IMAGE_SIZE))],
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "OpenCLIP ViT-B/32 image encoder"
    mlmodel.author = "OpenAI / OpenCLIP (https://github.com/mlfoundations/open_clip)"
    mlmodel.license = "MIT"
    mlmodel.input_description["image"] = f"RGB image, [0, 1] range, NCHW {IMAGE_SIZE}×{IMAGE_SIZE}"
    return mlmodel


def convert_text(model_module):
    import torch
    import coremltools as ct
    from coremltools import TensorType

    example = torch.zeros(1, CONTEXT_LENGTH, dtype=torch.int32)
    with torch.no_grad():
        traced = torch.jit.trace(model_module, example)

    print("converting text encoder…")
    mlmodel = ct.convert(
        traced,
        inputs=[TensorType(name="tokens", shape=(1, CONTEXT_LENGTH), dtype=int)],
        compute_precision=ct.precision.FLOAT16,
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.macOS14,
        convert_to="mlprogram",
    )
    mlmodel.short_description = "OpenCLIP ViT-B/32 text encoder"
    mlmodel.author = "OpenAI / OpenCLIP (https://github.com/mlfoundations/open_clip)"
    mlmodel.license = "MIT"
    mlmodel.input_description["tokens"] = f"BPE token IDs, length {CONTEXT_LENGTH}"
    return mlmodel


def export_merges() -> None:
    """Write the BPE merges file the Swift tokenizer expects.

    Source: open_clip's bundled bpe_simple_vocab_16e6.txt.gz, decompressed
    to plain text. The Swift tokenizer caps at openai/CLIP's 48,894 merges.
    """
    if MERGES_OUT.exists():
        print(f"merges already present: {MERGES_OUT}")
        return

    import gzip
    import open_clip

    # open_clip ships the same merges file as openai/CLIP at simple_tokenizer/bpe_simple_vocab_16e6.txt.gz
    pkg_dir = Path(open_clip.__file__).parent
    candidate = pkg_dir / "bpe_simple_vocab_16e6.txt.gz"
    if not candidate.exists():
        # Newer open_clip may relocate the file.
        for p in pkg_dir.rglob("bpe_simple_vocab_16e6.txt.gz"):
            candidate = p
            break
    with gzip.open(candidate, "rt", encoding="utf-8") as f:
        text = f.read()

    TOKENIZER_DIR.mkdir(parents=True, exist_ok=True)
    MERGES_OUT.write_text(text, encoding="utf-8")
    print(f"saved {MERGES_OUT}")


def main() -> int:
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    if IMAGE_OUT.exists() and TEXT_OUT.exists() and MERGES_OUT.exists():
        print("encoders + merges already exist — delete to re-convert")
        return 0

    try:
        import torch
        import open_clip

        print("loading OpenCLIP ViT-B/32 (laion2b_s34b_b79k)…")
        model, _, _ = open_clip.create_model_and_transforms(
            "ViT-B-32",
            pretrained="laion2b_s34b_b79k",
        )
        model.train(False)

        if not IMAGE_OUT.exists():
            image_module = build_image_module(model)
            mlmodel = convert_image(image_module)
            mlmodel.save(str(IMAGE_OUT))
            print(f"saved {IMAGE_OUT}")

        if not TEXT_OUT.exists():
            text_module = build_text_module(model)
            mlmodel = convert_text(text_module)
            mlmodel.save(str(TEXT_OUT))
            print(f"saved {TEXT_OUT}")

        export_merges()

        return 0
    except ModuleNotFoundError as e:
        print(f"missing dependency: {e}", file=sys.stderr)
        print("install with: pip install open_clip_torch", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
