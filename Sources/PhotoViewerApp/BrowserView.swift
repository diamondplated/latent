import SwiftUI
import AppKit
import PhotoViewerCore
import PhotoGeo

enum BrowseMode: String, CaseIterable, Identifiable {
    case grid, map
    var id: String { rawValue }
    var label: String { self == .grid ? "Grid" : "Map" }
    var symbol: String { self == .grid ? "square.grid.2x2" : "map" }
}

struct BrowserView: View {
    @Bindable var state: AppState
    @State private var thumbnailSize: CGFloat = 160
    @State private var vimKeymap = VimKeymap()
    @State private var locationCache = PhotoLocationCache()
    @State private var mode: BrowseMode = .grid

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 320)
            DetailView(state: state)
                .frame(minWidth: 480)
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(BrowseMode.allCases) { m in
                        Label(m.label, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        // Folder switch hooks: load saved vim state, kick off GPS extraction.
        .onChange(of: state.folder) { _, newFolder in
            if let folder = newFolder {
                if let loaded = try? VimKeymap.load(folder: folder) {
                    vimKeymap = loaded
                }
            }
        }
        .onChange(of: state.imageURLs) { _, newURLs in
            Task { await locationCache.locate(newURLs) }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        switch mode {
        case .grid:  thumbnailGrid
        case .map:   mapView
        }
    }

    // MARK: - Grid

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
                            colorLabel: vimKeymap.colorLabel(for: url),
                            isPicked: vimKeymap.isPicked(url),
                            isRejected: vimKeymap.isRejected(url),
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

    // MARK: - Map

    private var mapView: some View {
        PhotoMapView(
            locations: locationCache.allLocations,
            onSelectCluster: { urls in
                // Snap selection to the first photo in the cluster and pop
                // back to the grid so the user sees the result laid out.
                if let first = urls.first {
                    state.select(url: first)
                    mode = .grid
                }
            }
        )
    }

    // MARK: - Vim keymap bridge

    /// Translate one SwiftUI keystroke into a `VimAction` and dispatch.
    /// Most actions update internal `VimKeymap` state (color labels, picks,
    /// marks, rejects) — caller only needs to react to nav actions
    /// (`.next/.prev/.first/.last/.jumpToMark`).
    @MainActor
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Arrow keys keep working as before — vim doesn't own them.
        switch press.key {
        case .leftArrow, .upArrow:   state.selectPrevious(); return .handled
        case .rightArrow, .downArrow: state.selectNext(); return .handled
        default: break
        }

        let mods = vimMods(from: press.modifiers)
        let action = vimKeymap.handle(
            keyCharacter: press.key.character,
            modifiers: mods,
            currentURL: state.currentURL,
            currentIndex: state.selectedIndex,
            totalCount: state.imageURLs.count
        )

        switch action {
        case .next:    state.selectNext()
        case .prev:    state.selectPrevious()
        case .first:   state.selectFirst()
        case .last:    state.selectLast()
        case .jumpToMark(let c):
            if let url = vimKeymap.marks[c] { state.select(url: url) }
        case .setMark, .setColorLabel, .togglePick, .toggleReject:
            // VimKeymap already updated its own state; persist asynchronously.
            if let folder = state.folder {
                Task.detached { @MainActor in
                    try? vimKeymap.save(folder: folder)
                }
            }
        case .none:
            return .ignored
        }
        return .handled
    }

    private func vimMods(from m: EventModifiers) -> VimModifiers {
        var out = VimModifiers()
        if m.contains(.shift)   { out.insert(.shift) }
        if m.contains(.control) { out.insert(.control) }
        if m.contains(.option)  { out.insert(.option) }
        if m.contains(.command) { out.insert(.command) }
        return out
    }
}

struct ThumbnailCell: View {
    let url: URL
    let isSelected: Bool
    let colorLabel: Int
    let isPicked: Bool
    let isRejected: Bool
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
        .overlay(alignment: .topLeading) {
            if colorLabel > 0 {
                Circle()
                    .fill(colorForLabel(colorLabel))
                    .frame(width: 12, height: 12)
                    .overlay(Circle().strokeBorder(.white, lineWidth: 1))
                    .padding(4)
            }
        }
        .overlay(alignment: .topTrailing) {
            if isPicked || isRejected {
                Image(systemName: isPicked ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(isPicked ? .green : .red)
                    .padding(4)
            }
        }
        .opacity(isRejected ? 0.5 : 1.0)
        .task {
            image = await ThumbnailLoader.shared.thumbnail(for: url)
        }
    }

    private func colorForLabel(_ label: Int) -> Color {
        // Standard Lightroom-style color labels — red/yellow/green/blue/purple
        // for 1-5, then fall through to gray for 6-9.
        switch label {
        case 1: .red
        case 2: .yellow
        case 3: .green
        case 4: .blue
        case 5: .purple
        default: .gray
        }
    }
}
