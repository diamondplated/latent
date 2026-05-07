import SwiftUI

/// Sexy placeholder for the brief gap between selection and the preview
/// landing on screen. Looks like a real photo "loading", not a generic
/// indeterminate spinner. Shimmer band sweeps across a dim photo-ish
/// silhouette while a small accent spinner sits in the corner.
///
/// Visible window in normal use: tens of milliseconds (until
/// `previewNSImage` populates from the cheap NSImage(contentsOf:) path).
/// On slow drives or for first-time iCloud-synced photos, the preview is
/// further away — that's when this gets read.
struct PhotoSkeleton: View {
    @State private var shimmerOn: Bool = false

    var body: some View {
        ZStack {
            // Soft gradient background — photo-ish dark grey with a slight
            // depth gradient so it doesn't read as "broken empty rect".
            LinearGradient(
                colors: [Color(white: 0.10), Color(white: 0.16)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            // Centered icon with a gentle pulse — gives the eye something
            // to land on so the gap doesn't feel like a hang.
            VStack(spacing: 10) {
                Image(systemName: "photo.fill")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.white.opacity(0.16))
                    .symbolEffect(.pulse.byLayer, options: .repeating)
            }

            // Shimmer pass: a wide diagonal gradient that sweeps across.
            // Drives "is this loading" affordance without taking the focal
            // point of the pane.
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        .init(color: .white.opacity(0), location: 0.0),
                        .init(color: .white.opacity(0.08), location: 0.5),
                        .init(color: .white.opacity(0), location: 1.0),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .frame(width: geo.size.width * 0.6)
                .offset(x: shimmerOn ? geo.size.width * 0.7 : -geo.size.width * 0.7)
                .blendMode(.plusLighter)
            }
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(8)
        .onAppear {
            withAnimation(.linear(duration: 1.6).repeatForever(autoreverses: false)) {
                shimmerOn.toggle()
            }
        }
    }
}
