import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// One-shot result shared by the operation-queue worker and every caller
/// awaiting the same URL. The queue performs synchronous ImageIO work and
/// holds its permit while AVFoundation's async frame extraction runs, so the
/// result has to bridge both execution styles without touching the main actor.
private final class ThumbnailDecodeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var isResolved = false
    private var image: CGImage?
    private var waiters: [CheckedContinuation<CGImage?, Never>] = []

    func value() async -> CGImage? {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isResolved {
                let image = self.image
                lock.unlock()
                continuation.resume(returning: image)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func resolve(_ image: CGImage?) {
        lock.lock()
        guard !isResolved else {
            lock.unlock()
            return
        }
        isResolved = true
        self.image = image
        let pending = waiters
        waiters.removeAll(keepingCapacity: false)
        lock.unlock()

        for continuation in pending {
            continuation.resume(returning: image)
        }
    }
}

/// A single physical thumbnail decode. Video extraction is async inside
/// AVFoundation, but this operation deliberately retains its queue permit
/// until the requested frame arrives. Consequently videos and stills share
/// the same process-wide concurrency ceiling instead of every video spawning
/// an unconstrained AVAssetImageGenerator job.
private final class ThumbnailDecodeOperation: Operation, @unchecked Sendable {
    private let url: URL
    private let maxDimension: Int
    private let result: ThumbnailDecodeResult
    private let isVideo: Bool
    private let stateLock = NSLock()
    private var startedDecode = false
    private var videoTask: Task<Void, Never>?

    /// A malformed or remote-backed file must not occupy a thumbnail worker
    /// forever. AVFoundation receives cancellation at this deadline; the
    /// operation then releases its queue permit.
    private static let videoTimeout: DispatchTimeInterval = .seconds(15)
    /// Timed-out AVFoundation tasks can take a moment to acknowledge
    /// cancellation. Keep their generator permit until they actually return,
    /// so repeated malformed files can never accumulate unbounded decoder
    /// work after their OperationQueue slots have been released.
    private static let videoGenerationSlots = DispatchSemaphore(value: 2)
    private static let videoSlotPollNanoseconds: UInt64 = 100_000_000

    init(url: URL, maxDimension: Int, result: ThumbnailDecodeResult) {
        self.url = url
        self.maxDimension = maxDimension
        self.result = result
        self.isVideo = MediaTyping.detect(url) == .video
        super.init()
    }

    override func main() {
        stateLock.lock()
        guard !isCancelled else {
            stateLock.unlock()
            result.resolve(nil)
            return
        }
        startedDecode = true
        stateLock.unlock()

        if isVideo {
            // OperationQueue only accounts for synchronous operations until
            // main() returns. Wait for AVFoundation here so its async work
            // continues to occupy this operation's bounded queue slot.
            let deadline = DispatchTime.now() + Self.videoTimeout
            guard acquireVideoGenerationSlot(until: deadline) else {
                result.resolve(nil)
                return
            }

            let completed = DispatchSemaphore(value: 0)
            let worker = Task.detached(priority: .userInitiated) { [url, maxDimension, result] in
                defer {
                    Self.videoGenerationSlots.signal()
                    completed.signal()
                }
                let image = await VideoThumbnail.generate(
                    url: url,
                    maxDimension: maxDimension
                )
                result.resolve(Task.isCancelled ? nil : image)
            }

            stateLock.lock()
            videoTask = worker
            let cancelledBeforeRegistration = isCancelled
            stateLock.unlock()
            if cancelledBeforeRegistration { worker.cancel() }

            if completed.wait(timeout: deadline) == .timedOut {
                worker.cancel()
                result.resolve(nil)
            }

            stateLock.lock()
            videoTask = nil
            stateLock.unlock()
            return
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,  // honors EXIF orientation
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
            result.resolve(nil)
            return
        }
        result.resolve(cg)
    }

    /// Acquire the stricter AVFoundation gate without making cancellation
    /// wait for the entire decode deadline. Polling is confined to this
    /// OperationQueue worker (never a cooperative Swift-concurrency thread).
    private func acquireVideoGenerationSlot(until deadline: DispatchTime) -> Bool {
        while !isCancelled {
            let now = DispatchTime.now().uptimeNanoseconds
            let limit = deadline.uptimeNanoseconds
            guard now < limit else { return false }
            let nextPoll = DispatchTime(
                uptimeNanoseconds: min(limit, now &+ Self.videoSlotPollNanoseconds)
            )
            if Self.videoGenerationSlots.wait(timeout: nextPoll) == .success {
                return true
            }
        }
        return false
    }

    /// Cancel work that no longer has a consumer. Queued work is discarded
    /// immediately. A running AVFoundation request is cancellation-aware, so
    /// it is stopped and its queue permit released. ImageIO is synchronous and
    /// cannot be interrupted after entry; its stale result is suppressed by
    /// the loader's identity/generation checks.
    ///
    /// Returns true when the operation is queued or is a cancellable video,
    /// allowing the loader to forget it immediately. A running still returns
    /// false so a quick re-request can reuse that unavoidable decode.
    @discardableResult
    func cancelWhenUnused() -> Bool {
        stateLock.lock()
        if !startedDecode {
            super.cancel()
            stateLock.unlock()
            // A cancelled queued operation may never enter main(), so wake
            // every caller instead of leaving its continuation suspended.
            result.resolve(nil)
            return true
        }

        guard isVideo else {
            stateLock.unlock()
            return false
        }

        super.cancel()
        let worker = videoTask
        stateLock.unlock()

        // Resolving first lets cancelled UI tasks unwind immediately even if
        // AVFoundation takes a moment to observe cancellation.
        result.resolve(nil)
        worker?.cancel()
        return true
    }
}

/// Async thumbnail generation using bounded ImageIO/AVFoundation workers.
///
/// Key changes from the early version:
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
    private struct InflightThumbnail {
        let id: UUID
        let decodeGeneration: UInt64
        let operation: ThumbnailDecodeOperation
        let task: Task<CGImage?, Never>
        var consumers: Set<UUID>
    }

    /// Cancellation handlers are `@Sendable` and may run off the main actor.
    /// Boxing the weak actor-isolated owner keeps that cross-thread handoff
    /// explicit; the actual state mutation is always scheduled on MainActor.
    private final class ConsumerCancellation: @unchecked Sendable {
        private weak var loader: ThumbnailLoader?
        private let url: URL
        private let decodeID: UUID
        private let consumerID: UUID

        init(loader: ThumbnailLoader, url: URL, decodeID: UUID, consumerID: UUID) {
            self.loader = loader
            self.url = url
            self.decodeID = decodeID
            self.consumerID = consumerID
        }

        func cancel() {
            Task { @MainActor [weak loader, url, decodeID, consumerID] in
                loader?.cancelConsumer(
                    for: url,
                    decodeID: decodeID,
                    consumerID: consumerID
                )
            }
        }
    }

    private var inflight: [URL: InflightThumbnail] = [:]
    /// Invalidates completions from a folder/cache generation that has already
    /// been cleared. ImageIO work is synchronous once it reaches the operation
    /// queue, so cancellation alone cannot provide this guarantee.
    private var generation: UInt64 = 0

    /// Bounded-concurrency decode queue. ImageIO and video frame extraction
    /// both run through this physical gate. Half-cores leaves headroom for the
    /// renderer + main-actor scroll handling.
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
        guard !Task.isCancelled else { return nil }
        if let cached = cache[url] {
            touch(url)
            return cached
        }

        let consumerID = UUID()
        if var decode = inflight[url] {
            decode.consumers.insert(consumerID)
            inflight[url] = decode
            return await awaitThumbnail(
                for: url,
                decode: decode,
                consumerID: consumerID
            )
        }

        let id = UUID()
        let resultBox = ThumbnailDecodeResult()
        let operation = ThumbnailDecodeOperation(
            url: url,
            maxDimension: maxDimension,
            result: resultBox
        )
        let task = Task.detached(priority: .userInitiated) {
            await resultBox.value()
        }
        inflight[url] = InflightThumbnail(
            id: id,
            decodeGeneration: generation,
            operation: operation,
            task: task,
            consumers: [consumerID]
        )
        Self.decodeQueue.addOperation(operation)

        guard let decode = inflight[url], decode.id == id else { return nil }
        return await awaitThumbnail(
            for: url,
            decode: decode,
            consumerID: consumerID
        )
    }

    /// Remove a single URL from the cache. Called when a photo is trashed
    /// so its memory is freed immediately.
    func evict(url: URL) {
        cache.removeValue(forKey: url)
        order.removeAll { $0 == url }
        inflight[url]?.operation.cancelWhenUnused()
        inflight.removeValue(forKey: url)
    }

    /// Drop everything. Called on folder change.
    func clear() {
        generation &+= 1
        cache.removeAll()
        order.removeAll()
        for (_, decode) in inflight {
            decode.operation.cancelWhenUnused()
        }
        inflight.removeAll()
    }

    // MARK: - In-flight lifecycle

    /// Await one shared decode while tracking this specific caller. SwiftUI
    /// cancels a cell's `.task` when it scrolls out of view; when that was the
    /// final consumer, queued work is pruned instead of accumulating behind
    /// currently visible thumbnails.
    private func awaitThumbnail(
        for url: URL,
        decode: InflightThumbnail,
        consumerID: UUID
    ) async -> CGImage? {
        let cancellation = ConsumerCancellation(
            loader: self,
            url: url,
            decodeID: decode.id,
            consumerID: consumerID
        )
        let image = await withTaskCancellationHandler {
            await decode.task.value
        } onCancel: {
            cancellation.cancel()
        }

        let callerWasCancelled = Task.isCancelled
        return finishConsumer(
            for: url,
            decodeID: decode.id,
            decodeGeneration: decode.decodeGeneration,
            consumerID: consumerID,
            image: image,
            callerWasCancelled: callerWasCancelled
        )
    }

    private func cancelConsumer(for url: URL, decodeID: UUID, consumerID: UUID) {
        guard var decode = inflight[url], decode.id == decodeID,
              decode.consumers.remove(consumerID) != nil else { return }

        guard decode.consumers.isEmpty else {
            inflight[url] = decode
            return
        }

        if decode.operation.cancelWhenUnused() {
            inflight.removeValue(forKey: url)
        } else {
            // Synchronous ImageIO is already running. Keep the job available
            // for a quick re-request, but never cache it unless a live caller
            // has joined by the time it completes.
            inflight[url] = decode
        }
    }

    private func finishConsumer(
        for url: URL,
        decodeID: UUID,
        decodeGeneration: UInt64,
        consumerID: UUID,
        image: CGImage?,
        callerWasCancelled: Bool
    ) -> CGImage? {
        guard var decode = inflight[url], decode.id == decodeID else {
            // clear(), evict(), or a replacement decode invalidated this
            // result. Never hand stale pixels back to either an original
            // caller or a caller that joined the shared task later.
            return nil
        }

        let wasActiveConsumer = decode.consumers.remove(consumerID) != nil
        let isCurrent = decode.decodeGeneration == decodeGeneration
            && decodeGeneration == generation
        let mayUseResult = wasActiveConsumer && !callerWasCancelled && isCurrent

        if mayUseResult, let image {
            insert(url: url, image: image)
        }

        if decode.consumers.isEmpty {
            inflight.removeValue(forKey: url)
        } else {
            inflight[url] = decode
        }

        return mayUseResult ? image : nil
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

}
