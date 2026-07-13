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
    @State private var showShortcutOverlay = false
    @FocusState private var viewerFocused: Bool
    /// Hoisted from DetailView so the keypress handler here can drive blink
    /// state (B key down/up) and so the cache survives across mode switches.
    @State private var enhanceState = EnhancementState()

    var body: some View {
        HSplitView {
            // Far-left pane: folder tree (collapsible). Default off — toggled
            // from the toolbar — so the layout stays simple unless the user
            // wants to drill around a parent dir.
            if state.showFolderTree {
                FolderTreeView(state: state)
                    .frame(minWidth: 180, idealWidth: 220, maxWidth: 320)
            }
            sidebar
                .frame(minWidth: 240, idealWidth: 320)
            DetailView(state: state, enhanceState: enhanceState)
                .frame(minWidth: 480)
        }
        .focusable()
        .focused($viewerFocused)
        .focusEffectDisabled()
        .overlay {
            if showShortcutOverlay {
                KeyboardShortcutOverlay(isPresented: $showShortcutOverlay)
            }
        }
        // B is special: hold-to-blink the original. Need both `.down` and
        // `.up` phases so we can release the override when the key lifts.
        .onKeyPress(phases: [.down, .up]) { press in handleBlinkKey(press) }
        .onKeyPress(phases: .down) { press in handleKey(press) }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    state.showFolderTree.toggle()
                } label: {
                    Image(systemName: state.showFolderTree
                          ? "sidebar.left"
                          : "list.bullet.indent")
                }
                .help(state.showFolderTree ? "Hide folder tree" : "Show folder tree")
                .keyboardShortcut("l", modifiers: .command)
            }
            // Cmd-Up jumps to the parent dir, Finder-style. Re-roots the
            // folder tree on the parent so you can drill back down a
            // sibling. Disabled at filesystem root.
            ToolbarItem(placement: .navigation) {
                Button {
                    state.goUp()
                } label: {
                    Image(systemName: "arrow.up")
                }
                .help("Go to parent folder (\u{2318}\u{2191})")
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(!state.canGoUp || state.isLoading)
            }
            // Opt-in recursive scan. The default load is non-recursive
            // (just the folder's direct contents) — a parent of ~/Pictures
            // used to spawn a 100k-photo scan the user didn't ask for.
            // Hit this to pull in everything under the current folder.
            ToolbarItem(placement: .navigation) {
                Button {
                    if let folder = state.folder {
                        Task {
                            await state.loadFolder(folder, setAsAnchor: false, recursive: true)
                        }
                    }
                } label: {
                    Image(systemName: "square.3.layers.3d.down.right")
                }
                .help("Include subfolders (recursive scan)")
                .disabled(state.folder == nil || state.isLoading)
            }
            ToolbarItem(placement: .principal) {
                Picker("View", selection: $mode) {
                    ForEach(BrowseMode.allCases) { m in
                        Label(m.label, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
            }
            ToolbarItem(placement: .primaryAction) {
                photoSortMenu
            }
            ToolbarItem(placement: .primaryAction) {
                photoCounter
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    state.showEnhancementPanel.toggle()
                } label: {
                    Image(systemName: state.showEnhancementPanel
                          ? "sidebar.right"
                          : "wand.and.stars")
                }
                .help(state.showEnhancementPanel ? "Hide enhancement panel" : "Show enhancement panel")
                .keyboardShortcut("e", modifiers: .command)
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
        .onChange(of: state.selectedIndex) { viewerFocused = true }
        .onAppear { viewerFocused = true }
        .onDisappear { enhanceState.reset() }
    }

    @ViewBuilder
    private var sidebar: some View {
        ZStack {
            // Don't render the actual grid / map while scanning. SwiftUI
            // would otherwise diff a ForEach over a 1000-item array on
            // every batch update from the streaming scan, which spikes the
            // main thread (rainbow spinner). Show only the loading scene
            // until the scan settles.
            if state.isLoading {
                loadingOverlay
            } else if state.imageURLs.isEmpty && state.folder != nil {
                emptyFolderHint
            } else {
                switch mode {
                case .grid: thumbnailGrid
                case .map:  mapView
                }
            }
        }
    }

    /// Shown when the active folder has zero photos at the top level. The
    /// new default is non-recursive, so opening a folder of folders lands
    /// here — give the user an obvious next step (recurse) instead of a
    /// silent empty grid that looks broken.
    private var emptyFolderHint: some View {
        VStack(spacing: 14) {
            Image(systemName: "tray")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("No photos in this folder")
                .font(.title3.weight(.semibold))
            Text("This folder's direct contents are empty. Subfolders below it may contain photos.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Button {
                if let folder = state.folder {
                    Task {
                        await state.loadFolder(folder, setAsAnchor: false, recursive: true)
                    }
                }
            } label: {
                Label("Include Subfolders", systemImage: "square.3.layers.3d.down.right")
            }
            .controlSize(.large)
            .keyboardShortcut("r", modifiers: .command)
            .padding(.top, 4)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Translucent loader shown during folder scan / archive extraction.
    /// Delegates rendering to LoadingScene which has the icon, gradient bar,
    /// and live count. Wires the Stop button to `cancelScan()` so the user
    /// can bail out of a long recursive walk (e.g., they hit Include
    /// Subfolders on ~/Pictures and realized that's 100k photos).
    @ViewBuilder
    private var loadingOverlay: some View {
        if let phase = state.loadPhase {
            LoadingScene(
                phase: phase,
                lastError: state.lastError,
                onStop: { state.cancelScan() }
            )
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.2), value: state.isLoading)
        }
    }

    /// Toolbar sort menu: name vs recently modified. Same enum as the
    /// folder-tree sort (the user already understands the choice from the
    /// sidebar; carrying it over avoids a second mental model). Disabled
    /// while loading so a sort flip mid-scan can't race the load.
    private var photoSortMenu: some View {
        Menu {
            Picker("Sort", selection: $state.photoSort) {
                ForEach(FolderSort.allCases) { sort in
                    Label(sort.label, systemImage: sort.symbol).tag(sort)
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .menuIndicator(.hidden)
        .help("Sort photos")
        .disabled(state.imageURLs.isEmpty || state.isLoading)
    }

    /// Toolbar counter. Three modes: scan progress, multi-select badge,
    /// or "i / N" position. Multi-select wins when active so the user
    /// always knows how many they've gathered.
    private var photoCounter: some View {
        Group {
            if state.isLoading {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text(state.imageURLs.isEmpty ? "Scanning…" : "\(state.imageURLs.count) so far…")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            } else if !state.multiSelection.isEmpty {
                // Bulk-mode pill: pops with accent color so the user
                // can't miss that they're in a non-default state and
                // remembers Backspace will trash all of them.
                let n = state.multiSelection.count
                Text("\(n) selected")
                    .font(.system(.callout, design: .monospaced).weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.accentColor))
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
                    // Key cells by URL, not index. Sort/delete reshuffles
                    // positions; URL identity prevents SwiftUI from reusing
                    // a decoded thumbnail for the wrong file.
                    ForEach(state.imageURLs, id: \.self) { url in
                        ThumbnailCell(
                            url: url,
                            isSelected: state.currentURL == url,
                            isMultiSelected: state.multiSelection.contains(url),
                            colorLabel: vimKeymap.colorLabel(for: url),
                            isPicked: vimKeymap.isPicked(url),
                            isRejected: vimKeymap.isRejected(url),
                            size: thumbnailSize,
                            onTrash: { state.trashImage(at: url) }
                        )
                        .id(url)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(url.lastPathComponent)
                        .accessibilityAction(.default) {
                            state.multiSelection.removeAll()
                            state.select(url: url)
                        }
                        // ⌘-click → toggle this URL in the multi-selection
                        .gesture(
                            TapGesture()
                                .modifiers(.command)
                                .onEnded { _ in toggleMultiSelect(url: url) }
                        )
                        // Shift-click → range select from selectedIndex
                        // anchor through this URL's current index (inclusive)
                        .gesture(
                            TapGesture()
                                .modifiers(.shift)
                                .onEnded { _ in extendMultiSelect(to: url) }
                        )
                        // Plain click → clear multi, set primary
                        .onTapGesture {
                            state.multiSelection.removeAll()
                            state.select(url: url)
                        }
                    }
                }
                .padding(8)
            }
            .onChange(of: state.selectedIndex) { _, newValue in
                if let i = newValue, i < state.imageURLs.count {
                    withAnimation { proxy.scrollTo(state.imageURLs[i], anchor: .center) }
                }
            }
        }
    }

    // MARK: - Multi-selection

    /// Toggle a single thumbnail in the multi-selection (⌘-click handler).
    /// Also makes this URL the primary so subsequent shift-clicks anchor
    /// from here.
    private func toggleMultiSelect(url: URL) {
        guard state.imageURLs.contains(url) else { return }
        if state.multiSelection.contains(url) {
            state.multiSelection.remove(url)
        } else {
            state.multiSelection.insert(url)
        }
        state.select(url: url)
    }

    /// Range-select from the current primary (selectedIndex) through the
    /// clicked URL. Replaces the current multi-selection (Mac shift-click
    /// is "select range from anchor"; ⌘-shift-click would be "add range",
    /// but the simpler semantics are good enough for v1).
    private func extendMultiSelect(to url: URL) {
        guard let idx = state.imageURLs.firstIndex(of: url) else { return }
        let anchor = state.selectedIndex ?? idx
        let lo = min(anchor, idx)
        let hi = max(anchor, idx)
        state.multiSelection = Set(state.imageURLs[lo...hi])
        state.selectedIndex = idx
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
        guard !showShortcutOverlay else { return .ignored }
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
        if showShortcutOverlay {
            showShortcutOverlay = false
            return .handled
        }
        if press.key.character == "?" {
            showShortcutOverlay = true
            return .handled
        }

        // When the enhancement panel is open, arrows belong to its sliders
        // and pickers. Vim j/k still navigate photos.
        switch press.key {
        case .leftArrow, .upArrow:
            guard !state.showEnhancementPanel else { return .ignored }
            state.selectPrevious()
            return .handled
        case .rightArrow, .downArrow:
            guard !state.showEnhancementPanel else { return .ignored }
            state.selectNext()
            return .handled
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
    /// In the multi-selection set. Distinct from `isSelected` (which is
    /// the *primary* focus that DetailView shows). A thumbnail can be
    /// both at once — it's the most-recently-clicked AND part of a bulk.
    let isMultiSelected: Bool
    let colorLabel: Int
    let isPicked: Bool
    let isRejected: Bool
    let size: CGFloat
    /// One-click trash. Called from the hover-revealed X and the right-
    /// click context menu — kept as a closure so the cell doesn't need
    /// AppState injected through every preview path.
    let onTrash: () -> Void

    @State private var image: CGImage? = nil
    @State private var hovered: Bool = false
    @State private var didFail = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1.0, orientation: .up)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        if didFail {
                            Image(systemName: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
            }
            // Multi-selected tint overlay. Sits ABOVE the image so it
            // visually unifies a bulk selection at a glance (helpful when
            // the user has 30 picked across a 5000-photo grid).
            if isMultiSelected {
                Color.accentColor.opacity(0.22)
            }
        }
        .frame(width: size, height: size)
        .background(.background.tertiary)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay {
            // Border thickness encodes selection state: 3pt for primary,
            // 2pt for "in multi-selection but not primary", clear
            // otherwise. Picks the eye toward the primary first.
            let lineWidth: CGFloat = isSelected ? 3 : (isMultiSelected ? 2 : 0)
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(
                    (isSelected || isMultiSelected) ? Color.accentColor : .clear,
                    lineWidth: lineWidth
                )
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
        // Hover-revealed trash button. One click moves to Trash (not
        // permanent) so a misclick is recoverable from Finder. Kept in
        // the bottomTrailing corner — topLeading/topTrailing are taken
        // by the color label and pick/reject markers.
        .overlay(alignment: .bottomTrailing) {
            if hovered {
                Button {
                    onTrash()
                } label: {
                    Image(systemName: "trash.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.red.opacity(0.9), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.7), lineWidth: 0.5))
                }
                .buttonStyle(.plain)
                .padding(6)
                .help("Move to Trash")
                .transition(.opacity)
            }
        }
        .opacity(isRejected ? 0.5 : 1.0)
        .onHover { hovered = $0 }
        // Drag-out: dragging a thumbnail to Finder, Mail, Messages,
        // Photoshop, etc. delivers the underlying file URL — the same
        // payload Finder gives them. Single-thumbnail drag (multi-drag
        // is doable via Transferable but punted to v2; bulk-trash via
        // multi-select covers most batch flows).
        .draggable(url) {
            // Drag preview: a small version of the thumbnail itself if
            // we've decoded it, otherwise a generic file icon.
            Group {
                if let image {
                    Image(decorative: image, scale: 1.0, orientation: .up)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 96, height: 96)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 32))
                        .foregroundStyle(.secondary)
                        .frame(width: 96, height: 96)
                }
            }
        }
        .contextMenu {
            // ShareLink wraps NSSharingServicePicker — gets us AirDrop,
            // Mail, Messages, Notes, plus any apps that registered a
            // share extension (Photoshop, etc.) for free.
            ShareLink(item: url) {
                Label("Share…", systemImage: "square.and.arrow.up")
            }
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            } label: {
                Label("Reveal in Finder", systemImage: "magnifyingglass")
            }
            Divider()
            Button(role: .destructive) {
                onTrash()
            } label: {
                Label("Move to Trash", systemImage: "trash")
            }
        }
        .task(id: url) {
            image = nil
            hovered = false
            didFail = false
            let thumbnail = await ThumbnailLoader.shared.thumbnail(for: url)
            guard !Task.isCancelled else { return }
            image = thumbnail
            didFail = thumbnail == nil
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
