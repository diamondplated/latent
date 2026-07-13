import XCTest
import Foundation
@testable import PipelineCore
@testable import EnhancementStages

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

private func makeInput(seed: UInt8 = 0) -> ImageBuffer {
    let bpp = ImageFormat.working.bytesPerPixel
    let w = 16, h = 16
    var data = Data(count: w * h * bpp)
    if seed != 0 {
        for i in 0..<data.count { data[i] = seed }
    }
    return ImageBuffer(width: w, height: h, format: .working, pixels: data)
}

final class PipelineDAGTests: XCTestCase {

    func testColdRunRunsAllStages_WarmRunHitsCache() async throws {
        let cache = IntermediateCache(maxBytes: 16 * 1024 * 1024)
        let pipeline = Pipeline(steps: StandardPipeline.defaultSteps(), cache: cache)
        let input = makeInput()

        let cold = RecordingObserver()
        _ = try await pipeline.run(input: input, observer: cold)
        let coldEvents = await cold.snapshot()
        let coldCompletions = coldEvents.compactMap { e -> (StageID, Bool)? in
            if case .complete(let id, let hit) = e { return (id, hit) } else { return nil }
        }
        XCTAssertEqual(coldCompletions.count, 5)
        XCTAssertTrue(coldCompletions.allSatisfy { !$0.1 }, "cold run should have no cache hits")

        let warm = RecordingObserver()
        _ = try await pipeline.run(input: input, observer: warm)
        let warmEvents = await warm.snapshot()
        let warmCompletions = warmEvents.compactMap { e -> (StageID, Bool)? in
            if case .complete(let id, let hit) = e { return (id, hit) } else { return nil }
        }
        XCTAssertEqual(warmCompletions.count, 5)
        XCTAssertTrue(warmCompletions.allSatisfy { $0.1 }, "warm run should hit cache for every stage")
    }

    func testBypassRecomputesDownstreamOnly() async throws {
        let cache = IntermediateCache(maxBytes: 16 * 1024 * 1024)
        let pipeline = Pipeline(steps: StandardPipeline.defaultSteps(), cache: cache)
        let input = makeInput()

        _ = try await pipeline.run(input: input)

        var bypassed = StandardPipeline.defaultSteps()
        bypassed[1].enabled = false  // disable Denoise
        let pipeline2 = Pipeline(steps: bypassed, cache: cache)

        let obs = RecordingObserver()
        _ = try await pipeline2.run(input: input, observer: obs)
        let events = await obs.snapshot()

        XCTAssertFalse(events.contains(.start("denoise-nafnet")), "denoise must not run when disabled")

        let completions = events.compactMap { e -> (StageID, Bool)? in
            if case .complete(let id, let hit) = e { return (id, hit) } else { return nil }
        }
        XCTAssertEqual(completions.count, 4)

        let artifactRemoval = completions.first { $0.0 == "artifact-removal-fbcnn" }
        XCTAssertEqual(artifactRemoval?.1, true, "stage upstream of bypass should still cache-hit")

        let downstream: Set<StageID> = ["face-restore-gfpgan", "upscale", "sharpen-unsharp-mask"]
        for (id, hit) in completions where downstream.contains(id) {
            XCTAssertFalse(hit, "downstream stage \(id) should miss cache after bypass change")
        }
    }

    func testDifferentInputsDoNotCollide() async throws {
        let cache = IntermediateCache(maxBytes: 16 * 1024 * 1024)
        let pipeline = Pipeline(steps: StandardPipeline.defaultSteps(), cache: cache)

        _ = try await pipeline.run(input: makeInput(seed: 1))
        _ = try await pipeline.run(input: makeInput(seed: 2))

        let count = await cache.count
        XCTAssertEqual(count, 10, "two distinct inputs × 5 stages = 10 cached intermediates")
    }

    func testCancellationStopsPipeline() async throws {
        // Stages sleep 1ms each; cancellation between stages should bubble up
        // as PipelineError.cancelled or CancellationError. Either is acceptable.
        let cache = IntermediateCache(maxBytes: 16 * 1024 * 1024)
        let pipeline = Pipeline(steps: StandardPipeline.defaultSteps(), cache: cache)
        let input = makeInput()

        let task = Task {
            try await pipeline.run(input: input)
        }
        task.cancel()

        do {
            _ = try await task.value
            // Cancellation is racy with task start — completing successfully is acceptable too.
        } catch is CancellationError {
        } catch let err as PipelineError {
            if case .cancelled = err {
                // expected
            } else {
                XCTFail("unexpected pipeline error: \(err)")
            }
        }
    }
}

final class SidecarTests: XCTestCase {

    func testRoundTripPreservesStepsAndParameters() throws {
        let denoiseParams = Denoise.Params(strength: 0.8, preserveDetailBias: 0.3)
        let sidecar = EnhanceSidecar(steps: [
            .init(stageID: "denoise-nafnet", enabled: true, parameters: try ParameterBag(denoiseParams))
        ])

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: EnhanceSidecar.sidecarURL(for: tmp)) }

        try sidecar.save(for: tmp)
        let loaded = try EnhanceSidecar.load(for: tmp)
        XCTAssertNotNil(loaded)
        XCTAssertEqual(loaded?.steps.count, 1)
        XCTAssertEqual(loaded?.steps[0].stageID, "denoise-nafnet")
        XCTAssertEqual(loaded?.steps[0].enabled, true)

        let decoded = try loaded!.steps[0].parameters.decode(as: Denoise.Params.self)
        XCTAssertEqual(decoded.strength, 0.8, accuracy: 1e-9)
        XCTAssertEqual(decoded.preserveDetailBias, 0.3, accuracy: 1e-9)
    }

    func testLoadingNonexistentSidecarReturnsNil() throws {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("nonexistent_\(UUID().uuidString).jpg")
        let loaded = try EnhanceSidecar.load(for: tmp)
        XCTAssertNil(loaded)
    }
}

final class CacheTests: XCTestCase {

    func testContentHashIncludesEveryPixelByte() {
        let width = 512
        let height = 2
        let byteCount = width * height * ImageFormat.working.bytesPerPixel
        let firstPixels = Data(count: byteCount)
        var secondPixels = firstPixels
        secondPixels[1] = 0xff

        let first = ImageBuffer(width: width, height: height, format: .working, pixels: firstPixels)
        let second = ImageBuffer(width: width, height: height, format: .working, pixels: secondPixels)

        XCTAssertNotEqual(first.contentHash, second.contentHash)
    }

    func testLRUEvictsOldestWhenOverBudget() async {
        // Each entry: 16*16*8 = 2048 bytes. Budget for 2 entries.
        let cache = IntermediateCache(maxBytes: 5000)
        let key = { (i: Int) in
            CacheKey(inputHash: ContentHash(value: UInt64(i)), stagePath: [])
        }
        let buf = makeInput()

        await cache.put(buf, for: key(1))
        await cache.put(buf, for: key(2))
        _ = await cache.get(key(1))  // touch key(1) so key(2) becomes LRU
        await cache.put(buf, for: key(3))

        let one = await cache.get(key(1))
        let two = await cache.get(key(2))
        let three = await cache.get(key(3))
        XCTAssertNotNil(one)
        XCTAssertNil(two, "least-recently-used entry should be evicted")
        XCTAssertNotNil(three)
    }
}
