# scripts/

User-run utilities for model conversion and app packaging. Nothing here runs inside the app.

## Model conversion

The app never downloads models. Running these scripts is the one explicit step that fetches weights
and converts them to CoreML. See the README's Quick start for the short version, and
[THIRD_PARTY_MODELS.md](../THIRD_PARTY_MODELS.md) for what each model is.

```bash
./scripts/setup_models.sh
```

That builds a Python 3.11 venv in `.venv-convert/`, installs `scripts/requirements.txt` into it, and
runs every converter. The converters write `.mlpackage` files to `Resources/Models/`, and
`convert_openclip.py` also writes the BPE merges file to `Resources/Tokenizer/`. Both directories are
gitignored. The Real-ESRGAN, NAFNet and FBCNN weights download through `fetch.py`, which checks each
file against a pinned SHA-256 and stops on a mismatch. OpenCLIP weights come through open_clip's own
loader and aren't pinned yet (#41).

| Script | Model | Output |
| --- | --- | --- |
| `convert_realesrgan.py` | Real-ESRGAN x2plus (RRDBNet vendored in `archs/`) | Upscale |
| `convert_nafnet.py` | NAFNet-SIDD | Denoise |
| `convert_fbcnn.py` | FBCNN | Artifact Removal |
| `convert_openclip.py` | OpenCLIP ViT-B/32 image and text encoders, plus tokenizer merges | Search |

To run a single converter by hand:

```bash
python3.11 -m venv .venv-convert
source .venv-convert/bin/activate
pip install -r scripts/requirements.txt
python3 scripts/convert_realesrgan.py
```

### Pinned versions

`requirements.txt` is the source of truth. Don't pin anything older to get past an error. `torch` is
held at a version that clears CVE-2025-32434 (a `torch.load(weights_only=True)` bypass, which is
exactly how these scripts load downloaded `.pth` files). `requirements.txt` explains the pin, and
[SECURITY.md](../SECURITY.md) covers the advisory. Packages that `requirements.txt` says were dropped
stay dropped.

### If a conversion fails

- **`ModuleNotFoundError`**: you're outside the venv, or `pip install -r scripts/requirements.txt`
  didn't finish.
- **Wrong Python**: the converters need Python 3.11 exactly. `brew install python@3.11`, then
  `PYTHON="$(brew --prefix python@3.11)/bin/python3.11" ./scripts/setup_models.sh`.
- **coremltools warns that the torch version is untested**: expected. `requirements.txt` explains
  why the pinned pair was verified directly.

A missing model is never an error in the app. Every stage falls back or passes through, so a failed
conversion only means that stage stays classical.

## Packaging

- `build_app.sh`: builds the release binary and assembles a signed `build/Latent.app`.
- `run.sh`: rebuilds the app, quits any running copy, and opens the new one.
- `generate_icon.swift`: renders `Resources/AppBundle/Latent.icns`.
