# photo-viewer

A Mac-native photo viewer focused on speed, folder-based browsing, and best-in-class **local** AI enhancement. No cloud calls, no library import, no subscription.

See `docs/PLAN.md` for full design context (move plan into the repo before sharing externally).

## Status

This is the **architectural keystone** for the project: the pipeline DAG executor, intermediate cache, sidecar format, and stage protocol. Everything else (model inference, viewer UI, Quick Look extension) plugs into the surfaces defined here.

What's working:

- ✅ `PipelineCore` library — `ImageBuffer`, `Stage` protocol, `Pipeline` chain executor, `IntermediateCache` (LRU, byte-bounded), `EnhanceSidecar` (`.enhance.json` round-trip), `ImageBuffer ↔ CGImage` bridge
- ✅ `EnhancementStages` — the 5 stages with **real, final parameter shapes** but **identity-function bodies** (no ML inference yet)
  - `ArtifactRemoval` (FBCNN)
  - `Denoise` (NAFNet)
  - `FaceRestore` (GFPGAN)
  - `Upscale` (Real-ESRGAN x4plus / SwinIR-L)
  - `Sharpen` (classical unsharp mask)
- ✅ `PhotoIO` library — `ImageReader` / `ImageWriter` with EXIF round-trip, orientation baking (canonical-up pixels for the pipeline), color-space awareness (sRGB / Display P3 / Adobe RGB / ProPhoto), `preserveMetadata: false` for privacy exports
- ✅ `PhotoML` library — `TileExecutor` (tile + feathered seam blending), `CoreMLImageModel` (image-to-image and tensor-output models), `ModelRegistry` + `ModelManager` (lazy-load with negative caching), `FaceDetector` (Apple Vision), `FaceComposite` (crop, resize, alpha-blend)
- ✅ All 5 enhancement stages wired:
  - `Sharpen` — Core Image unsharp mask, no model needed
  - `Upscale` — Real-ESRGAN x2 model if present, Lanczos resize fallback
  - `Denoise` (NAFNet), `ArtifactRemoval` (FBCNN) — model if present, identity passthrough otherwise
  - `FaceRestore` (GFPGAN) — Vision face detection → per-face crop → model → feathered alpha composite; fast-paths to identity if no faces detected or model unavailable
- ✅ `PhotoSearch` library — `EmbeddingVector` + cosine similarity, `EmbeddingIndex` (per-folder JSON-persisted, staleness-aware), `CLIPImageEncoder` (OpenCLIP ViT-B/32, 512-dim normalized embeddings), `SearchEngine` (folder walk + index-or-skip + image-image queries). **Text-query path is stubbed** pending the BPE tokenizer port.
- ✅ `PhotoViewerApp` — minimal SwiftUI app: folder picker → thumbnail grid → detail view, arrow-key navigation, file-system watch for hot-reload. No vim keymap, A/B compare, or pipeline UI yet.
- ✅ `pv-pipeline` CLI — 17 self-verification scenarios

What's stubbed:

- 🚧 CLIP text encoder works (model converts cleanly), but the BPE tokenizer is a Swift port of `clip.simple_tokenizer` — ~200 lines, its own milestone. Image-image search works fully without it.
- 🚧 SwiftUI app is minimal — no vim keymap, no A/B compare, no in-app pipeline controls yet. App target is a Swift Package executable, not a proper Xcode app bundle (no code signing, no entitlements, no app icon). Migration to Xcode project is a separate milestone.

## Build & verify

```bash
swift build
swift run pv-pipeline                  # run the verifier
swift run PhotoViewerApp               # launch the SwiftUI viewer
```

Expected output:

```
photo-viewer pipeline runner / verifier
=======================================

  PASS  cold run executes all stages, no cache hits
  PASS  warm run hits cache for all stages
  PASS  disabling a stage skips it; upstream stays cached
  PASS  distinct inputs occupy independent cache entries
  PASS  sidecar round-trip preserves stage parameters
  PASS  sidecar load rejects newer schema versions
  PASS  LRU eviction drops least-recently-used entry
  PASS  image I/O round-trips a JPEG through reader+writer
  PASS  reader bakes EXIF orientation into pixels (axes swap for orientation 6)
  PASS  writer with preserveMetadata=false strips EXIF
  PASS  TileExecutor single-tile fast path is exact identity
  PASS  TileExecutor multi-tile identity reproduces input within Float16 tolerance
  PASS  TileExecutor 2x upscale produces correct output dimensions

All checks passed.
```

## Tests

The `Tests/PipelineCoreTests/` target is XCTest-based and **requires Xcode** (not just CommandLineTools). Once Xcode is installed:

```bash
sudo xcode-select -s /Applications/Xcode.app
swift test
```

Until then, the `pv-pipeline` CLI exercises the same scenarios with `assert()` semantics — see `Sources/PipelineCLI/main.swift`.

## Project layout

```
photo-viewer/
├── Package.swift
├── Sources/
│   ├── PipelineCore/          # Stage protocol, Pipeline executor, Cache, Sidecar, ImageBuffer, CGImage/CVPixelBuffer bridges
│   ├── EnhancementStages/     # The 5 stages, all wired
│   ├── PhotoIO/               # ImageReader / ImageWriter / ImageMetadata
│   ├── PhotoML/               # TileExecutor / CoreMLImageModel / ModelRegistry / ModelManager / FaceDetector / FaceComposite
│   ├── PhotoSearch/           # EmbeddingVector / EmbeddingIndex / CLIPImageEncoder / SearchEngine (text encoder stubbed)
│   ├── PipelineCLI/           # `pv-pipeline` runner + self-verifier
│   └── PhotoViewerApp/        # Minimal SwiftUI viewer
├── Resources/
│   └── Models/                # .mlpackage files land here (gitignored)
├── scripts/
│   ├── convert_realesrgan.py  # Upscale: Real-ESRGAN x2
│   ├── convert_nafnet.py      # Denoise: NAFNet-SIDD
│   ├── convert_fbcnn.py       # Artifact removal: FBCNN
│   ├── convert_gfpgan.py      # Face restore: GFPGAN v1.4
│   ├── convert_openclip.py    # Search: OpenCLIP ViT-B/32 (image + text encoders)
│   └── requirements.txt
└── Tests/
    └── PipelineCoreTests/     # XCTest target (needs Xcode)
```

## Architectural decisions

**Why a chain, not a full DAG?** The enhancement pipeline is linear — every stage feeds the next. The "DAG" framing is for the cache: each stage's output is keyed on `(inputHash, ordered list of (stageID, paramsHash) for enabled prior stages)`. Toggle a stage off and upstream cache hits still apply; downstream is recomputed once with the new path. Branching/joining (e.g., for ensemble enhancement) can be added later behind the same protocol.

**Why `actor IntermediateCache`?** Multiple pipeline runs from different windows/tabs share a process-wide cache. An actor serializes access without locks. LRU eviction is byte-bounded (not entry-count-bounded) because a 50MP enhanced image is ~1500x bigger than a 256x256 thumbnail.

**Why is `Params` per-stage Codable + hashable?** The same parameter struct serves three masters:
1. **Hashing** for in-memory cache keys (the `stableHash` extension)
2. **Codable** for sidecar persistence (`ParameterBag` JSON-encodes whatever the stage holds)
3. **Sendable** for concurrent execution

**Why not bundle CoreML now?** Two reasons. First, CoreML model conversion (PyTorch → ONNX → CoreML) is a separate workstream that needs the actual model weights from Hugging Face plus `coremltools` in a Python env. Second, getting the pipeline plumbing right is independent of the inference implementation — when we plug in real ML, only `process()` bodies change, not the protocol or the executor.

**Sidecar format choice (`.enhance.json` vs binary).** JSON for diffability and forward-compat. `ParameterBag` stores stage parameters as embedded JSON values, so unknown stages from a future version round-trip without losing data when read by an older app.

## Next milestones

In order of dependency:

1. ~~**Image I/O module**~~ — done. CGImageSource/CGImageDestination based reader and writer, EXIF preserved with orientation baking. CVPixelBuffer-backed `ImageBuffer` deferred until the CoreML wiring needs it.

2. ~~**Real-ESRGAN x2**~~ + ~~remaining 4 stages~~ — done. Run any of the `scripts/convert_*.py` to populate models. Without them, stages gracefully degrade (Sharpen still works classically, Upscale falls back to Lanczos, others pass through).
3. ~~**Search infrastructure**~~ — done for image-image. Text-query needs the BPE tokenizer port (next).
4. ~~**SwiftUI app shell**~~ — minimal version done; folder picker, thumbnail grid, detail view, arrow nav.

5. **CLIP BPE tokenizer in Swift** (~1 week) — port `clip.simple_tokenizer` so text queries work. Vocab + merges files live in app bundle resources.

6. **SwiftUI app polish** (4-6 weeks) — vim keymap dispatcher, A/B compare with synced zoom/pan, in-app pipeline UI (per-stage toggles + sliders + live preview), Metal-backed image renderer for proper color management, MapKit-based map view with GPS clustering.

7. **Migrate to Xcode project** (1-2 weeks) — proper bundle, code signing, sandbox entitlements, app icon, App Store packaging.

8. **System integration** (2-3 weeks) — Quick Look extension target, default-app registration, drag in/out from Finder.

9. **Polish + beta** (4-6 weeks) — perf tuning on real 50MP+ images, lazy-download flow for models, App Store submission.

Most of the original 5-7 month plan got front-loaded into this scaffold; remaining work is largely UI polish, the tokenizer port, and Xcode/App-Store packaging.

## License

TBD.
