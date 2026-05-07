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
    /// Hoisted from DetailView so the keypress handler here can drive blink
    /// state (B key down/up) and so the cache survives across mode switches.
    @State private var enhanceState = EnhancementState()
    @State private var annotationState = AnnotationState()

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 240, idealWidth: 320)
            DetailView(state: state, enhanceState: enhanceState, annotationState: annotationState)
                .frame(minWidth: 480)
        }
        .focusable()
        .focusEffectDisabled()
        // B is special: hold-to-blink the original. Need both `.down` and
        // `.up` phases so we can release the override when the key lifts.
        .onKeyPress(phases: [.down, .up]) { press in handleBlinkKey(press) }
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
            ToolbarItem(placement: .primaryAction) {
                photoCounter
            }
        }
        // Folder switch hooks.
        .onChange(of: state.folder) { _, newFolder in
            if let folder = newFolder {
                if let loaded = try? VimKeymap.load(folder: folder) {
                    vimKeymap = loaded
                }
            }
            // Forget GPS cache for the previous folder. We'll lazy-rebuild
            // when the user actually opens the map view.
            locationCache.reset()
        }
        // GPS extraction is the single biggest cost in the load path
        // (header reads on every photo) — only kick it off when the user
        // actually wants the map view, not on every folder open.
        .onChange(of: mode) { _, newMode in
            if newMode == .map { Task { await locationCache.locate(state.imageURLs) } }
        }
        // If the user opens a folder while ALREADY in map mode, fire the
        // first GPS pass once the scan settles. Watch isLoading rather than
        // imageURLs so we don't re-fire per batch.
        .onChange(of: state.isLoading) { _, nowLoading in
            if !nowLoading, mode == .map {
                Task { await locationCache.locate(state.imageURLs) }
            }
        }
    }

    @ViewBuilder
    private var sidebar: some View {
        ZStack {
            // Don't render the actual grid / map while scanning. SwiftUI
            // would otherwise diff a ForEach over a 1000-item array on
            // every batch update from the streaming scan, which spikes the
            // main thread (rainbow spinner). Show only the loading scene
            // until the scan settles.
            if !state.isLoading {
                switch mode {
                case .grid: thumbnailGrid
                case .map:  mapView
                }
            } else {
                loadingOverlay
            }
        }
    }

    /// Translucent loader shown during folder scan / archive extraction.
    /// Delegates rendering to LoadingScene which has the icon, gradient bar,
    /// and live count.
    @ViewBuilder
    private var loadingOverlay: some View {
        if let phase = state.loadPhase {
            LoadingScene(phase: phase, lastError: state.lastError)
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.2), value: state.isLoading)
        }
    }

    /// Toolbar counter: "i / N" when a photo is selected, "N photos" if
    /// nothing is selected, or "Scanning…" while loading. Compact monospace
    /// so it doesn't bounce around as numbers grow.
    private var photoCounter: some View {
        Group {
            if state.isLoading {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(state.imageURLs.isEmpty ? "Scanning…" : "\(state.imageURLs.count) so far…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else if !state.imageURLs.isEmpty {
                let total = state.imageURLs.count
                if let i = state.selectedIndex {
                    Text("\(i + 1) / \(total)")
                        .font(.system(.callout, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                } else {
                    Text("\(total) photo\(total == 1 ? "" : "s")")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
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
                    // Iterate over indices instead of Array(enumerated()) —
                    // the latter allocates a fresh [(Int, URL)] every render,
                    // which on a 2000+-item folder shows up in profiles.
                    // Indices avoid the alloc and are also cheaper for
                    // SwiftUI's id resolution.
                    ForEach(state.imageURLs.indices, id: \.self) { idx in
                        let url = state.imageURLs[idx]
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

    // MARK: - Blink (hold B to peek at the original)

    /// Hold B to override the compare mode to `.original`. On release, restore
    /// whatever was selected. Returns `.handled` only when the key is B; lets
    /// other keys propagate to `handleKey` (the vim dispatcher).
    @MainActor
    private func handleBlinkKey(_ press: KeyPress) -> KeyPress.Result {
        if annotationState.isActive { return .ignored }
        guard press.key.character == "b" || press.key.character == "B" else {
            return .ignored
        }
        switch press.phase {
        case .down:    enhanceState.blinking = true
        case .up:      enhanceState.blinking = false
        default: break
        }
        return .handled
    }

    // MARK: - Vim keymap bridge

    /// Translate one SwiftUI keystroke into a `VimAction` and dispatch.
    /// Most actions update internal `VimKeymap` state (color labels, picks,
    /// marks, rejects) — caller only needs to react to nav actions
    /// (`.next/.prev/.first/.last/.jumpToMark`).
    @MainActor
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        // Suppress vim while annotation overlay is active — typing letters
        // would otherwise both nav photos AND drop chord state, which is
        // confusing when the user thinks they're focused on drawing.
        if annotationState.isActive {
            return .ignored
        }

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
