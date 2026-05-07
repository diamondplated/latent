import Foundation
import CoreML

/// Process-wide cache of loaded CoreML models. Loading an `.mlpackage` is
/// expensive (~hundreds of ms, plus first-call ANE warmup). The pipeline can
/// run hundreds of times in a session — share loaded models across all runs.
public actor ModelManager {
    public static let shared = ModelManager()

    private var cache: [ModelID: CoreMLImageModel] = [:]
    /// Negative cache: model attempted to load but file missing. Avoid
    /// retrying on every Pipeline.run.
    private var unavailable: Set<ModelID> = []

    /// Returns a loaded model for `id`, or nil if the model file isn't on
    /// disk yet. Subsequent calls hit the cache.
    public func model(for id: ModelID, spec: TensorSpec, computeUnits: MLComputeUnits = .all) async throws -> CoreMLImageModel? {
        if unavailable.contains(id) { return nil }
        if let existing = cache[id] { return existing }

        guard ModelRegistry.url(for: id) != nil else {
            unavailable.insert(id)
            return nil
        }

        let model = try await CoreMLImageModel(id: id, spec: spec, computeUnits: computeUnits)
        cache[id] = model
        return model
    }

    /// Forget any cached or negatively-cached state. Useful after the user
    /// downloads new models so subsequent calls discover them.
    public func reset() {
        cache.removeAll()
        unavailable.removeAll()
    }
}
