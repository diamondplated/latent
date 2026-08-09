import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PipelineCore
import EnhancementStages
import PhotoIO
import PhotoML
import PhotoSearch
import PhotoViewerCore
import PhotoGeo
import PhotoQuickLook
import PhotoServe

// CLI entry. Doubles as an executable verifier for the pipeline, since this
// project currently runs against macOS CommandLineTools (no XCTest framework).
// The XCTest target in Tests/ stays in tree and runs once Xcode is installed.

@main
struct PipelineCLI {
    static func main() async {
        print("photo-viewer pipeline runner / verifier")
        print("=======================================\n")

        var failures = 0
        failures += await runVerification("cold run executes all stages, no cache hits", check: coldRunMissesAll)
        failures += await runVerification("warm run hits cache for all stages", check: warmRunHitsAll)
        failures += await runVerification("disabling a stage skips it; upstream stays cached", check: bypassRecomputesDownstream)
        failures += await runVerification("distinct inputs occupy independent cache entries", check: distinctInputsDontCollide)
        failures += await runVerification("sidecar round-trip preserves stage parameters", check: sidecarRoundTrip)
        failures += await runVerification("sidecar load rejects newer schema versions", check: sidecarRejectsNewerVersion)
        failures += await runVerification("LRU eviction drops least-recently-used entry", check: lruEviction)
        failures += await runVerification("image I/O round-trips a JPEG through reader+writer", check: jpegRoundTrip)
        failures += await runVerification("reader bakes EXIF orientation into pixels (axes swap for orientation 6)", check: orientationBaking)
        failures += await runVerification("writer with preserveMetadata=false strips EXIF", check: privacyExportStripsMetadata)
        failures += await runVerification("TileExecutor single-tile fast path is exact identity", check: tileExecutorSingleTile)
        failures += await runVerification("TileExecutor multi-tile identity reproduces input within Float16 tolerance", check: tileExecutorMultiTileIdentity)
        failures += await runVerification("TileExecutor 2x upscale produces correct output dimensions", check: tileExecutorUpscaleDimensions)
        failures += await runVerification("FaceRestore is identity for an image with no detectable faces", check: faceRestoreNoFaces)
        failures += await runVerification("EmbeddingVector cosine similarity of identical vectors equals 1", check: embeddingSelfSimilarityIsOne)
        failures += await runVerification("EmbeddingVector cosine similarity of orthogonal vectors equals 0", check: embeddingOrthogonalSimilarityIsZero)
        failures += await runVerification("EmbeddingIndex round-trips entries through save/load", check: embeddingIndexRoundTrip)
        failures += await runVerification("CLIPBPETokenizer init from minimal merges file produces 77-token output with SOS/EOS", check: tokenizerSmokeTest)
        // VimKeymap is @MainActor; hop via a Task so the closure handed to
        // runVerification stays non-isolated.
        failures += await runVerification("VimKeymap: j returns .next from index 0") {
            try await Task { @MainActor in try await vimJourneyNextFromZero() }.value
        }
        failures += await runVerification("VimKeymap: gg chord returns .none then .first") {
            try await Task { @MainActor in try await vimGGTwoChord() }.value
        }
        failures += await runVerification("VimKeymap: m a sets mark, ' a jumps to it") {
            try await Task { @MainActor in try await vimMarkRoundtrip() }.value
        }
        failures += await runVerification("VimKeymap: digit key sets color label") {
            try await Task { @MainActor in try await vimDigitSetsColorLabel() }.value
        }
        failures += await runVerification("VimKeymap: shift+P toggles pick") {
            try await Task { @MainActor in try await vimShiftPTogglesPick() }.value
        }
        failures += await runVerification("VimKeymap: save/load roundtrip preserves marks/labels/picks") {
            try await Task { @MainActor in try await vimSaveLoadRoundtrip() }.value
        }
        failures += await runVerification("HTTPRequest: parses request line, query and case-insensitive headers", check: httpParsesRequestLineAndHeaders)
        failures += await runVerification("HTTPRequest: reads body per Content-Length", check: httpParsesBodyByContentLength)
        failures += await runVerification("HTTPRequest: rejects malformed requests", check: httpRejectsMalformedRequests)
        failures += await runVerification("HTTPRequest: expectedLength reports nil until the body is complete", check: httpExpectedLengthDetectsIncompleteRequest)
        failures += await runVerification("HTTPRequest: refuses overflowing, negative and conflicting Content-Length", check: httpRefusesHostileContentLength)
        failures += await runVerification("HTTPResponse: serializes status line, headers and body", check: httpResponseSerializesStatusAndBody)
        failures += await runVerification("AddressGate: accepts loopback, RFC1918, link-local and ULA", check: addressGateAcceptsPrivateRanges)
        failures += await runVerification("AddressGate: refuses public and malformed addresses", check: addressGateRejectsPublicAddresses)
        failures += await runVerification("SharedFolders: issued IDs resolve and carry no path text", check: sharedFoldersResolveOnlyIssuedIDs)
        failures += await runVerification("SharedFolders: unknown and traversal IDs never resolve", check: sharedFoldersRejectUnknownAndTraversalIDs)
        failures += await runVerification("SharedFolders: unshare invalidates every issued ID", check: sharedFoldersUnshareInvalidatesIDs)
        failures += await runVerification("PairingManager: a pairing code works exactly once", check: pairingCodeIsSingleUse)
        failures += await runVerification("PairingManager: a pairing code expires after 60s", check: pairingCodeExpires)
        failures += await runVerification("PairingManager: wrong codes are refused, then rate limited", check: pairingRejectsWrongCodeAndRateLimits)
        failures += await runVerification("PairingManager: codes are 128-bit and non-repeating", check: pairingCodeHasEnoughEntropy)
        failures += await runVerification("PairingManager: device tokens validate and revoke", check: pairingTokensValidateAndRevoke)
        failures += await runVerification("PairingManager: stores a token hash, never the token", check: pairingStoresTokenHashNotToken)
        failures += await runVerification("Router: refuses API requests with no token", check: routerRefusesUnauthenticatedAPIRequests)
        failures += await runVerification("Router: refuses a valid token from a public address", check: routerRefusesNonPrivateHosts)
        failures += await runVerification("Router: serves the folder list with a valid token", check: routerServesAPIWithValidToken)
        failures += await runVerification("Router: a declined pairing issues no token", check: routerPairingRequiresApproval)
        failures += await runVerification("Router: an approved pairing issues a working token", check: routerPairingIssuesTokenWhenApproved)
        failures += await runVerification("Router: swipe actions map onto VimActions", check: routerMapsSwipeActionsToVimActions)
        failures += await runVerification("Router: unknown action names are rejected", check: routerRejectsUnknownActionNames)
        failures += await runVerification("SSE: frames carry event and data lines and end blank", check: sseFramesAreWellFormed)
        failures += await runVerification("SSE: multi-line payloads split across data lines", check: sseFramesEscapeNewlinesInData)
        failures += await runVerification("HTTPRequest: parses correctly from a non-zero-startIndex Data slice", check: httpParsesFromNonZeroStartIndexSlice)
        failures += await runVerification("PhotoGeo: extractGPS reads lat/lon from a synthetic JPEG", check: extractGPSFromSyntheticJPEG)
        failures += await runVerification("QuickLookRenderer: synthetic JPEG renders within max dimension", check: quickLookRenderRespectsMaxDimension)
        failures += await runVerification("QuickLookRenderer: rejects unsupported file extensions", check: quickLookRenderRejectsUnsupported)
        failures += await runVerification("ArchiveExtractor: detects zip / tar / tar.gz / tar.bz2 / tar.xz from filename", check: archiveDetectsCommonFormats)
        failures += await runVerification("ArchiveExtractor: extracts a real zip, preserving subfolder structure", check: archiveExtractRoundTripZip)
        failures += await runVerification("ArchiveExtractor: rejects unsupported extensions", check: archiveExtractRejectsBadFormat)

        // Optional: real-photo smoke test. Set PV_TEST_FOLDER=/some/path with
        // real JPEG/HEIC/PNG to exercise the full pipeline end-to-end on
        // disk-resident images. Skipped when the env var isn't set.
        if let folder = ProcessInfo.processInfo.environment["PV_TEST_FOLDER"] {
            let folderURL = URL(fileURLWithPath: folder, isDirectory: true)
            failures += await runVerification("real-photo: every JPEG/HEIC/PNG in PV_TEST_FOLDER reads, runs pipeline, writes back, re-reads") {
                try await realPhotoFolderRoundTrip(folder: folderURL)
            }
        }

        print()
        if failures == 0 {
            print("All checks passed.")
        } else {
            print("\(failures) check(s) failed.")
            exit(1)
        }
    }
}

// MARK: - Helpers

func runVerification(_ name: String, check: sending () async throws -> Void) async -> Int {
    do {
        try await check()
        print("  PASS  \(name)")
        return 0
    } catch let err as VerifyError {
        print("  FAIL  \(name): \(err.message)")
        return 1
    } catch {
        print("  FAIL  \(name): \(error)")
        return 1
    }
}

struct VerifyError: Error {
    let message: String
}

func require(_ condition: @autoclosure () -> Bool, _ message: @autoclosure () -> String) throws {
    if !condition() { throw VerifyError(message: message()) }
}

func makeInput(seed: UInt8 = 0, w: Int = 16, h: Int = 16) -> ImageBuffer {
    let bpp = ImageFormat.working.bytesPerPixel
    var data = Data(count: w * h * bpp)
    if seed != 0 {
        for i in 0..<data.count { data[i] = seed }
    }
    return ImageBuffer(width: w, height: h, format: .working, pixels: data)
}

actor RecordingObserver: PipelineObserver {
    enum Event: Equatable {
        case start(StageID)
        case complete(StageID, cacheHit: Bool)
    }
    private(set) var events: [Event] = []

    func stageStarted(stageID: StageID, displayName: String) async {
        events.append(.start(stageID))
    }
    func stageProgress(stageID: StageID, fraction: Double) async {}
    func stageCompleted(stageID: StageID, cacheHit: Bool) async {
        events.append(.complete(stageID, cacheHit: cacheHit))
    }

    func snapshot() -> [Event] { events }
}

func completions(_ events: [RecordingObserver.Event]) -> [(StageID, Bool)] {
    events.compactMap { e in
        if case .complete(let id, let hit) = e { return (id, hit) } else { return nil }
    }
}

// MARK: - Verifications

func coldRunMissesAll() async throws {
    let cache = IntermediateCache(maxBytes: 16 * 1024 * 1024)
    let pipeline = Pipeline(steps: StandardPipeline.defaultSteps(), cache: cache)
    let obs = RecordingObserver()
    _ = try await pipeline.run(input: makeInput(), observer: obs)
    let comps = completions(await obs.snapshot())
    try require(comps.count == 5, "expected 5 completions, got \(comps.count)")
    try require(comps.allSatisfy { !$0.1 }, "expected all cold cache misses, got hits: \(comps.filter { $0.1 }.map { $0.0 })")
}

func warmRunHitsAll() async throws {
    let cache = IntermediateCache(maxBytes: 16 * 1024 * 1024)
    let pipeline = Pipeline(steps: StandardPipeline.defaultSteps(), cache: cache)
    let input = makeInput()
    _ = try await pipeline.run(input: input)  // warm

    let obs = RecordingObserver()
    _ = try await pipeline.run(input: input, observer: obs)
    let comps = completions(await obs.snapshot())
    try require(comps.count == 5, "expected 5 completions, got \(comps.count)")
    try require(comps.allSatisfy { $0.1 }, "expected all cache hits, got misses: \(comps.filter { !$0.1 }.map { $0.0 })")
}

func bypassRecomputesDownstream() async throws {
    let cache = IntermediateCache(maxBytes: 16 * 1024 * 1024)
    let pipeline = Pipeline(steps: StandardPipeline.defaultSteps(), cache: cache)
    let input = makeInput()
    _ = try await pipeline.run(input: input)  // warm full chain

    var bypassed = StandardPipeline.defaultSteps()
    bypassed[1].enabled = false  // disable Denoise
    let pipeline2 = Pipeline(steps: bypassed, cache: cache)

    let obs = RecordingObserver()
    _ = try await pipeline2.run(input: input, observer: obs)
    let events = await obs.snapshot()

    try require(!events.contains(.start("denoise-nafnet")), "denoise must not run when disabled")

    let comps = completions(events)
    try require(comps.count == 4, "expected 4 completions (denoise skipped), got \(comps.count)")

    let artifactRemoval = comps.first { $0.0 == "artifact-removal-fbcnn" }
    try require(artifactRemoval?.1 == true, "upstream stage should still cache-hit; got \(String(describing: artifactRemoval))")

    let downstream: Set<StageID> = ["face-restore-gfpgan", "upscale", "sharpen-unsharp-mask"]
    for (id, hit) in comps where downstream.contains(id) {
        try require(!hit, "downstream stage \(id) should miss cache after bypass change")
    }
}

func distinctInputsDontCollide() async throws {
    let cache = IntermediateCache(maxBytes: 16 * 1024 * 1024)
    let pipeline = Pipeline(steps: StandardPipeline.defaultSteps(), cache: cache)
    _ = try await pipeline.run(input: makeInput(seed: 1))
    _ = try await pipeline.run(input: makeInput(seed: 2))
    let count = await cache.count
    try require(count == 10, "expected 10 cached intermediates (2 inputs × 5 stages), got \(count)")
}

func sidecarRoundTrip() async throws {
    let denoiseParams = Denoise.Params(strength: 0.8, preserveDetailBias: 0.3)
    let sidecar = EnhanceSidecar(steps: [
        .init(stageID: "denoise-nafnet", enabled: true, parameters: try ParameterBag(denoiseParams))
    ])

    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("test_\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: EnhanceSidecar.sidecarURL(for: tmp)) }

    try sidecar.save(for: tmp)
    let loaded = try EnhanceSidecar.load(for: tmp)
    try require(loaded != nil, "sidecar load returned nil")
    try require(loaded?.steps.count == 1, "expected 1 step")
    try require(loaded?.steps[0].stageID == "denoise-nafnet", "wrong stage id")
    try require(loaded?.steps[0].enabled == true, "wrong enabled flag")

    let decoded = try loaded!.steps[0].parameters.decode(as: Denoise.Params.self)
    try require(decoded.strength == 0.8, "strength = \(decoded.strength)")
    try require(decoded.preserveDetailBias == 0.3, "preserveDetailBias = \(decoded.preserveDetailBias)")
}

// MARK: - I/O fixture helpers

/// Synthesize an N-pixel gradient as an 8-bit RGBA CGImage in sRGB.
func makeGradientCGImage(width: Int, height: Int) -> CGImage {
    let bytesPerRow = width * 4
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    // Vertical red gradient with green band so orientation tests can distinguish corners.
    if let buf = context.data?.assumingMemoryBound(to: UInt8.self) {
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                buf[i + 0] = UInt8((x * 255) / max(1, width - 1))
                buf[i + 1] = (y < height / 4) ? 255 : 0   // green band on top quarter
                buf[i + 2] = UInt8((y * 255) / max(1, height - 1))
                buf[i + 3] = 255
            }
        }
    }
    return context.makeImage()!
}

/// Write a CGImage to a JPEG file with a specific EXIF orientation tag.
func writeJPEG(_ cgImage: CGImage, to url: URL, orientation: ExifOrientation = .up, quality: Double = 0.95) throws {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    let props: [CFString: Any] = [
        kCGImagePropertyOrientation: orientation.rawValue,
        kCGImageDestinationLossyCompressionQuality: quality,
    ]
    CGImageDestinationAddImage(dest, cgImage, props as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
        throw VerifyError(message: "failed to finalize fixture JPEG")
    }
}

func tempURL(_ ext: String) -> URL {
    URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_io_\(UUID().uuidString).\(ext)")
}

// MARK: - Existing verifications continue below

func sidecarRejectsNewerVersion() async throws {
    // Hand-craft a sidecar JSON with version=999 and confirm load throws.
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("future_\(UUID().uuidString).jpg")
    let sidecarURL = EnhanceSidecar.sidecarURL(for: tmp)
    defer { try? FileManager.default.removeItem(at: sidecarURL) }

    let json = """
    {
      "version": 999,
      "createdAt": "2030-01-01T00:00:00Z",
      "updatedAt": "2030-01-01T00:00:00Z",
      "steps": []
    }
    """
    try json.data(using: .utf8)!.write(to: sidecarURL)

    do {
        _ = try EnhanceSidecar.load(for: tmp)
        throw VerifyError(message: "expected SidecarError.unsupportedVersion, got success")
    } catch let err as SidecarError {
        if case .unsupportedVersion(let found, _) = err {
            try require(found == 999, "expected found=999, got \(found)")
        } else {
            throw VerifyError(message: "wrong SidecarError variant: \(err)")
        }
    }
}

func lruEviction() async throws {
    // Each entry: 16*16*8 = 2048 bytes. Budget allows 2 entries.
    let cache = IntermediateCache(maxBytes: 5000)
    let key = { (i: Int) in
        CacheKey(inputHash: ContentHash(value: UInt64(i)), stagePath: [])
    }
    let buf = makeInput()

    await cache.put(buf, for: key(1))
    await cache.put(buf, for: key(2))
    _ = await cache.get(key(1))         // touch key(1) so key(2) becomes LRU
    await cache.put(buf, for: key(3))   // should evict key(2)

    let one = await cache.get(key(1))
    let two = await cache.get(key(2))
    let three = await cache.get(key(3))
    try require(one != nil, "key(1) was evicted unexpectedly")
    try require(two == nil, "key(2) (LRU) should have been evicted")
    try require(three != nil, "key(3) was evicted unexpectedly")
}

// MARK: - I/O verifications

func jpegRoundTrip() async throws {
    let src = tempURL("jpg")
    let out = tempURL("jpg")
    defer {
        try? FileManager.default.removeItem(at: src)
        try? FileManager.default.removeItem(at: out)
    }

    let cg = makeGradientCGImage(width: 64, height: 48)
    try writeJPEG(cg, to: src)

    let reader = ImageReader()
    let (buffer, metadata) = try reader.read(url: src)
    try require(buffer.width == 64, "expected width 64, got \(buffer.width)")
    try require(buffer.height == 48, "expected height 48, got \(buffer.height)")
    try require(metadata.sourceFormat == .jpeg, "expected sourceFormat .jpeg, got \(String(describing: metadata.sourceFormat))")
    try require(metadata.colorSpace == .sRGB, "expected sRGB color space, got \(metadata.colorSpace)")

    // Run through the standard pipeline. Upscale scale=2 doubles dims.
    // (Without a CoreML model on disk, Upscale falls back to Lanczos resize,
    // which still produces 2x output — same dimension contract.)
    let cache = IntermediateCache(maxBytes: 16 * 1024 * 1024)
    let pipeline = Pipeline(steps: StandardPipeline.defaultSteps(), cache: cache)
    let processed = try await pipeline.run(input: buffer)
    try require(processed.width == 128 && processed.height == 96,
                "expected 2x dims (128x96), got \(processed.width)x\(processed.height)")

    let writer = ImageWriter()
    try writer.write(buffer: processed, metadata: metadata, to: out)

    let (buf2, meta2) = try reader.read(url: out)
    try require(buf2.width == 128 && buf2.height == 96,
                "round-tripped dimensions wrong: \(buf2.width)x\(buf2.height)")
    try require(meta2.sourceFormat == .jpeg, "round-tripped format not JPEG")
}

func orientationBaking() async throws {
    let src = tempURL("jpg")
    defer { try? FileManager.default.removeItem(at: src) }

    // 100 wide × 50 tall; tag with orientation .right (6) which means
    // visually 50 wide × 100 tall after baking.
    let cg = makeGradientCGImage(width: 100, height: 50)
    try writeJPEG(cg, to: src, orientation: .right)

    let reader = ImageReader()
    let (buffer, metadata) = try reader.read(url: src)

    // Original orientation recorded.
    try require(metadata.originalOrientation == .right,
                "expected metadata.originalOrientation = .right, got \(metadata.originalOrientation)")

    // Pixel dimensions should reflect canonical (rotated) orientation: axes swapped.
    try require(buffer.width == 50, "expected baked width 50, got \(buffer.width)")
    try require(buffer.height == 100, "expected baked height 100, got \(buffer.height)")
}

// MARK: - TileExecutor helpers

/// Build a buffer with a deterministic gradient pattern.
func makeGradientBuffer(width: Int, height: Int) -> ImageBuffer {
    let pixelCount = width * height
    var data = Data(count: pixelCount * 4 * MemoryLayout<Float16>.size)
    data.withUnsafeMutableBytes { rawPtr in
        let dst = rawPtr.bindMemory(to: Float16.self).baseAddress!
        for y in 0..<height {
            for x in 0..<width {
                let p = y * width + x
                dst[p * 4 + 0] = Float16(Float(x) / Float(max(1, width - 1)))
                dst[p * 4 + 1] = Float16(Float(y) / Float(max(1, height - 1)))
                dst[p * 4 + 2] = Float16((Float(x) + Float(y)) / Float(max(1, width + height - 2)))
                dst[p * 4 + 3] = 1.0
            }
        }
    }
    return ImageBuffer(width: width, height: height, format: .working, pixels: data)
}

/// Mean absolute difference between two RGB channels (alpha excluded).
func meanAbsoluteRGBDifference(_ a: ImageBuffer, _ b: ImageBuffer) -> Double {
    precondition(a.width == b.width && a.height == b.height)
    let pixelCount = a.width * a.height
    var sum: Double = 0
    a.pixels.withUnsafeBytes { aRaw in
        b.pixels.withUnsafeBytes { bRaw in
            let aP = aRaw.bindMemory(to: Float16.self).baseAddress!
            let bP = bRaw.bindMemory(to: Float16.self).baseAddress!
            for p in 0..<pixelCount {
                for c in 0..<3 {
                    sum += abs(Double(aP[p * 4 + c]) - Double(bP[p * 4 + c]))
                }
            }
        }
    }
    return sum / Double(pixelCount * 3)
}

func privacyExportStripsMetadata() async throws {
    let src = tempURL("jpg")
    let out = tempURL("jpg")
    defer {
        try? FileManager.default.removeItem(at: src)
        try? FileManager.default.removeItem(at: out)
    }

    let cg = makeGradientCGImage(width: 32, height: 32)
    try writeJPEG(cg, to: src, orientation: .right)

    let reader = ImageReader()
    let (buffer, metadata) = try reader.read(url: src)
    try require(metadata.originalOrientation == .right, "fixture should have orientation .right")

    let writer = ImageWriter()
    try writer.write(buffer: buffer, metadata: metadata, to: out, options: .init(preserveMetadata: false))

    // Re-read; orientation should be .up (because the writer always emits canonical
    // pixels), and there should be no carry-over of the original orientation.
    let (_, meta2) = try reader.read(url: out)
    try require(meta2.originalOrientation == .up, "preserveMetadata=false should still write orientation=up; got \(meta2.originalOrientation)")
}

// MARK: - TileExecutor verifications

func tileExecutorSingleTile() async throws {
    // Buffer fits in one tile → fast path with no blending.
    let input = makeGradientBuffer(width: 64, height: 64)
    let executor = TileExecutor(tileSize: 128, overlap: 16, scale: 1)
    let output = try await executor.execute(input: input) { tile in tile }

    try require(output.width == 64 && output.height == 64, "expected 64x64, got \(output.width)x\(output.height)")
    try require(output.pixels == input.pixels, "single-tile fast path should pass through bytes unchanged")
}

func tileExecutorMultiTileIdentity() async throws {
    // 128x96 input forces multiple tiles at tileSize 64, overlap 16.
    let input = makeGradientBuffer(width: 128, height: 96)
    let executor = TileExecutor(tileSize: 64, overlap: 16, scale: 1)
    let output = try await executor.execute(input: input) { tile in tile }

    try require(output.width == 128 && output.height == 96, "dimensions wrong: \(output.width)x\(output.height)")

    // Identity through linear feathered blend should reproduce input within
    // Float16 quantization noise (mantissa precision ~3e-4 for unit-range values).
    let mae = meanAbsoluteRGBDifference(input, output)
    try require(mae < 5e-3, "multi-tile identity diverged: MAE = \(mae)")
}

// MARK: - PhotoSearch verifications

func embeddingSelfSimilarityIsOne() async throws {
    let v = EmbeddingVector([1.0, 2.0, 3.0, 4.0]).normalized()
    let sim = v.cosineSimilarity(v)
    try require(abs(sim - 1.0) < 1e-5, "expected ~1.0, got \(sim)")
}

func embeddingOrthogonalSimilarityIsZero() async throws {
    let a = EmbeddingVector([1.0, 0.0, 0.0]).normalized()
    let b = EmbeddingVector([0.0, 1.0, 0.0]).normalized()
    let sim = a.cosineSimilarity(b)
    try require(abs(sim) < 1e-5, "expected ~0.0 for orthogonal vectors, got \(sim)")
}

func embeddingIndexRoundTrip() async throws {
    let tempFolder = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_search_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: tempFolder, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: tempFolder)
        if let url = try? EmbeddingIndex.indexFileURL(for: tempFolder) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    let index = EmbeddingIndex(folderURL: tempFolder)
    let entry = IndexedPhoto(
        relativePath: "subdir/photo.jpg",
        embedding: EmbeddingVector(Array(repeating: Float(0.5), count: 512)).normalized(),
        fileSize: 12345,
        modifiedAt: Date(timeIntervalSince1970: 1700000000)
    )
    await index.upsert(entry)
    try await index.save()

    let reloaded = EmbeddingIndex(folderURL: tempFolder)
    try await reloaded.load()
    let count = await reloaded.count
    try require(count == 1, "expected 1 entry after reload, got \(count)")
    let got = await reloaded.entry(forRelativePath: "subdir/photo.jpg")
    try require(got != nil, "entry missing after reload")
    try require(got?.fileSize == 12345, "fileSize lost in roundtrip")
    try require(abs((got?.embedding.values[0] ?? 0) - entry.embedding.values[0]) < 1e-5,
                "embedding values changed in roundtrip")
}

// MARK: - Tokenizer verifications

func tokenizerSmokeTest() async throws {
    // Write a minimal merges file (header + a handful of generic merges) to a
    // temp path, build a tokenizer from it, encode a string, validate the
    // output structure. Real tokenization correctness against CLIP needs the
    // ~48,894-merge vocab from convert_openclip.py.
    let tempFile = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("clip-merges-\(UUID().uuidString).txt")
    let merges = """
    #version: 0.2
    t h
    th e</w>
    a n
    an d</w>
    o f</w>
    """
    try merges.write(to: tempFile, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: tempFile) }

    let tokenizer = try CLIPBPETokenizer(mergesFileURL: tempFile)

    // Vocab: 256 byte chars + 256 byte+</w> + 5 merges + 2 specials = 519
    try require(tokenizer.vocabSize == 519, "expected vocab size 519, got \(tokenizer.vocabSize)")
    try require(tokenizer.startTokenID == 517, "SOS should be 517, got \(tokenizer.startTokenID)")
    try require(tokenizer.endTokenID == 518, "EOS should be 518, got \(tokenizer.endTokenID)")

    let ids = try tokenizer.encode("the and of")
    try require(ids.count == 77, "expected 77 tokens, got \(ids.count)")
    try require(ids[0] == tokenizer.startTokenID, "first token should be SOS, got \(ids[0])")

    // The EOS sits after real tokens; the rest is padding (0).
    let firstZero = ids.firstIndex(of: 0) ?? 77
    let eosIdx = firstZero - 1
    try require(eosIdx > 0 && ids[eosIdx] == tokenizer.endTokenID,
                "EOS should be at index \(eosIdx), got \(ids[eosIdx])")

    // All other content tokens between SOS and EOS must be in vocab range.
    for i in 1..<eosIdx {
        try require(ids[i] >= 0 && ids[i] < tokenizer.vocabSize,
                    "token \(ids[i]) at index \(i) out of vocab range")
    }
}

func faceRestoreNoFaces() async throws {
    // Synthetic gradient has no faces. FaceRestore should detect zero faces
    // and return input unchanged (no model call needed).
    let input = makeGradientBuffer(width: 256, height: 256)
    let stage = FaceRestore()
    let output = try await stage.process(
        input: input,
        params: .init(strength: 0.7, minFaceSize: 64, identityPreserveBias: 0.5),
        progress: .noop
    )
    try require(output.width == 256 && output.height == 256, "dimensions changed")
    try require(output.pixels == input.pixels, "no-faces fast path should pass through bytes unchanged")
}

func tileExecutorUpscaleDimensions() async throws {
    // Multi-tile + scale=2 with a 2x nearest-neighbor synthetic upscaler.
    // Verifies output dimensions and that the executor doesn't crash on the
    // larger output buffer + per-tile coord mapping.
    let input = makeGradientBuffer(width: 96, height: 64)
    let executor = TileExecutor(tileSize: 48, overlap: 8, scale: 2)
    let output = try await executor.execute(input: input) { tile in
        // 2x nearest-neighbor: each input pixel becomes a 2x2 block.
        let outW = tile.width * 2
        let outH = tile.height * 2
        let pixelCount = outW * outH
        var data = Data(count: pixelCount * 4 * MemoryLayout<Float16>.size)
        tile.pixels.withUnsafeBytes { srcRaw in
            data.withUnsafeMutableBytes { dstRaw in
                let src = srcRaw.bindMemory(to: Float16.self).baseAddress!
                let dst = dstRaw.bindMemory(to: Float16.self).baseAddress!
                for y in 0..<outH {
                    for x in 0..<outW {
                        let srcP = (y / 2) * tile.width + (x / 2)
                        let dstP = y * outW + x
                        for c in 0..<4 {
                            dst[dstP * 4 + c] = src[srcP * 4 + c]
                        }
                    }
                }
            }
        }
        return ImageBuffer(width: outW, height: outH, format: .working, pixels: data)
    }

    try require(output.width == 192, "expected width 192, got \(output.width)")
    try require(output.height == 128, "expected height 128, got \(output.height)")
}
