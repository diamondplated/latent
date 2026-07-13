# Latent

A Mac-native photo viewer focused on speed, folder-based browsing, and best-in-class **local** AI enhancement. No cloud calls, no library import, no subscription.

## Status

This is a working SwiftPM macOS app plus the pipeline/search libraries behind it. The viewer is folder-first, the enhancement panel is model-aware, and the CLI verifier covers the pipeline pieces that cannot run through XCTest on CommandLineTools-only machines.

What's working:

- ✅ `PipelineCore` library — `ImageBuffer`, `Stage` protocol, `Pipeline` chain executor, `IntermediateCache` (LRU, byte-bounded), `EnhanceSidecar` (`.enhance.json` round-trip), `ImageBuffer ↔ CGImage` bridge
- ✅ `EnhancementStages` — the 5 stages with real parameter shapes and model-aware execution/fallbacks
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
- ✅ `PhotoSearch` library — `EmbeddingVector` + cosine similarity, `EmbeddingIndex` (per-folder JSON-persisted, staleness-aware), `CLIPImageEncoder` / `CLIPTextEncoder` (OpenCLIP ViT-B/32, 512-dim normalized embeddings), Swift BPE tokenizer, and `SearchEngine` folder indexing with image-image and text queries when converted model/tokenizer assets are installed.
- ✅ `PhotoViewerApp` — SwiftUI app: folder picker → thumbnail grid (with color labels, picks/rejects from vim) ↔ map view → detail view with vim keymap (j/k/gg/G/marks/picks/labels), in-app pipeline UI (per-stage toggles + sliders + live preview), A/B compare (enhanced / original / side-by-side, hold-B blink), synced zoom/pan (0.25–16×, drag to pan, pinch to zoom, double-tap reset).
- ✅ `PhotoQuickLook` — `QuickLookRenderer` using ImageIO's downsample fast path. Ready for an Xcode-based QL extension target to import directly.
- ✅ `scripts/build_app.sh` — packages a real `.app` bundle from `swift build` output, including locally converted model/tokenizer assets. Info.plist registers Latent as a viewer for JPEG/HEIC/PNG/TIFF/RAW etc. so Finder offers `Open With → Latent`.
- ✅ `pv-pipeline` CLI — self-verification scenarios for cache behavior, sidecars, image I/O, tiling, search primitives, vim state, GPS, Quick Look, and archive extraction

Still rough:

- 🚧 CoreML model assets are not committed. Run the conversion scripts to install `.mlpackage` files under `Resources/Models/` or user Application Support.
- 🚧 The app is still packaged from SwiftPM. `scripts/build_app.sh` creates a usable `.app`, but distribution-grade signing, sandbox entitlements, and the Quick Look extension target still need an Xcode project.

## Build & verify

```bash
swift build
swift run pv-pipeline                  # run the verifier
swift run Latent                       # launch the viewer from the package binary

# Build a real .app bundle:
swift scripts/generate_icon.swift      # render the app icon (one-time)
./scripts/build_app.sh
open build/Latent.app
```

### Opening folders

- **Drag a folder onto `Latent.app`** (Dock icon or Finder icon) — opens it.
- **Terminal:** `open -a Latent /path/to/folder`
- **From inside Latent:** Cmd-O / "Open Folder…"
- **Right-click an *image* in Finder → Open With → Latent** — opens the
  parent folder and selects that image. Works because `public.jpeg` etc.
  are registered. **Folders themselves don't show "Open With" in the
  standard Finder context menu — that's an Apple OS-level restriction**,
  not something `Info.plist` alone can fix. The drag-drop and
  command-line paths above are the workarounds; a proper "Open in
  Latent" Finder extension would need a separate Xcode-only target.

Expected output (abbreviated):

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
  ...

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
│   ├── PhotoSearch/           # EmbeddingVector / EmbeddingIndex / CLIP image+text encoders / SearchEngine
│   ├── PipelineCLI/           # `pv-pipeline` runner + self-verifier
│   ├── PhotoQuickLook/        # QuickLookRenderer (consumed by future QL extension target)
│   └── PhotoViewerApp/        # SwiftUI viewer (folder browse, vim keymap, map view, in-app pipeline UI, A/B compare)
├── Resources/
│   └── Models/                # .mlpackage files land here (gitignored)
├── scripts/
│   ├── convert_realesrgan.py  # Upscale: Real-ESRGAN x2
│   ├── convert_nafnet.py      # Denoise: NAFNet-SIDD
│   ├── convert_fbcnn.py       # Artifact removal: FBCNN
│   ├── convert_gfpgan.py      # Face restore: GFPGAN v1.4
│   ├── convert_openclip.py    # Search: OpenCLIP ViT-B/32 (image + text encoders)
│   ├── build_app.sh           # Package PhotoViewerApp as a real .app bundle
│   └── requirements.txt
├── Resources/AppBundle/
│   └── Info.plist             # Document types, bundle ID, etc. for the .app bundle
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

5. ~~**CLIP BPE tokenizer in Swift**~~ — done. `CLIPBPETokenizer` ports `simple_tokenizer.py`. Run `convert_openclip.py` to populate the merges file.
6. ~~**SwiftUI app polish**~~ (most) — done. Vim keymap, keybind cheatsheet, A/B compare, synced zoom/pan, map view, in-app pipeline UI all wired. Remaining: status-bar progress and a Metal-backed renderer for proper HDR/wide-gamut display.
7. **Migrate to Xcode project** (1-2 weeks) — proper bundle (today the `build_app.sh` script gets close, but Xcode handles code signing, sandbox entitlements, app icon, App Store packaging, and notarization). Adding the Quick Look extension target lives in this milestone — `PhotoQuickLook.QuickLookRenderer` is already shipped and ready to import.
8. **System integration** (2-3 weeks) — Quick Look extension target (built atop `PhotoQuickLook`), drag in/out from Finder, default-app registration ranking (today: `LSHandlerRank=Alternate`).
9. **Polish + beta** (4-6 weeks) — perf tuning on real 50MP+ images, lazy-download flow for models, App Store submission.

Most of the original 5-7 month plan got front-loaded into this scaffold. Remaining work is largely Xcode/App-Store packaging plus UI polish.

## License

TBD.
