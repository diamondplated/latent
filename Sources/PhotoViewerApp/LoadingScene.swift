import SwiftUI

/// Full-bleed loader shown while a folder is being scanned or an archive is
/// being extracted. Designed so the user can tell at a glance:
///   - what's actually happening (extracting vs scanning)
///   - what folder/archive
///   - that progress is being made (live count + animated indicator)
///
/// Uses an indeterminate visual progress bar (we don't know the total file
/// count up front for recursive walks) plus an animated count that ticks up
/// as `LoadPhase.scanning.photosFound` increments.
struct LoadingScene: View {
    let phase: AppState.LoadPhase
    let lastError: String?

    @State private var pulse: CGFloat = 1.0

    var body: some View {
        VStack(spacing: 24) {
            iconLayer
                .scaleEffect(pulse)
                .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)

            VStack(spacing: 6) {
                Text(title)
                    .font(.title2.weight(.semibold))
                Text(subtitle)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 320)
            }

            statusRow

            indeterminateProgressBar
                .frame(width: 220, height: 4)

            if let lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .padding(.top, 4)
            }
        }
        .padding(36)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.tertiary, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 28, y: 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .onAppear { pulse = 1.08 }
    }

    // MARK: - Pieces

    /// Icon block: gradient-filled rounded square with an SF Symbol that
    /// changes per phase. The pulse animation makes it feel alive even when
    /// the count isn't moving (e.g., during the slow tar extract on a huge
    /// archive).
    private var iconLayer: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18)
                .fill(
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.85), Color.accentColor.opacity(0.55)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 88, height: 88)
                .shadow(color: Color.accentColor.opacity(0.3), radius: 20, y: 4)
            Image(systemName: iconSymbol)
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(.white)
                .symbolEffect(.pulse.byLayer, options: .repeating)
        }
    }

    private var iconSymbol: String {
        switch phase {
        case .extracting: return "shippingbox.fill"
        case .scanning:   return "folder.fill"
        }
    }

    private var title: String {
        switch phase {
        case .extracting: return "Extracting archive"
        case .scanning:   return "Scanning folder"
        }
    }

    private var subtitle: String {
        switch phase {
        case .extracting(let name): return name
        case .scanning(let name, _): return name
        }
    }

    /// Live status: "X photos found" while scanning; "Decompressing…" while
    /// extracting (we don't get incremental progress out of unzip without
    /// piping its verbose output).
    private var statusRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Group {
                switch phase {
                case .extracting:
                    Text("Decompressing…")
                case .scanning(_, let n):
                    let label = n == 0 ? "Looking for photos…"
                                       : "\(n) photo\(n == 1 ? "" : "s") found"
                    Text(label)
                        .contentTransition(.numericText(countsDown: false))
                        .animation(.snappy, value: n)
                }
            }
            .font(.system(.body, design: .rounded))
            .foregroundStyle(.primary)
        }
    }

    /// Custom indeterminate bar — looks slicker than the default ProgressView
    /// indeterminate style on macOS (which is a tiny spinner) at this size.
    private var indeterminateProgressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.4), Color.accentColor],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * 0.35)
                    .offset(x: shimmerOffset(in: geo.size.width))
                    .animation(
                        .linear(duration: 1.4).repeatForever(autoreverses: false),
                        value: shimmerKey
                    )
            }
        }
    }

    @State private var shimmerKey: Bool = false
    private func shimmerOffset(in width: CGFloat) -> CGFloat {
        // Toggle the key on appear so the implicit animation starts. The
        // actual offset values are picked to slide the bar fully across.
        if shimmerKey { return width * 0.65 } else { return -width * 0.35 }
    }
}

// Note: #Preview macro requires Xcode's preview infrastructure, which the
// CommandLineTools SPM toolchain doesn't ship. Add previews back in when
// the project migrates to an Xcode workspace.
