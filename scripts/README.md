# scripts/

One-off utilities for populating the model bundle.

## convert_realesrgan.py

Converts Real-ESRGAN x2plus from PyTorch to CoreML and writes the result to
`Resources/Models/upscale-realesrgan-x2.mlpackage`. Once the file is in place,
the Swift `ModelRegistry` finds it and `Upscale.process()` uses it instead of
the Lanczos fallback.

Run it:

The converters require Python 3.11 exactly.

```bash
cd /path/to/photo-viewer

python3.11 -m venv .venv-convert
source .venv-convert/bin/activate
pip install -r scripts/requirements.txt

python3 scripts/convert_realesrgan.py
```

What happens:

1. Downloads `RealESRGAN_x2plus.pth` (~64MB) into `scripts/weights/` (gitignored).
2. Builds the RRDBNet architecture and loads weights.
3. Traces with PyTorch JIT at 128×128, then converts to a CoreML mlprogram with
   FP16 compute precision and flexible input shape (64–1024 in each dim).
4. Saves the `.mlpackage` (~64MB) to `Resources/Models/`.

Total runtime: 1–3 minutes on Apple Silicon, mostly during the coremltools
conversion pass.

If the conversion fails:

- **`ModuleNotFoundError`** — `pip install -r scripts/requirements.txt` in your venv.
- **PyTorch version mismatch** — basicsr 1.4.2 is happiest with torch 2.x. If pip
  resolves a different torch, pin both via `pip install torch==2.4.1 basicsr==1.4.2`.
- **coremltools failures on specific layers** — Real-ESRGAN is a well-known
  architecture and converts cleanly with coremltools 8.0. If you see ops
  marked unsupported, you're probably on coremltools 7.x; upgrade.

The `.mlpackage` is gitignored — it's too large for source control and any
contributor can regenerate it deterministically from the script.
