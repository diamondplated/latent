import Foundation

public typealias StageID = String

/// A single transformation in the enhancement pipeline.
///
/// Stages are pure functions of `(input, parameters) → output`. They must not
/// depend on hidden state, so the cache layer can safely memoize on
/// `(input.contentHash, params.stableHash)`.
public protocol Stage: Sendable {
    associatedtype Params: StageParameters

    var id: StageID { get }
    var displayName: String { get }

    /// Run the stage. Implementations should honor cooperative cancellation
    /// (`Task.checkCancellation()`) at chunk boundaries on long operations.
    func process(input: ImageBuffer, params: Params, progress: ProgressReporter) async throws -> ImageBuffer
}

/// Parameters for a stage. Must be deterministically hashable so the cache
/// produces the same key for equivalent param values across runs.
public protocol StageParameters: Sendable, Hashable {
    /// 64-bit hash that's stable across process restarts. Default
    /// implementation uses Swift's `Hasher`, which is salted per-process —
    /// override if you need cross-run cache hits (e.g., for the on-disk
    /// sidecar cache).
    var stableHash: UInt64 { get }
}

extension StageParameters {
    public var stableHash: UInt64 {
        var hasher = Hasher()
        hasher.combine(self)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}

/// Type-erased stage so a Pipeline can hold a heterogeneous chain.
public struct AnyStage: Sendable {
    public let id: StageID
    public let displayName: String
    private let _process: @Sendable (ImageBuffer, ProgressReporter) async throws -> ImageBuffer
    public let paramsHash: UInt64

    public init<S: Stage>(_ stage: S, params: S.Params) {
        self.id = stage.id
        self.displayName = stage.displayName
        self.paramsHash = params.stableHash
        self._process = { input, progress in
            try await stage.process(input: input, params: params, progress: progress)
        }
    }

    public func run(_ input: ImageBuffer, progress: ProgressReporter) async throws -> ImageBuffer {
        try await _process(input, progress)
    }
}

/// Reports per-stage progress from 0.0 to 1.0. UI binds to this to draw
/// per-stage progress bars; tests can use a no-op reporter.
public struct ProgressReporter: Sendable {
    private let _report: @Sendable (Double) -> Void

    public init(_ report: @escaping @Sendable (Double) -> Void) {
        self._report = report
    }

    public static let noop = ProgressReporter { _ in }

    public func report(_ fraction: Double) {
        _report(min(1.0, max(0.0, fraction)))
    }
}
