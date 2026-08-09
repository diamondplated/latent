# Contributing to Latent

Thanks for looking. Latent is a Mac-native photo viewer with a local enhancement pipeline. Out of
the box nothing it does touches the network — the exceptions are the map view's MapKit tiles and the
phone companion, which is off until you switch it on and never leaves your LAN. That default is
worth protecting, so a change that would introduce a runtime network call needs a good reason and an
off-by-default flag.

## Getting set up

```bash
swift build
swift run pv-pipeline      # the self-verifier — start here
swift run Latent           # launch the viewer
```

Models are optional. With `Resources/Models/` empty, every stage still runs: Sharpen works
classically, Upscale falls back to Lanczos, and Denoise / ArtifactRemoval fast-path to
identity. You do not need 1.2 GB of weights to work on the viewer, the cache, the vim keymap, or the
search plumbing.

To populate models (one-time, needs network and a Python env with `coremltools`):

```bash
pip install -r scripts/requirements.txt
./scripts/setup_models.sh          # or run individual scripts/convert_*.py
```

**Read [THIRD_PARTY_MODELS.md](THIRD_PARTY_MODELS.md) first.** The models come from four different
upstream projects, all permissively licensed.

## Verifying a change

```bash
swift build
swift run pv-pipeline      # assert-based, runs anywhere
swift test                 # XCTest target, needs full Xcode (not just CommandLineTools)
```

`pv-pipeline` exists because `swift test` needs Xcode and the pipeline internals are worth checking
on machines that only have CommandLineTools. Both are run in CI. If you add a scenario to one,
consider whether it belongs in the other.

For anything touching the viewer UI, actually open a real folder of photos. The grid, the prefetcher
and the trash flow all behave differently at a few thousand images than they do at ten.

## Architecture, briefly

- `PipelineCore` — `Stage` protocol, the chain executor, `IntermediateCache`, sidecar round-trip,
  `ImageBuffer`. Pure and cheap to test; this is where logic wants to live.
- `EnhancementStages` — the four stages, each model-aware with a documented fallback.
- `PhotoIO` — reader/writer, EXIF round-trip, orientation baked into pixels before the pipeline sees
  them, colour-space awareness.
- `PhotoML` — tiling with feathered seams, CoreML wrappers, model registry with negative caching,
  Vision face detection.
- `PhotoSearch` — embeddings, per-folder index, CLIP image and text encoders, Swift BPE tokenizer.
- `PhotoViewerApp` — the SwiftUI app.
- `PipelineCLI` — `pv-pipeline`.

A note on naming: the SwiftPM package and most modules are still called `PhotoViewer` / `Photo*`
from before the project was named Latent. The shipped executable and app are `Latent`. Renaming the
modules would be a large diff for no functional gain, so it has not been done.

## Things not to simplify away

- **The cache key.** Each stage's output is keyed on the input hash plus the ordered list of
  `(stageID, paramsHash)` for enabled prior stages. That is what makes toggling a stage off keep
  upstream hits valid. It looks more complicated than it needs to be; it isn't.
- **Orientation baking.** The reader produces canonical-up pixels so no stage has to think about
  EXIF orientation. Don't push that back downstream.
- **`preserveMetadata: false`** on export. Stripping EXIF is a privacy feature, not an oversight.
- **Graceful model degradation.** A missing model must never be an error. Someone should be able to
  clone, build, and run without downloading a gigabyte.
- **No runtime network calls by default.** Model download is an explicit, separate, user-run script.
  The phone companion is the one runtime listener, and it only exists while switched on.

## Reporting bugs

Say what the image was — format, rough megapixels, and whether it came off a camera or a phone.
Most interesting bugs here are format- or size-dependent. If it involves an enhancement stage, say
whether you had that model installed, since the fallback path and the model path are different code.
