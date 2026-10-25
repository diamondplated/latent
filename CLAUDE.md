# CLAUDE.md

Latent is a folder-first SwiftUI photo viewer for macOS 14+ with a local CoreML enhancement
pipeline, OpenCLIP search, a vim culling keymap, and an opt-in LAN phone companion. SwiftPM only;
there is no Xcode project. README.md, CONTRIBUTING.md and SECURITY.md are accurate and worth reading
before a non-trivial change.

## Build and verify

```bash
swift build
swift run pv-pipeline      # assert-based self-verifier; no Xcode, no models
swift test                 # XCTest; needs full Xcode
./scripts/build_app.sh     # packages build/Latent.app
```

- Needs the macOS 27 SDK (Xcode 27). The app target does not compile with the Command Line Tools
  alone; `pv-pipeline` does.
- **None of this runs on Linux.** A cloud session cannot build or test this repo. Say so instead of
  claiming a change compiles, keep edits conservative, and let CI verify. CI runs on a self-hosted
  MacBook Air (`runs-on: [self-hosted, macOS, air]`) and queues while the laptop sleeps.
- New verification scenarios usually belong in both `Sources/PipelineCLI/*Verifications.swift` and
  `Tests/`. `pv-pipeline` exists so CommandLineTools-only machines can still verify.

## Layout

- `PipelineCore`: `Stage` protocol, chain executor, `IntermediateCache` actor, sidecars, `ImageBuffer`.
- `EnhancementStages`: the four stages (in `StageStubs.swift`, despite the name).
- `PhotoIO`: reader/writer, EXIF, folder watching, archive extraction.
- `PhotoML`: tiling, CoreML wrappers, model registry.
- `PhotoSearch`: CLIP encoders, BPE tokenizer, per-folder embedding index.
- `PhotoViewerCore`: `VimKeymap` and durable culling state (no Apple UI deps).
- `PhotoGeo`, `PhotoQuickLook`: EXIF GPS, Quick Look renderer (extension target not built yet).
- `PhotoServe`: LAN HTTP server, address gate, pairing, embedded `client.html` phone client.
- `PhotoViewerApp`: the SwiftUI app (`AppState` is the hub).
- `PipelineCLI`: `pv-pipeline`.
- `scripts/`: model conversion (Python, coremltools) and app packaging.

Module names are `Photo*` / package `PhotoViewer` from before the rename. Do not rename them.

## Rules that are not negotiable

- **No runtime network calls by default.** Anything new that touches the network must be off by
  default and documented in SECURITY.md. Model downloads stay in user-run scripts.
- **A missing model is never an error.** Every stage keeps its fallback or pass-through.
- **Do not simplify the cache key** (input hash plus ordered `(stageID, paramsHash)` of enabled prior
  stages) or move orientation handling out of the reader.
- **Export keeps `preserveMetadata: false`.** Stripping EXIF is a privacy feature.
- **Phone companion stays LAN-only**, can never delete, and keeps one-time pairing. Treat changes
  to `AddressGate`, `PairingManager` or the router as security changes.
- Trashing uses `FileManager.trashItem`; nothing permanently deletes a photo.
- Model weights and tokenizer assets are gitignored. Never commit them.

## Conventions

- Swift 6 strict concurrency. `@unchecked Sendable` is used for `Operation` subclasses and small
  lock-guarded boxes; do not add it to dodge a real data race.
- Builds against the macOS 27 SDK can hit name clashes with new Foundation types (see
  `PipelineCore.ProgressReporter`); qualify rather than rename.
- Commit messages: short imperative subject, body explains why.
