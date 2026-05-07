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
- ✅ `pv-pipeline` CLI — 10 self-verification scenarios (cache, bypass, sidecar, LRU, JPEG round-trip, orientation baking, privacy export)

What's stubbed:

- 🚧 Stage bodies return input unchanged. Plumbing is exercised end-to-end; ML is the next milestone.
- 🚧 No CoreML model loading, no tile-based inference, no face detection
- 🚧 No CVPixelBuffer-backed `ImageBuffer` initializers (deferred until CoreML wiring)
- 🚧 No SwiftUI app target (this is a Swift Package; the app target is added in milestone 4)

## Build & verify

```bash
swift build
swift run pv-pipeline
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
│   ├── PipelineCore/          # Stage protocol, Pipeline executor, Cache, Sidecar, ImageBuffer, CGImage bridge
│   ├── EnhancementStages/     # The 5 stage implementations (currently identity-function stubs)
│   ├── PhotoIO/               # ImageReader / ImageWriter / ImageMetadata
│   └── PipelineCLI/           # `pv-pipeline` runner + self-verifier
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

2. **First real model: Real-ESRGAN x2** (2-3 weeks) — convert the model with `coremltools`, ship as `.mlpackage` resource (lazy-downloaded), wire into `Upscale.process()` with tile-based execution + feathered seam blending.

3. **Remaining 4 models** (3-4 weeks) — FBCNN, NAFNet, GFPGAN, OpenCLIP. GFPGAN needs face detection (Apple Vision framework) + alpha-blend composition.

4. **SwiftUI app target** (4-6 weeks) — switch from Swift Package to mixed Package + Xcode project; folder browse view, image display with Metal, vim keymap dispatcher, per-stage UI.

5. **System integration** (2-3 weeks) — Quick Look extension target, default-app registration, CLI tool, drag in/out.

6. **AI features** (3-4 weeks) — natural language search index (OpenCLIP image+text embeddings), MapKit-based map view with GPS clustering.

7. **Polish + beta** (4-6 weeks) — perf tuning on real 50MP+ images, lazy-download flow for models, App Store submission.

Total: ~5-7 months for one engineer to v1, matching the plan.

## License

TBD.
