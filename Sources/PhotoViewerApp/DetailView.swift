import SwiftUI
import AppKit
import ImageIO

struct DetailView: View {
    let state: AppState
    @State private var image: NSImage? = nil
    @State private var loadingURL: URL? = nil

    var currentURL: URL? {
        guard let i = state.selectedIndex, i < state.imageURLs.count else { return nil }
        return state.imageURLs[i]
    }

    var body: some View {
        ZStack {
            Color.black
            if let image {
                Image(nsImage: image)
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
        .task(id: currentURL) {
            await loadCurrent()
        }
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

    private var imageDimensions: (width: Int, height: Int)? {
        guard let image else { return nil }
        return (Int(image.size.width), Int(image.size.height))
    }

    @MainActor
    private func loadCurrent() async {
        guard let url = currentURL else {
            image = nil
            return
        }
        if loadingURL == url { return }
        loadingURL = url
        // Quick path: NSImage load. The full color-managed pipeline path goes
        // through ImageReader; for display we just need pixels on screen fast.
        let loaded = await Task.detached(priority: .userInitiated) {
            NSImage(contentsOf: url)
        }.value
        // Only commit if the user hasn't moved on.
        if loadingURL == url {
            image = loaded
        }
    }
}
