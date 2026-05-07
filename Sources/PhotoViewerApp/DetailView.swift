import SwiftUI
import AppKit
import ImageIO
import PipelineCore

struct DetailView: View {
    let state: AppState
    /// EnhancementState now lives at the BrowserView level (so the keypress
    /// handler can drive `blinking`). Passed in as @Bindable.
    @Bindable var enhanceState: EnhancementState
    /// Annotation editor — shared with BrowserView so vim keypresses can be
    /// suppressed while drawing.
    @Bindable var annotationState: AnnotationState
    /// Shared zoom/pan across single-pane and side-by-side modes. Reset on
    /// selection change so each new photo opens at fit-to-window.
    @State private var zoom: CGFloat = 1.0
    @State private var pan: CGSize = .zero
    @GestureState private var transientPan: CGSize = .zero
    @GestureState private var transientZoom: CGFloat = 1.0
    /// Pane size at last layout — used by the annotation export pipeline to
    /// rescale annotations from pane-space to image-pixel-space.
    @State private var paneSize: CGSize = .zero
    /// Toast for annotation Save / Copy success messages.
    @State private var toastMessage: String? = nil

    var currentURL: URL? {
        guard let i = state.selectedIndex, i < state.imageURLs.count else { return nil }
        return state.imageURLs[i]
    }

    var body: some View {
        HSplitView {
            imagePane
                .frame(minWidth: 320)
            EnhancementPanel(state: enhanceState)
        }
        .task(id: currentURL) {
            await loadCurrent()
            // Reset zoom/pan whenever the underlying photo changes so the
            // user doesn't open a fresh photo at the previous photo's pan.
            zoom = 1.0
            pan = .zero
            // Bind annotation state to the new URL — annotations don't
            // travel between photos.
            annotationState.bind(to: currentURL)
        }
    }

    /// Image area: single pane (enhanced or original), or side-by-side
    /// depending on `enhanceState.displayMode`. Zoom/pan applies uniformly
    /// across whichever panes are visible.
    private var imagePane: some View {
        ZStack {
            Color.black
            content
            // The annotation overlay sits ABOVE the image and below the
            // chrome. It's always present (so existing annotations stay
            // visible) but only intercepts input when annotation mode is on.
            AnnotationOverlay(state: annotationState, isInteractive: annotationState.isActive)
                .padding(8) // mirror the image pane's padding so coords align
        }
        .background(
            // Track the pane size for the export pipeline. GeometryReader
            // would be cleaner but PreferenceKey + onChange is simpler here.
            GeometryReader { geo in
                Color.clear.onAppear { paneSize = geo.size }
                    .onChange(of: geo.size) { _, new in paneSize = new }
            }
        )
        .overlay(alignment: .topLeading) { infoBar }
        .overlay(alignment: .bottomTrailing) { positionBadge }
        .overlay(alignment: .topTrailing) { showingOriginalBadge }
        .overlay(alignment: .top) { annotateModeButton }
        .overlay(alignment: .bottom) { bottomChrome }
        .gesture(panGesture, including: annotationState.isActive ? .none : .all)
        .gesture(magnifyGesture, including: annotationState.isActive ? .none : .all)
        .onTapGesture(count: 2) {
            guard !annotationState.isActive else { return }
            withAnimation(.spring(duration: 0.25)) {
                zoom = 1.0
                pan = .zero
            }
        }
    }

    /// Pill in the top-center: shows whether annotation mode is on, click
    /// to toggle. Hidden in side-by-side compare to keep that mode focused.
    private var annotateModeButton: some View {
        Group {
            if enhanceState.displayMode != .sideBySide {
                Button {
                    annotationState.isActive.toggle()
                } label: {
                    Label(
                        annotationState.isActive ? "Annotating" : "Annotate",
                        systemImage: annotationState.isActive ? "pencil.tip.crop.circle.fill" : "pencil.tip.crop.circle"
                    )
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(annotationState.isActive ? Color.accentColor : .clear,
                                in: Capsule())
                    .foregroundStyle(annotationState.isActive ? .white : .primary)
                    .overlay(Capsule().strokeBorder(.tertiary, lineWidth: 0.5))
                    .background(.thinMaterial, in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(12)
                .keyboardShortcut("a", modifiers: [.command])
            }
        }
    }

    /// Annotation toolbar (when annotating) or zoom hint (when not). Stack
    /// the toast at the very bottom so success messages don't fight with
    /// the toolbar for screen real estate.
    @ViewBuilder
    private var bottomChrome: some View {
        VStack(spacing: 6) {
            if let toastMessage {
                Text(toastMessage)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            if annotationState.isActive {
                AnnotationToolbar(
                    state: annotationState,
                    onCopy: copyAnnotated,
                    onSave: saveAnnotated
                )
            } else {
                zoomHint
            }
        }
        .padding(.bottom, 12)
    }

    private func saveAnnotated() {
        guard let url = currentURL else { return }
        do {
            let outURL = try AnnotationExport.saveAnnotated(
                sourceURL: url,
                annotations: annotationState.annotations,
                paneSize: paneSize
            )
            showToast("Saved \(outURL.lastPathComponent)")
        } catch {
            showToast("Save failed: \(error.localizedDescription)")
        }
    }

    private func copyAnnotated() {
        guard let url = currentURL else { return }
        do {
            try AnnotationExport.copyAnnotatedToClipboard(
                sourceURL: url,
                annotations: annotationState.annotations,
                paneSize: paneSize
            )
            showToast("Copied to clipboard")
        } catch {
            showToast("Copy failed: \(error.localizedDescription)")
        }
    }

    private func showToast(_ message: String) {
        withAnimation(.easeInOut(duration: 0.2)) { toastMessage = message }
        Task {
            try? await Task.sleep(for: .seconds(2.5))
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) { toastMessage = nil }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch enhanceState.displayMode {
        case .sideBySide:
            HStack(spacing: 1) {
                paneView(image: enhanceState.originalDisplayImage, label: "ORIGINAL")
                Rectangle().fill(Color.gray.opacity(0.4)).frame(width: 1)
                paneView(image: enhanceState.enhancedDisplayImage, label: "ENHANCED")
            }
        default:
            paneView(image: imageForDisplay, label: nil)
        }
    }

    private var imageForDisplay: NSImage? {
        switch enhanceState.displayMode {
        case .original:    return enhanceState.originalDisplayImage
        case .enhanced:    return enhanceState.enhancedDisplayImage
        case .sideBySide:  return nil // handled in `content`
        }
    }

    /// One image pane with the current zoom/pan transform applied. The label
    /// (when supplied) is a small monogram in the top-left of the pane —
    /// shown in side-by-side mode so the user knows which side is which.
    /// Uses pre-rendered NSImages from EnhancementState to avoid redoing the
    /// float16 → CGImage bridge on every body call.
    private func paneView(image: NSImage?, label: String?) -> some View {
        ZStack {
            if let nsImage = image {
                // Note: deliberately NO transition / animation on the image
                // swap. Cross-fading the old NSImage out while the new one
                // fades in produced "phantom shadow" double-exposures during
                // arrow-key nav. Instant swap is faster, sharper, more like
                // Preview.app's behavior.
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
                    .scaleEffect(zoom * transientZoom)
                    .offset(x: pan.width + transientPan.width,
                            y: pan.height + transientPan.height)
                    .id(nsImage)  // force view identity reset on swap so
                                  // SwiftUI doesn't try to morph the old
                                  // Image into the new one's frame
            } else if currentURL == nil {
                Text("Select a photo")
                    .foregroundStyle(.secondary)
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
        await enhanceState.loadInput(url: url)
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
