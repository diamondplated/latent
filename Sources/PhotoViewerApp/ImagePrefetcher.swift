import Foundation
import SwiftUI
import ImageIO

/// In-memory ring cache for full-resolution CGImages around the current
/// selection. Holds at most `capacity` decoded images; speculatively
/// decodes the user's likely next picks (±2 by default) so the next arrow
/// press has its image ready and the swap is sub-frame.
///
/// **No disk persistence** — the cache lives only as long as the process.
/// Memory is bounded by `capacity` × per-image size, regardless of folder
/// size, so a 100k-photo folder costs the same as a 100-photo folder.
///
/// Cancellation: when the window changes (user navigated), in-flight
/// decodes for URLs that left the window are cancelled; their tasks
/// observe `Task.isCancelled` after the CGImageSource hand-off and bail
/// without committing. Stale results are dropped on the main-actor commit.
///
/// Memory math: typical JPEG decoded RGBA8 is ~24MP × 4 bytes = ~96MB.
/// At capacity 5, the worst-case footprint is ~480MB. Acceptable for a
/// desktop app on Apple Silicon (16GB+ standard); if a user pushes a
/// folder of 50MP RAWs the cache stays bounded but the per-entry size
/// grows. Cap remains the same.
@MainActor
@Observable
final class ImagePrefetcher {
    /// Maximum number of decoded images held at once. Picked so the typical
    /// "current + 2 each side" window fits exactly. Bumping this gives more
    /// headroom for users who hold the arrow key, at memory cost.
    let capacity: Int

    /// LRU storage. Insertion order is preserved; oldest at the front,
    /// newest (most-recently used) at the back. We use an array because
    /// the typical capacity is tiny (5–7) and array lookup at this scale
    /// is faster than a hash map's overhead.
    private var entries: [(url: URL, image: CGImage)] = []
    /// In-flight decodes keyed by URL. Cancelled when the URL leaves the
    /// window or the cache is cleared.
    private var inflight: [URL: Task<Void, Never>] = [:]

    init(capacity: Int = 5) {
        self.capacity = capacity
    }

    // MARK: - Lookup

    /// Synchronous cache hit-test. Touches the LRU so a hit re-promotes
    /// the entry. Returns nil on miss — caller should fall back to its
    /// own decode path (the prefetcher will try again next window update).
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

        // 1) Cancel in-flight decodes for URLs no longer in the window.
        for (url, task) in inflight where !keep.contains(url) {
            task.cancel()
            inflight.removeValue(forKey: url)
        }

        // 2) Evict cached entries outside the window. (LRU is a separate
        //    eviction trigger; this is the explicit "user moved on" pass.)
        entries.removeAll { !keep.contains($0.url) }

        // 3) Schedule decodes for URLs in the window we don't have and
        //    aren't already decoding. Order: focus first (the visible
        //    photo, in case it was somehow missed), then neighbors. The
        //    decode itself is on Task.detached(.userInitiated) so it
        //    competes fairly with foreground work.
        let scheduleOrder: [URL] = (focus.map { [$0] } ?? []) + neighbors
        for url in scheduleOrder where !contains(url) && inflight[url] == nil {
            scheduleDecode(url: url)
        }
    }

    /// Drop a single URL from the cache and cancel any pending decode for
    /// it. Called by `state.trashImage(at:)` so trashed photos free their
    /// memory immediately and don't get re-prefetched.
    func evict(url: URL) {
        inflight[url]?.cancel()
        inflight.removeValue(forKey: url)
        entries.removeAll { $0.url == url }
    }

    /// Wipe everything. Called when the active folder changes — the new
    /// folder's URLs share no overlap with the old one, so the entire
    /// cache is stale.
    func clear() {
        for (_, task) in inflight { task.cancel() }
        inflight.removeAll()
        entries.removeAll()
    }

    // MARK: - Internals

    private func contains(_ url: URL) -> Bool {
        entries.contains { $0.url == url }
    }

    private func scheduleDecode(url: URL) {
        let task = Task.detached(priority: .userInitiated) { [weak self] in
            // Use CGImageSource directly. NSImage(contentsOf:) goes through
            // AppKit which can pick a smaller representation and loses the
            // source's color space — we want the full-res CGImage with its
            // native gamut intact, same as EnhancementState's fast preview.
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateImageAtIndex(src, 0, nil)
            else {
                _ = await MainActor.run { [weak self] in
                    self?.inflight.removeValue(forKey: url)
                }
                return
            }
            // Cancellation gate: if the user navigated past this URL while
            // we were decoding, drop the result instead of committing it.
            if Task.isCancelled {
                _ = await MainActor.run { [weak self] in
                    self?.inflight.removeValue(forKey: url)
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.inflight.removeValue(forKey: url)
                // Re-check the window: another updateWindow may have
                // removed this URL while we were decoding.
                self.commit(url: url, image: cg)
            }
        }
        inflight[url] = task
    }

    /// Insert a freshly-decoded image, enforcing the capacity. If the URL
    /// is no longer something we'd want to keep (the window moved past it
    /// during decode), we still insert and let LRU evict it naturally —
    /// it's already in memory, might as well be reachable for one frame
    /// in case the user oscillates.
    private func commit(url: URL, image: CGImage) {
        // De-dupe: if a parallel path beat us to it, nothing to do.
        if entries.contains(where: { $0.url == url }) { return }
        entries.append((url: url, image: image))
        // LRU eviction
        while entries.count > capacity {
            entries.removeFirst()
        }
    }
}
