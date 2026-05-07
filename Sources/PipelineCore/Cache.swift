import Foundation

/// Compound key for cached pipeline intermediates.
///
/// Format: input content hash + ordered list of (stage id, params hash) for
/// every stage that ran before this point. Toggling a stage off or changing
/// its params produces a different key, but everything upstream stays cached.
public struct CacheKey: Hashable, Sendable {
    public let inputHash: ContentHash
    public let stagePath: [StageStep]

    public struct StageStep: Hashable, Sendable {
        public let stageID: StageID
        public let paramsHash: UInt64
    }

    public init(inputHash: ContentHash, stagePath: [StageStep]) {
        self.inputHash = inputHash
        self.stagePath = stagePath
    }
}

/// Approximate cost of an entry, used for LRU eviction.
public struct CacheCost: Sendable {
    /// Bytes the entry occupies (pixel data size).
    public let bytes: Int

    public init(bytes: Int) { self.bytes = bytes }
}

/// Thread-safe LRU cache for pipeline intermediates, bounded by total bytes.
///
/// Implemented as an actor so concurrent stages can read/write without races.
/// Eviction policy: when total bytes would exceed `maxBytes`, evict
/// least-recently-used entries until under the limit.
public actor IntermediateCache {
    private struct Entry {
        let buffer: ImageBuffer
        let cost: CacheCost
        var lastAccess: UInt64
    }

    private var entries: [CacheKey: Entry] = [:]
    private var totalBytes: Int = 0
    private var accessCounter: UInt64 = 0
    public let maxBytes: Int

    public init(maxBytes: Int) {
        precondition(maxBytes > 0)
        self.maxBytes = maxBytes
    }

    public func get(_ key: CacheKey) -> ImageBuffer? {
        guard var entry = entries[key] else { return nil }
        accessCounter &+= 1
        entry.lastAccess = accessCounter
        entries[key] = entry
        return entry.buffer
    }

    public func put(_ buffer: ImageBuffer, for key: CacheKey) {
        let cost = CacheCost(bytes: buffer.pixels.count)
        if let existing = entries[key] {
            totalBytes -= existing.cost.bytes
        }
        accessCounter &+= 1
        entries[key] = Entry(buffer: buffer, cost: cost, lastAccess: accessCounter)
        totalBytes += cost.bytes
        evictIfNeeded()
    }

    public func clear() {
        entries.removeAll()
        totalBytes = 0
    }

    public var count: Int { entries.count }
    public var bytes: Int { totalBytes }

    private func evictIfNeeded() {
        guard totalBytes > maxBytes else { return }
        // Sort by lastAccess ascending and evict from the front until under budget.
        let sorted = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (key, entry) in sorted {
            if totalBytes <= maxBytes { break }
            entries.removeValue(forKey: key)
            totalBytes -= entry.cost.bytes
        }
    }
}
