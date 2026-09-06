import Foundation
import SwiftUI
import PhotoIO

/// Process-wide physical gate for image decoding. Both speculative previews and
/// pipeline-ready full-buffer reads use this queue, so rapid navigation cannot
/// leave more than two synchronous ImageIO/Core Image conversions executing at
/// once even after their logical Swift tasks have been cancelled.
enum ImageDecodeWorkQueue {
    static let shared: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "Latent.ImageDecode"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 2
        return queue
    }()
}

/// One-shot result shared by every waiter for a URL. `NSLock` is used instead
/// of actor isolation because the ImageIO operation completes on an
/// `OperationQueue` worker while callers await from the main actor.
private final class PreviewDecodeResult: @unchecked Sendable {
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

/// A synchronous ImageIO decode occupying one real queue permit. Queued work
/// can be cancelled; once `main()` enters ImageIO it stays registered and keeps
/// its OperationQueue slot until the non-interruptible decode returns.
private final class PreviewDecodeOperation: Operation, @unchecked Sendable {
    private let url: URL
    private let result: PreviewDecodeResult
    private let stateLock = NSLock()
    private var startedImageIO = false

    init(url: URL, result: PreviewDecodeResult) {
        self.url = url
        self.result = result
        super.init()
    }

    override func main() {
        stateLock.lock()
        guard !isCancelled else {
            stateLock.unlock()
            result.resolve(nil)
            return
        }
        startedImageIO = true
        stateLock.unlock()

        let image = ImageReader.previewCGImage(url: url)
        result.resolve(image)
    }

    /// Cancel only while the operation is still queued. Once ImageIO starts it
    /// cannot be interrupted, so keeping that operation reusable lets a URL
    /// that quickly re-enters the window await the same physical decode.
    func cancelIfQueued() -> Bool {
        stateLock.lock()
        guard !startedImageIO else {
            stateLock.unlock()
            return false
        }
        super.cancel()
        stateLock.unlock()

        // A queued cancelled operation may never enter `main`; wake waiters now.
        result.resolve(nil)
        return true
    }
}

/// In-memory ring cache for full-resolution CGImages around the current
/// selection. Holds at most `capacity` decoded images; speculatively
/// decodes the user's likely next picks (±2 by default) so the next arrow
/// press has its image ready and the swap is sub-frame.
///
/// **No disk persistence** — the cache lives only as long as the process.
/// Memory is bounded by both entry count and decoded byte cost, regardless of
/// folder size, so unusually large RAW files cannot multiply into a surprise
/// gigabyte-scale cache.
///
/// Cancellation: when the window changes, queued work that left it is removed.
/// Already-running ImageIO calls cannot be interrupted, so they keep one of the
/// two physical permits until return; their stale results are then discarded.
///
/// Memory math: typical JPEG decoded RGBA8 is ~24MP × 4 bytes = ~96MB.
/// The default byte ceiling adapts to physical memory and never exceeds
/// 384 MiB. Warning/critical memory pressure clears the cache immediately.
@MainActor
@Observable
final class ImagePrefetcher {
    /// Maximum number of decoded images held at once. Picked so the typical
    /// "current + 2 each side" window fits exactly. Bumping this gives more
    /// headroom for users who hold the arrow key, at memory cost.
    let capacity: Int
    let maxBytes: Int

    /// LRU storage. Insertion order is preserved; oldest at the front,
    /// newest (most-recently used) at the back. We use an array because
    /// the typical capacity is tiny (5–7) and array lookup at this scale
    /// is faster than a hash map's overhead.
    private var entries: [(url: URL, image: CGImage, cost: Int)] = []
    private var totalCost = 0
    private struct DecodeJob {
        let id: UUID
        let operation: PreviewDecodeOperation
        let resultTask: Task<CGImage?, Never>
    }

    /// All queued or running decodes keyed by URL. The identity token keeps
    /// an old task's completion from removing or committing over a newer task
    /// for the same URL after rapid navigation.
    private var jobs: [URL: DecodeJob] = [:]
    /// The current retention window (focus + neighbors). Results may commit
    /// only while their URL is still requested.
    private var requestedURLs: Set<URL> = []
    /// Ordered speculative work. The visible focus is queued separately at
    /// foreground priority before these neighbors.
    private var requestedNeighbors: [URL] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    init(capacity: Int = 5, maxBytes: Int? = nil) {
        self.capacity = capacity
        let mib = 1_024 * 1_024
        let adaptive = Int(ProcessInfo.processInfo.physicalMemory / 32)
        self.maxBytes = maxBytes ?? min(384 * mib, max(128 * mib, adaptive))

        let source = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning, .critical],
            queue: .main
        )
        source.setEventHandler { [weak self] in self?.clear() }
        source.resume()
        memoryPressureSource = source
    }

    // MARK: - Lookup

    /// Synchronous cache hit-test. Touches the LRU so a hit re-promotes
    /// the entry. Returns nil on miss — callers that need the image now can
    /// await `foregroundDecode(for:)`, sharing the same bounded decode queue.
    func image(for url: URL) -> CGImage? {
        guard let idx = entries.firstIndex(where: { $0.url == url }) else { return nil }
        let entry = entries.remove(at: idx)
        entries.append(entry)  // move-to-end = most recently used
        return entry.image
    }

    // MARK: - Window updates

    /// Update the prefetch window. `focus` is the currently-displayed
    /// photo; `neighbors` are the URLs that should be pre-decoded (±2
    /// in the photo list, typically). URLs outside the union of focus +
    /// neighbors get evicted; in-flight decodes for them are cancelled.
    func updateWindow(focus: URL?, neighbors: [URL]) {
        var keep: Set<URL> = Set(neighbors)
        if let focus { keep.insert(focus) }
        requestedURLs = keep

        var seen: Set<URL> = []
        requestedNeighbors = neighbors.filter { url in
            url != focus && seen.insert(url).inserted
        }
        let speculative = Set(requestedNeighbors)

        // 1) Cancel work that left the entire window. Keep a former neighbor's
        //    job when it becomes focus so the foreground can await/promote the
        //    same decode instead of starting a duplicate.
        let obsolete = jobs.keys.filter { !keep.contains($0) }
        for url in obsolete {
            guard let job = jobs[url] else { continue }
            if job.operation.cancelIfQueued() {
                jobs.removeValue(forKey: url)
            } else {
                // ImageIO is already running and cannot be stopped. Retain the
                // URL/job association until it returns so a quick navigation
                // back to this URL reuses the same physical decode.
                job.operation.queuePriority = .veryLow
            }
        }
        // Queue priority is mutable until execution begins. Demote retained
        // former focuses and promote an already-requested current focus.
        for (url, job) in jobs {
            if url == focus {
                promote(job.operation)
            } else if speculative.contains(url) {
                job.operation.queuePriority = .normal
            }
        }

        // 2) Evict cached entries outside the window. (LRU is a separate
        //    eviction trigger; this is the explicit "user moved on" pass.)
        entries.removeAll { !keep.contains($0.url) }
        totalCost = entries.reduce(0) { $0 + $1.cost }

        // 3) Register the visible decode before speculative work so it wins an
        //    available queue slot. DetailView then awaits this exact job.
        if let focus, !contains(focus) {
            _ = decodeTask(for: focus, foreground: true)
        }
        scheduleRequestedDecodes()
    }

    /// Return the shared decode task for the visible photo, promoting an
    /// existing speculative job when possible. `updateWindow` normally starts
    /// this first; the fallback makes the API safe for direct callers too.
    func foregroundDecode(for url: URL) -> Task<CGImage?, Never> {
        requestedURLs.insert(url)
        return decodeTask(for: url, foreground: true)
    }

    /// Drop a single URL from the cache and cancel any pending decode for
    /// it. Called by `state.trashImage(at:)` so trashed photos free their
    /// memory immediately and don't get re-prefetched.
    func evict(url: URL) {
        requestedURLs.remove(url)
        requestedNeighbors.removeAll { $0 == url }
        if let job = jobs[url] {
            _ = job.operation.cancelIfQueued()
            // Even a running ImageIO operation must lose its cache identity.
            // It can finish physically, but finishDecode's UUID gate will
            // discard it while a fresh same-URL request starts a new job.
            jobs.removeValue(forKey: url)
        }
        entries.removeAll { $0.url == url }
        totalCost = entries.reduce(0) { $0 + $1.cost }
    }

    /// Wipe everything. Called when the active folder changes — the new
    /// folder's URLs share no overlap with the old one, so the entire
    /// cache is stale.
    func clear() {
        requestedURLs.removeAll()
        requestedNeighbors.removeAll()
        for url in Array(jobs.keys) {
            guard let job = jobs[url] else { continue }
            _ = job.operation.cancelIfQueued()
        }
        // Running ImageIO cannot be interrupted, but removing every identity
        // prevents a same-URL request in the new generation from reusing or
        // committing its stale result.
        jobs.removeAll()
        entries.removeAll()
        totalCost = 0
    }

    // MARK: - Internals

    private func contains(_ url: URL) -> Bool {
        entries.contains { $0.url == url }
    }

    private func scheduleRequestedDecodes() {
        // Queue at most the current navigation window. A later update cancels
        // queued stale operations, so rapid navigation cannot build an
        // unbounded backlog behind the two physical worker slots.
        let pending = requestedNeighbors
        requestedNeighbors.removeAll(keepingCapacity: true)
        for url in pending {
            guard requestedURLs.contains(url), !contains(url), jobs[url] == nil else { continue }
            _ = decodeTask(for: url, foreground: false)
        }
    }

    private func decodeTask(for url: URL, foreground: Bool) -> Task<CGImage?, Never> {
        if let existing = jobs[url] {
            if foreground { promote(existing.operation) }
            return existing.resultTask
        }

        let id = UUID()
        let result = PreviewDecodeResult()
        let operation = PreviewDecodeOperation(url: url, result: result)
        operation.queuePriority = foreground ? .veryHigh : .normal
        operation.qualityOfService = foreground ? .userInitiated : .utility
        let resultTask = Task.detached(priority: foreground ? .userInitiated : .utility) {
            await result.value()
        }
        jobs[url] = DecodeJob(id: id, operation: operation, resultTask: resultTask)

        Task { @MainActor [weak self, resultTask] in
            let image = await resultTask.value
            self?.finishDecode(url: url, id: id, image: image)
        }
        ImageDecodeWorkQueue.shared.addOperation(operation)
        return resultTask
    }

    private func promote(_ operation: PreviewDecodeOperation) {
        operation.queuePriority = .veryHigh
        operation.qualityOfService = .userInitiated
    }

    private func finishDecode(url: URL, id: UUID, image: CGImage?) {
        // A cancelled task for an older window (or older attempt for this URL)
        // must not tear down or commit over the current one.
        guard jobs[url]?.id == id else { return }
        jobs.removeValue(forKey: url)
        if let image, requestedURLs.contains(url) {
            commit(url: url, image: image)
        }
    }

    /// Insert a freshly-decoded image, enforcing both count and byte limits.
    /// The caller has already verified that the URL remains in the requested
    /// window, so stale navigation results never enter the cache.
    private func commit(url: URL, image: CGImage) {
        // De-dupe: if a parallel path beat us to it, nothing to do.
        if entries.contains(where: { $0.url == url }) { return }
        let cost = image.bytesPerRow * image.height
        // A single image larger than the entire budget is still displayed by
        // the caller's normal load path; retaining it here would defeat the
        // purpose of a bounded speculative cache.
        guard cost <= maxBytes else { return }
        entries.append((url: url, image: image, cost: cost))
        totalCost += cost
        // LRU eviction by both count and actual decoded bytes.
        while entries.count > capacity || totalCost > maxBytes {
            totalCost -= entries.removeFirst().cost
        }
    }
}
