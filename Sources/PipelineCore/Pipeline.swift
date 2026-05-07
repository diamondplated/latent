import Foundation

public enum PipelineError: Error, Sendable, CustomStringConvertible {
    case cancelled
    case stageFailed(stageID: StageID, underlying: Error)

    public var description: String {
        switch self {
        case .cancelled:
            return "Pipeline cancelled"
        case .stageFailed(let id, let err):
            return "Stage \(id) failed: \(err)"
        }
    }
}

/// One step in the pipeline chain. Wraps a type-erased stage with an
/// `enabled` flag so the UI can toggle stages without rebuilding the whole
/// chain.
public struct PipelineStep: Sendable {
    public var stage: AnyStage
    public var enabled: Bool

    public init(stage: AnyStage, enabled: Bool = true) {
        self.stage = stage
        self.enabled = enabled
    }

    public var stageID: StageID { stage.id }
    public var displayName: String { stage.displayName }
}

/// Reports overall pipeline progress and per-stage events to the UI.
public protocol PipelineObserver: Sendable {
    func stageStarted(stageID: StageID, displayName: String) async
    func stageProgress(stageID: StageID, fraction: Double) async
    func stageCompleted(stageID: StageID, cacheHit: Bool) async
}

public struct NullObserver: PipelineObserver {
    public init() {}
    public func stageStarted(stageID: StageID, displayName: String) async {}
    public func stageProgress(stageID: StageID, fraction: Double) async {}
    public func stageCompleted(stageID: StageID, cacheHit: Bool) async {}
}

/// Linear chain executor with intermediate caching.
///
/// Run order: input → step[0] → step[1] → ... → step[n-1] → output. Disabled
/// steps are skipped (their input passes through unchanged). Cache key after
/// step k is `(inputHash, [enabled steps 0...k as (id, paramsHash)])`. Toggle
/// a step off and the upstream cache hits still apply; downstream is recomputed
/// once with the new path.
public struct Pipeline: Sendable {
    public let steps: [PipelineStep]
    public let cache: IntermediateCache

    public init(steps: [PipelineStep], cache: IntermediateCache) {
        // Stage IDs must be unique within a pipeline: the cache key
        // `(inputHash, [(stageID, paramsHash)...])` would collide for two
        // stages sharing an id, serving the output of one as the output of
        // the other. Cheap precondition prevents a silent data-correctness bug.
        let ids = steps.map(\.stageID)
        precondition(Set(ids).count == ids.count, "duplicate stage IDs in pipeline: \(ids)")
        self.steps = steps
        self.cache = cache
    }

    public func run(
        input: ImageBuffer,
        observer: PipelineObserver = NullObserver()
    ) async throws -> ImageBuffer {
        var current = input
        var path: [CacheKey.StageStep] = []

        for step in steps {
            // Map raw CancellationError to PipelineError.cancelled so callers
            // only ever need to catch one error type for cancellation.
            if Task.isCancelled { throw PipelineError.cancelled }

            guard step.enabled else { continue }

            let pathStep = CacheKey.StageStep(stageID: step.stageID, paramsHash: step.stage.paramsHash)
            path.append(pathStep)
            // Always key off the original pipeline input, not `current` — the
            // path encodes all transformations, so `(inputHash, path)` is
            // uniquely correct. Keying off `current.contentHash` would be wrong:
            // two distinct inputs that happen to produce identical intermediates
            // would share cache keys past that point.
            let key = CacheKey(inputHash: input.contentHash, stagePath: path)

            await observer.stageStarted(stageID: step.stageID, displayName: step.displayName)

            if let cached = await cache.get(key) {
                await observer.stageCompleted(stageID: step.stageID, cacheHit: true)
                current = cached
                continue
            }

            let progress = ProgressReporter { fraction in
                Task { await observer.stageProgress(stageID: step.stageID, fraction: fraction) }
            }

            let output: ImageBuffer
            do {
                output = try await step.stage.run(current, progress: progress)
            } catch is CancellationError {
                throw PipelineError.cancelled
            } catch {
                throw PipelineError.stageFailed(stageID: step.stageID, underlying: error)
            }

            await cache.put(output, for: key)
            await observer.stageCompleted(stageID: step.stageID, cacheHit: false)
            current = output
        }

        return current
    }
}
