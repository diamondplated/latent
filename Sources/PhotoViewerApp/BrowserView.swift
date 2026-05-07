import SwiftUI
import AppKit

struct BrowserView: View {
    @Bindable var state: AppState
    @State private var thumbnailSize: CGFloat = 160

    var body: some View {
        HSplitView {
            thumbnailGrid
                .frame(minWidth: 240, idealWidth: 320)
            DetailView(state: state)
                .frame(minWidth: 480)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.rightArrow) { state.selectNext(); return .handled }
        .onKeyPress(.leftArrow)  { state.selectPrevious(); return .handled }
        .onKeyPress(.downArrow)  { state.selectNext(); return .handled }
        .onKeyPress(.upArrow)    { state.selectPrevious(); return .handled }
    }

    private var thumbnailGrid: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: thumbnailSize), spacing: 8)],
                    spacing: 8
                ) {
                    ForEach(Array(state.imageURLs.enumerated()), id: \.element) { idx, url in
                        ThumbnailCell(
                            url: url,
                            isSelected: state.selectedIndex == idx,
                            size: thumbnailSize
                        )
                        .id(idx)
                        .onTapGesture {
                            state.selectedIndex = idx
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: state.selectedIndex) { _, newValue in
                if let i = newValue {
                    withAnimation { proxy.scrollTo(i, anchor: .center) }
                }
            }
        }
    }
}

struct ThumbnailCell: View {
    let url: URL
    let isSelected: Bool
    let size: CGFloat
    @State private var image: NSImage? = nil

    var body: some View {
        ZStack {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay(ProgressView().controlSize(.small))
            }
        }
        .frame(width: size, height: size)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 3)
        }
        .task {
            image = await ThumbnailLoader.shared.thumbnail(for: url)
        }
    }
}
