import Foundation
import PipelineCore
import EnhancementStages

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
