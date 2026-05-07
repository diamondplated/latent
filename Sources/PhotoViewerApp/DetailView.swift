import SwiftUI
import AppKit
import ImageIO
import PipelineCore

struct DetailView: View {
    let state: AppState
    /// Owns the enhancement editor state (per-stage params, buffers, cache).
    /// Kept at DetailView level so the panel and the image preview share one
    /// instance and the cache survives across selection changes.
    @State private var enhanceState = EnhancementState()

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
        }
    }

    /// The left side: just the image (or placeholder/spinner). Picks between
    /// the original and the pipeline output based on the panel's toggle.
    private var imagePane: some View {
        ZStack {
            Color.black
            if let nsImage = displayImage {
                Image(nsImage: nsImage)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .padding(8)
            } else if currentURL == nil {
                Text("Select a photo")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .overlay(alignment: .topLeading) { infoBar }
        .overlay(alignment: .bottomTrailing) { positionBadge }
        .overlay(alignment: .topTrailing) { showingOriginalBadge }
    }

    /// The image to actually display. Order of preference:
    ///   - showingOriginal=true → originalBuffer (or nothing if not loaded)
    ///   - else → enhancedBuffer if available, else originalBuffer (so the
    ///     user sees the source instantly while the first pipeline run is
    ///     still working, instead of a blank frame).
    private var displayImage: NSImage? {
        if enhanceState.showingOriginal {
            return enhanceState.originalBuffer?.makeNSImage()
        }
        if let enhanced = enhanceState.enhancedBuffer {
            return enhanced.makeNSImage()
        }
        return enhanceState.originalBuffer?.makeNSImage()
    }

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

    /// "ORIGINAL" pill in the corner whenever the comparison toggle is on.
    /// Without it, sliding the toggle while focused on the panel would not
    /// have any visible cue at the image level.
    private var showingOriginalBadge: some View {
        Group {
            if enhanceState.showingOriginal && enhanceState.originalBuffer != nil {
                Text("ORIGINAL")
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.yellow.opacity(0.85), in: Capsule())
                    .foregroundStyle(.black)
                    .padding(12)
            }
        }
    }

    /// Use the buffer's dimensions (which already reflect orientation baking
    /// from the reader) so the displayed numbers match what the pipeline
    /// actually saw, not the raw EXIF.
    private var imageDimensions: (width: Int, height: Int)? {
        let buf = enhanceState.showingOriginal
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
