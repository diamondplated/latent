import SwiftUI
import PhotoViewerCore

/// Active filter for the photo grid. Determines which subset of photos
/// are visible when applied to the full `imageURLs` list.
enum PhotoFilter: Equatable, Hashable, Identifiable {
    case all
    case picked
    case rejected
    case colorLabel(Int)  // 1-5

    var id: String {
        switch self {
        case .all: "all"
        case .picked: "picked"
        case .rejected: "rejected"
        case .colorLabel(let n): "color-\(n)"
        }
    }

    var label: String {
        switch self {
        case .all: "All"
        case .picked: "Picked"
        case .rejected: "Rejected"
        case .colorLabel(let n): "Label \(n)"
        }
    }

    var symbol: String {
        switch self {
        case .all: "photo.on.rectangle"
        case .picked: "checkmark.circle"
        case .rejected: "xmark.circle"
        case .colorLabel: "circle.fill"
        }
    }

    var chipColor: Color {
        switch self {
        case .all: .secondary
        case .picked: .green
        case .rejected: .red
        case .colorLabel(let n):
            switch n {
            case 1: .red
            case 2: .yellow
            case 3: .green
            case 4: .blue
            case 5: .purple
            default: .gray
            }
        }
    }
}

/// Horizontal filter bar with chips for All, Picked, Rejected, and
/// color labels 1-5. Filters the grid through the VimKeymap's label/pick/
/// reject data. Appears above the thumbnail grid when the filter is active.
struct FilterBar: View {
    @Binding var activeFilter: PhotoFilter
    let vimKeymap: VimKeymap
    let imageURLs: [URL]

    private let filters: [PhotoFilter] = [
        .all, .picked, .rejected,
        .colorLabel(1), .colorLabel(2), .colorLabel(3),
        .colorLabel(4), .colorLabel(5),
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(filters) { filter in
                    filterChip(filter)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
        }
    }

    private func filterChip(_ filter: PhotoFilter) -> some View {
        let isActive = activeFilter == filter
        let count = countForFilter(filter)

        return Button {
            activeFilter = filter
        } label: {
            HStack(spacing: 4) {
                if case .colorLabel = filter {
                    Circle()
                        .fill(filter.chipColor)
                        .frame(width: 8, height: 8)
                } else {
                    Image(systemName: filter.symbol)
                        .font(.system(size: 10))
                }
                Text(filter.label)
                    .font(.caption.weight(.medium))
                if count > 0 && filter != .all {
                    Text("\(count)")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule().fill(
                    isActive
                        ? filter.chipColor.opacity(0.2)
                        : Color.secondary.opacity(0.08)
                )
            )
            .overlay(
                Capsule().strokeBorder(
                    isActive ? filter.chipColor.opacity(0.5) : .clear,
                    lineWidth: 1
                )
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? filter.chipColor : .secondary)
    }

    private func countForFilter(_ filter: PhotoFilter) -> Int {
        switch filter {
        case .all:
            return imageURLs.count
        case .picked:
            return imageURLs.filter { vimKeymap.isPicked($0) }.count
        case .rejected:
            return imageURLs.filter { vimKeymap.isRejected($0) }.count
        case .colorLabel(let n):
            return imageURLs.filter { vimKeymap.colorLabel(for: $0) == n }.count
        }
    }
}

// MARK: - Filtering logic

extension PhotoFilter {
    /// Apply this filter to a URL list using the VimKeymap state.
    @MainActor
    func apply(to urls: [URL], keymap: VimKeymap) -> [URL] {
        switch self {
        case .all:
            return urls
        case .picked:
            return urls.filter { keymap.isPicked($0) }
        case .rejected:
            return urls.filter { keymap.isRejected($0) }
        case .colorLabel(let n):
            return urls.filter { keymap.colorLabel(for: $0) == n }
        }
    }
}
