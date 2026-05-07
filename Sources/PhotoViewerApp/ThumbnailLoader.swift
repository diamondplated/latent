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
@MainActor
final class ThumbnailLoader: ObservableObject {
    static let shared = ThumbnailLoader()

    private var cache: [URL: CGImage] = [:]
    private var inflight: [URL: Task<CGImage?, Never>] = [:]
    private let maxDimension: Int = 256

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

    func thumbnail(for url: URL) async -> CGImage? {
        if let cached = cache[url] { return cached }
        if let task = inflight[url] { return await task.value }

        let task = Task<CGImage?, Never> { [maxDimension] in
            await Self.makeThumbnail(url: url, maxDimension: maxDimension)
        }
        inflight[url] = task

        let result = await task.value
        inflight.removeValue(forKey: url)
        if let result { cache[url] = result }
        return result
    }

    /// Run the decode on the bounded operation queue rather than directly
    /// on a global GCD queue — caps concurrent decodes and lets the OS
    /// schedule fairly under load.
    private static func makeThumbnail(url: URL, maxDimension: Int) async -> CGImage? {
        await withCheckedContinuation { continuation in
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
