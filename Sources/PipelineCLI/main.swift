import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PipelineCore
import EnhancementStages
import PhotoIO

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

func runVerification(_ name: String, check: () async throws -> Void) async -> Int {
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

    // Run through the standard pipeline (identity stages) to validate the buffer
    // is a real working buffer that survives the DAG.
    let cache = IntermediateCache(maxBytes: 16 * 1024 * 1024)
    let pipeline = Pipeline(steps: StandardPipeline.defaultSteps(), cache: cache)
    let processed = try await pipeline.run(input: buffer)
    try require(processed.width == 64 && processed.height == 48, "pipeline changed dimensions")

    let writer = ImageWriter()
    try writer.write(buffer: processed, metadata: metadata, to: out)

    // Re-read written file and verify it loads back at correct dimensions.
    let (buf2, meta2) = try reader.read(url: out)
    try require(buf2.width == 64 && buf2.height == 48, "round-tripped dimensions wrong: \(buf2.width)x\(buf2.height)")
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
