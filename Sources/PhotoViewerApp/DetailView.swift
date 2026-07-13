import SwiftUI
import AppKit
import ImageIO
import PipelineCore

struct DetailView: View {
    let state: AppState
    /// EnhancementState now lives at the BrowserView level (so the keypress
    /// handler can drive `blinking`). Passed in as @Bindable.
    @Bindable var enhanceState: EnhancementState
    /// Shared zoom/pan across single-pane and side-by-side modes. Reset on
    /// selection change so each new photo opens at fit-to-window.
    @State private var zoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @GestureState private var transientPan: CGSize = .zero
    @GestureState private var transientZoom: CGFloat = 1.0

    var currentURL: URL? {
        guard let i = state.selectedIndex, i < state.imageURLs.count else { return nil }
        return state.imageURLs[i]
    }

    var body: some View {
        HSplitView {
            imagePane
                .frame(minWidth: 320)
            // Enhancement panel is hidden by default — Latent is primarily
            // a viewer. Toolbar button (in BrowserView) toggles it.
            if state.showEnhancementPanel {
                EnhancementPanel(state: enhanceState)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.18), value: state.showEnhancementPanel)
        .task(id: currentURL) {
            // Update the prefetch window FIRST — this both seeds the cache
            // for next-press neighbors and lets us hand a cache hit
            // straight to loadCurrent. Sync call (no await), instant
            // because window-update is in-memory only.
            updatePrefetchWindow()
            await loadCurrent()
            // Reset zoom/pan whenever the underlying photo changes so the
            // user doesn't open a fresh photo at the previous photo's pan.
            zoom = 1.0
            pan = .zero
        }
    }

    /// Tell the prefetcher to keep the current photo + the ±2 neighbors
    /// in cache, evict everything else, and start decoding any window
    /// entry that isn't already there. Cheap (a few set ops + at most
    /// 2-3 task spawns); runs every selection change.
    private func updatePrefetchWindow() {
        guard let i = state.selectedIndex, i < state.imageURLs.count else {
            state.prefetcher.updateWindow(focus: nil, neighbors: [])
            return
        }
        let urls = state.imageURLs
        let focus = urls[i]
        // ±2 neighbors, clamped to bounds. Skip videos / animated images
        // — those don't go through the CGImage decode path so prefetching
        // them would just burn memory on data we won't render via the
        // cache.
        let radius = 2
        var neighbors: [URL] = []
        for offset in [-1, 1, -2, 2] {  // closest first
            let idx = i + offset
            guard idx >= 0 && idx < urls.count else { continue }
            let url = urls[idx]
            if MediaTyping.detect(url) == .staticImage {
                neighbors.append(url)
            }
            if neighbors.count >= radius * 2 { break }
        }
        // The focus URL may itself be a video/animated; the prefetcher
        // accepts whatever (it'll just decode + cache, no harm), but we
        // only schedule a decode for static images. Pass focus through
        // regardless so a cache HIT for a previously-prefetched static
        // gets promoted in the LRU.
        state.prefetcher.updateWindow(focus: focus, neighbors: neighbors)
    }

    /// Image area: single pane (enhanced or original), or side-by-side
    /// depending on `enhanceState.displayMode`. Zoom/pan applies uniformly
    /// across whichever panes are visible.
    private var imagePane: some View {
        // GeometryReader so the double-click handler knows the pane's size
        // (needed to convert the click point into a zoom-target offset).
        GeometryReader { geo in
            ZStack {
                Color.black
                content
            }
            // Explicit hit-test shape so pan / zoom / double-click gestures
            // register over the WHOLE pane — not only the actual image
            // pixels. Without this, letterboxed photos (any photo whose
            // aspect ratio doesn't match the pane) had dead zones around
            // the image where clicks did nothing.
            .contentShape(Rectangle())
            .overlay(alignment: .topLeading) { infoBar }
            .overlay(alignment: .bottomTrailing) { positionBadge }
            .overlay(alignment: .topTrailing) { showingOriginalBadge }
            .overlay(alignment: .bottom) { zoomHint }
            .gesture(panGesture)
            .gesture(magnifyGesture)
            // Double-tap on a specific point: cycles 1x → 2x → 3x → 4x →
            // back to fit, recentering on the clicked spot each time.
            .onTapGesture(count: 2, coordinateSpace: .local) { location in
                handleDoubleTap(at: location, paneSize: geo.size)
            }
        }
    }

    /// Cycle through 1× → 2× → 3× → 4× → 1× on each double-click, recentering
    /// on the clicked point at every step. So the user can quickly zoom in
    /// further without panning manually — click on the area of interest,
    /// click again to push deeper, click a fourth time to come back out.
    ///
    /// Math: `.scaleEffect(z)` scales the inner view around the pane center,
    /// then `.offset(p)` translates. So a pre-transform view point V ends
    /// up at pane position `C + (V − C)·z + p`. To make the point currently
    /// at pane position L (under the user's cursor) land at the new pane
    /// center after a zoom change to z_new:
    ///     p_new = (C + p_cur − L) · (z_new / z_cur)
    /// Generalizes correctly to ALL incremental zooms (the previous version
    /// assumed z_cur == 1 and was off by a factor on later clicks).
    private func handleDoubleTap(at location: CGPoint, paneSize: CGSize) {
        withAnimation(.spring(duration: 0.28)) {
            let target = nextZoomStep(from: zoom)
            if target <= 1.0 {
                // Cycle back to fit-to-window — pan resets too.
                zoom = 1.0
                pan = .zero
                return
            }
            let center = CGPoint(x: paneSize.width / 2, y: paneSize.height / 2)
            let factor = target / max(zoom, 0.0001)
            let dx = (center.x + pan.width  - location.x) * factor
            let dy = (center.y + pan.height - location.y) * factor
            zoom = target
            pan = CGSize(width: dx, height: dy)
        }
    }

    /// 1× → 2× → 3× → 4× → 1× cycle. Buckets accept a little slack so a
    /// user who pinch-zoomed to e.g. 2.4× then double-clicks still gets
    /// the next step (3×) rather than landing back at 2×.
    private func nextZoomStep(from current: CGFloat) -> CGFloat {
        if current < 1.5 { return 2.0 }
        if current < 2.5 { return 3.0 }
        if current < 3.5 { return 4.0 }
        return 1.0
    }

    @ViewBuilder
    private var content: some View {
        // Route by media type. Static images go through the
        // pipeline-driven CGImage path; animated images use NSImageView
        // for native playback; video uses AVKit. Side-by-side compare is
        // image-only by design (comparing two mid-flight video frames is
        // a different feature) so we still take the image path there.
        switch (enhanceState.displayMode, currentURL.flatMap(MediaTyping.detect)) {
        case (.sideBySide, _):
            HStack(spacing: 1) {
                paneView(image: enhanceState.originalDisplayImage, label: "ORIGINAL")
                Rectangle().fill(Color.gray.opacity(0.4)).frame(width: 1)
                paneView(image: enhanceState.enhancedDisplayImage, label: "ENHANCED")
            }
        case (_, .animatedImage):
            if let url = currentURL {
                AnimatedImageView(url: url)
                    .padding(8)
                    .scaleEffect(zoom * transientZoom)
                    .offset(x: pan.width + transientPan.width,
                            y: pan.height + transientPan.height)
                    .id(url)
            }
        case (_, .video):
            if let url = currentURL {
                VideoPlaybackView(url: url)
                    .padding(8)
                    .id(url)
            }
        case (_, .unsupported):
            VStack(spacing: 6) {
                Image(systemName: "questionmark.square.dashed")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("Unsupported file type")
                    .foregroundStyle(.secondary)
                if let url = currentURL {
                    Text(url.lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        default:
            paneView(image: imageForDisplay, label: nil)
        }
    }

    private var imageForDisplay: CGImage? {
        switch enhanceState.displayMode {
        case .original:    return enhanceState.originalDisplayImage
        case .enhanced:    return enhanceState.enhancedDisplayImage
        case .sideBySide:  return nil // handled in `content`
        }
    }

    /// One image pane with the current zoom/pan transform applied. The label
    /// (when supplied) is a small monogram in the top-left of the pane —
    /// shown in side-by-side mode so the user knows which side is which.
    ///
    /// Uses CGImage directly (not NSImage) so the source's native color space
    /// — Display P3, Adobe RGB, etc. — survives all the way to the SwiftUI
    /// renderer without being squashed to sRGB by an intermediate NSImage.
    private func paneView(image: CGImage?, label: String?) -> some View {
        ZStack {
            if let cg = image {
                // No transition / animation on the swap. Cross-fading the
                // old image out while the new one fades in produced "phantom
                // shadow" double-exposures during rapid arrow nav. Instant
                // swap matches Preview.app's behavior. .id forces view
                // identity reset so SwiftUI doesn't try to morph layouts.
                Image(decorative: cg, scale: 1.0, orientation: .up)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
                    .scaleEffect(zoom * transientZoom)
                    .offset(x: pan.width + transientPan.width,
                            y: pan.height + transientPan.height)
                    .id(ObjectIdentifier(cg))
            } else if currentURL == nil {
                Text("Select a photo")
                    .foregroundStyle(.secondary)
            } else if let error = enhanceState.lastError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 36))
                    Text(error)
                        .multilineTextAlignment(.center)
                }
                .foregroundStyle(.secondary)
                .padding()
            } else {
                PhotoSkeleton()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .overlay(alignment: .topLeading) {
            if let label {
                Text(label)
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(8)
            }
        }
    }

    // MARK: - Gestures

    private var panGesture: some Gesture {
        DragGesture()
            .updating($transientPan) { value, transient, _ in
                transient = value.translation
            }
            .onEnded { value in
                pan.width += value.translation.width
                pan.height += value.translation.height
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .updating($transientZoom) { value, transient, _ in
                transient = value.magnification
            }
            .onEnded { value in
                let next = max(0.25, min(zoom * value.magnification, 16.0))
                zoom = next
            }
    }

    // MARK: - Overlays

    private var infoBar: some View {
        Group {
            if let url = currentURL {
                VStack(alignment: .leading, spacing: 2) {
                    Text(url.lastPathComponent)
                        .font(.system(.callout, design: .monospaced))
                        .lineLimit(1)
                    if let dims = imageDimensions {
                        Text("\(dims.width) × \(dims.height)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(12)
            }
        }
    }

    private var positionBadge: some View {
        Group {
            if let i = state.selectedIndex, !state.imageURLs.isEmpty {
                Text("\(i + 1) / \(state.imageURLs.count)")
                    .font(.system(.caption, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(12)
            }
        }
    }

    /// Yellow "ORIGINAL" pill when the comparison toggle (or transient blink)
    /// is forcing the original view in single-pane mode. Hidden in side-by-side
    /// since the per-pane labels already make it obvious.
    private var showingOriginalBadge: some View {
        Group {
            if enhanceState.displayMode == .original && enhanceState.originalBuffer != nil {
                Text(enhanceState.blinking ? "BLINK" : "ORIGINAL")
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
                    .padding(12)
            }
        }
    }

    /// Tiny zoom-level pill at the bottom edge — only when zoomed away from 1×.
    /// Click-targetless info; just a hint that you're not at fit-to-window.
    private var zoomHint: some View {
        Group {
            let effective = zoom * transientZoom
            if abs(effective - 1.0) > 0.001 {
                Text(String(format: "%.2f×", effective))
                    .font(.system(.caption2, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.thinMaterial, in: Capsule())
                    .padding(12)
            }
        }
    }

    private var imageDimensions: (width: Int, height: Int)? {
        let buf = enhanceState.displayMode == .original
            ? enhanceState.originalBuffer
            : (enhanceState.enhancedBuffer ?? enhanceState.originalBuffer)
        guard let buf else { return nil }
        return (buf.width, buf.height)
    }

    @MainActor
    private func loadCurrent() async {
        guard let url = currentURL else { return }
        // Cache hit on the prefetch ring → hand the decoded CGImage
        // straight to EnhancementState, skipping the disk decode entirely.
        // Miss falls through to the normal preview-decode path.
        let cached = state.prefetcher.image(for: url)
        await enhanceState.loadInput(url: url, prefetched: cached)
    }
}

// MARK: - Bridge so BrowserView can drive blink + view-mode without
//         knowing the internals of EnhancementState.

extension DetailView {
    /// Read-only view into EnhancementState's current display intent. Currently
    /// unused — present so future feature additions (e.g. status bar in
    /// ContentView) can read display state without a fresh wiring pass.
    var compareMode: CompareMode { enhanceState.compareMode }
}
