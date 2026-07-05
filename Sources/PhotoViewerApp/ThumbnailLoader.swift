import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Async thumbnail generation using ImageIO's downsample fast path.
///
/// Two changes from the early version:
///   1. Decode work is funneled through an `OperationQueue` capped at
///      half the machine's logical cores. Without this cap, every visible
///      cell on a 1000+-photo grid would fire its own detached Task and
///      a heavy first-render scroll would spike CPU into the red. The cap
///      lets the OS time-share predictably and keeps the rest of the UI
///      responsive (especially the main-actor scroll handler).
///   2. The cache holds CGImage rather than NSImage, matching the rest of
///      the display pipeline post-refactor — no needless wrap.
///   3. LRU eviction: the cache is bounded to `maxEntries` so a 10,000-
///      photo folder doesn't retain 2.5GB of decoded thumbnails. Oldest
///      (least-recently-used) entries are evicted first.
@MainActor
final class ThumbnailLoader: ObservableObject {
    static let shared = ThumbnailLoader()

    /// Maximum number of thumbnails held at once. At 256×256 RGBA (~256KB
    /// each), 500 entries ≈ 128MB. Generous enough that scrolling through
    /// several hundred photos doesn't re-decode, small enough that a
    /// 10k-photo folder won't blow out memory.
    let maxEntries: Int

    /// Thumbnail pixel dimension cap.
    let maxDimension: Int

    private var cache: [URL: CGImage] = [:]
    /// Insertion-order tracking for LRU eviction. Most-recently-used at
    /// the end; oldest at the front. `touch(_:)` promotes on hit.
    private var order: [URL] = []
    private var inflight: [URL: Task<CGImage?, Never>] = [:]

    /// Bounded-concurrency decode queue. ImageIO is CPU-bound; running it
    /// many-at-a-time on every core makes the whole machine sluggish without
    /// finishing thumbnails any faster on net. Half-cores leaves headroom
    /// for the renderer + main-actor scroll handling.
    private static let decodeQueue: OperationQueue = {
        let q = OperationQueue()
        q.maxConcurrentOperationCount = max(2, ProcessInfo.processInfo.activeProcessorCount / 2)
        q.qualityOfService = .userInitiated
        q.name = "Latent.ThumbnailLoader.Decode"
        return q
    }()

    init(maxEntries: Int = 500, maxDimension: Int = 256) {
        self.maxEntries = maxEntries
        self.maxDimension = maxDimension
    }

    func thumbnail(for url: URL) async -> CGImage? {
        if let cached = cache[url] {
            touch(url)
            return cached
        }
        if let task = inflight[url] { return await task.value }

        let task = Task<CGImage?, Never> { [maxDimension] in
            await Self.makeThumbnail(url: url, maxDimension: maxDimension)
        }
        inflight[url] = task

        let result = await task.value
        inflight.removeValue(forKey: url)
        if let result {
            insert(url: url, image: result)
        }
        return result
    }

    /// Remove a single URL from the cache. Called when a photo is trashed
    /// so its memory is freed immediately.
    func evict(url: URL) {
        cache.removeValue(forKey: url)
        order.removeAll { $0 == url }
        inflight[url]?.cancel()
        inflight.removeValue(forKey: url)
    }

    /// Drop everything. Called on folder change.
    func clear() {
        cache.removeAll()
        order.removeAll()
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
    }

    // MARK: - LRU internals

    /// Promote a URL to most-recently-used (end of order array).
    private func touch(_ url: URL) {
        if let idx = order.firstIndex(of: url) {
            order.remove(at: idx)
        }
        order.append(url)
    }

    /// Insert a new entry, evicting the oldest if over capacity.
    private func insert(url: URL, image: CGImage) {
        cache[url] = image
        touch(url)
        while cache.count > maxEntries, let oldest = order.first {
            order.removeFirst()
            cache.removeValue(forKey: oldest)
        }
    }

    /// Run the decode on the bounded operation queue rather than directly
    /// on a global GCD queue — caps concurrent decodes and lets the OS
    /// schedule fairly under load. Routes video URLs through the
    /// AVAssetImageGenerator path so the grid actually shows a frame for
    /// .mp4 / .mov etc. instead of a placeholder.
    private static func makeThumbnail(url: URL, maxDimension: Int) async -> CGImage? {
        let kind = MediaTyping.detect(url)
        if kind == .video {
            return await VideoThumbnail.generate(url: url, maxDimension: maxDimension)
        }
        return await withCheckedContinuation { continuation in
            decodeQueue.addOperation {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,  // honors EXIF orientation
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: cg)
            }
        }
    }
}

