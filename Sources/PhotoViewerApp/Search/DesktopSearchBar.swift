import SwiftUI

/// Compact, folder-scoped semantic-search surface. It never starts indexing
/// on appear: the only indexing entry point is the explicit button below.
struct DesktopSearchBar: View {
    @Bindable var state: DesktopSearchState
    let currentURL: URL?
    let visibleURLs: [URL]
    let currentVisibleURLs: @MainActor () -> [URL]
    let focusRequest: Int
    let onFocusChange: (Bool) -> Void
    let onClose: () -> Void

    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Describe a photo…", text: $state.query)
                    .textFieldStyle(.plain)
                    .focused($queryFocused)
                    .onSubmit {
                        state.scheduleTextSearch(visibleURLs: visibleURLs, debounce: false)
                    }
                    .accessibilityLabel("Search photos by description")

                if !state.query.isEmpty {
                    Button {
                        state.clearResults()
                        queryFocused = true
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Clear search")
                    .accessibilityLabel("Clear search")
                }
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close search")
                .accessibilityLabel("Close search")
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 7)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 7))

            if state.isIndexing {
                indexingProgress
            } else {
                HStack(spacing: 8) {
                    indexAction
                    if let currentURL, canFindSimilar(currentURL) {
                        Button {
                            state.findSimilar(to: currentURL, visibleURLs: visibleURLs)
                        } label: {
                            Label("Find Similar", systemImage: "photo.on.rectangle.angled")
                        }
                        .buttonStyle(.borderless)
                        .disabled(!state.hasSavedIndex || !state.modelAvailability.canIndexOrFindSimilar)
                        .help("Find visually similar photos in the local index")
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption)
            }

            statusLine

            if let help = state.modelHelpText {
                modelHelp(help)
            }
        }
        .padding(8)
        .background(.background.secondary)
        .onAppear { queryFocused = true }
        .onChange(of: focusRequest) { queryFocused = true }
        .onChange(of: queryFocused) { _, focused in onFocusChange(focused) }
        .onDisappear { onFocusChange(false) }
        .onChange(of: state.query) {
            state.scheduleTextSearch(visibleURLs: visibleURLs)
        }
    }

    @ViewBuilder
    private var indexAction: some View {
        switch state.indexState {
        case .checking:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Checking index…")
                    .foregroundStyle(.secondary)
            }
        case .missing, .failed:
            Button {
                state.startIndexing(visibleURLs: currentVisibleURLs)
            } label: {
                Label("Index This Folder", systemImage: "sparkle.magnifyingglass")
            }
            .disabled(!state.modelAvailability.canIndexOrFindSimilar)
        case .stale:
            Button {
                state.startIndexing(visibleURLs: currentVisibleURLs)
            } label: {
                Label("Refresh Index", systemImage: "arrow.clockwise")
            }
            .disabled(!state.modelAvailability.canIndexOrFindSimilar)
        case .current:
            Button {
                state.startIndexing(visibleURLs: currentVisibleURLs)
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .disabled(!state.modelAvailability.canIndexOrFindSimilar)
        case .noFolder, .readOnlySource:
            EmptyView()
        }
    }

    private var indexingProgress: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
                ProgressView(value: state.progressFraction)
                    .frame(maxWidth: .infinity)
                Text(state.indexedTotal > 0
                     ? "\(state.indexedCurrent) / \(state.indexedTotal)"
                     : "Preparing…")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                Button(state.isStoppingIndex ? "Stopping…" : "Stop", role: .destructive) {
                    state.cancelIndexing()
                }
                .buttonStyle(.borderless)
                .disabled(state.isStoppingIndex)
            }
            if !state.indexingFilename.isEmpty {
                Text(state.indexingFilename)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        if state.isSearching {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Searching locally…")
            }
            .foregroundStyle(.secondary)
            .font(.caption)
        } else if let message = state.message {
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if let results = state.resultFilter {
            HStack(spacing: 5) {
                Text(resultDescription)
                Spacer(minLength: 0)
                Text("\(results.count) match\(results.count == 1 ? "" : "es")")
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            switch state.indexState {
            case .missing:
                Text("Not indexed. Indexing starts only when you choose Index This Folder.")
            case .current(let count, let skipped):
                if skipped > 0 {
                    Text("\(count) indexed locally; \(skipped) unreadable file\(skipped == 1 ? "" : "s") skipped.")
                } else {
                    Text("\(count) photo\(count == 1 ? "" : "s") indexed locally.")
                }
            case .stale:
                Text("This folder changed. Refresh to update search results.")
            case .failed(let error):
                Text(error)
            case .readOnlySource:
                Text("Archive previews aren’t indexed.")
            default:
                EmptyView()
            }
        }
    }

    private var resultDescription: String {
        switch state.resultContext {
        case .none: "Search results"
        case .text(let text): "“\(text)”"
        case .similar(let filename): "Similar to \(filename)"
        }
    }

    private func modelHelp(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(text, systemImage: "externaldrive.badge.questionmark")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Link(
                    "Setup guide…",
                    destination: URL(string: "https://github.com/diamondplated/latent#quick-start")!
                )
                // Re-checking reads local files and clears Core ML's negative
                // cache. The link above is the only network-capable action and
                // it opens solely when the user clicks it.
                Button("Recheck Models") {
                    Task { await state.recheckModels() }
                }
                .buttonStyle(.link)
            }
            .font(.caption2)
        }
        .padding(7)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func canFindSimilar(_ url: URL) -> Bool {
        switch MediaTyping.detect(url) {
        case .staticImage, .animatedImage: true
        case .video, .unsupported: false
        }
    }
}
