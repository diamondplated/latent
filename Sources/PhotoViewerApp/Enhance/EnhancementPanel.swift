import SwiftUI

/// Side panel: 5 collapsible per-stage sections plus the global controls
/// (Show Original toggle, Apply & Save, status row). Sized for a comfortable
/// HSplitView width on a 13" laptop without crowding the image.
@MainActor
struct EnhancementPanel: View {
    @Bindable var state: EnhancementState
    /// Which sections are expanded. Defaults below match what the standard
    /// pipeline emphasizes so a brand-new user sees something useful first.
    @State private var artifactRemovalExpanded: Bool = false
    @State private var denoiseExpanded: Bool = true
    @State private var faceRestoreExpanded: Bool = false
    @State private var upscaleExpanded: Bool = true
    @State private var sharpenExpanded: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Enhancements")
                        .font(.headline)
                        .padding(.horizontal, 12)
                        .padding(.top, 12)

                    stageSection(
                        title: "Artifact Removal",
                        isExpanded: $artifactRemovalExpanded,
                        enabled: state.artifactRemovalEnabled
                    ) {
                        ArtifactRemovalControls(state: state)
                    }
                    stageSection(
                        title: "Denoise",
                        isExpanded: $denoiseExpanded,
                        enabled: state.denoiseEnabled
                    ) {
                        DenoiseControls(state: state)
                    }
                    stageSection(
                        title: "Face Restore",
                        isExpanded: $faceRestoreExpanded,
                        enabled: state.faceRestoreEnabled
                    ) {
                        FaceRestoreControls(state: state)
                    }
                    stageSection(
                        title: "Upscale",
                        isExpanded: $upscaleExpanded,
                        enabled: state.upscaleEnabled
                    ) {
                        UpscaleControls(state: state)
                    }
                    stageSection(
                        title: "Sharpen",
                        isExpanded: $sharpenExpanded,
                        enabled: state.sharpenEnabled
                    ) {
                        SharpenControls(state: state)
                    }

                    Spacer(minLength: 8)
                }
                .padding(.bottom, 12)
            }
            Divider()
            footer
        }
        .frame(minWidth: 280, idealWidth: 320, maxWidth: 400)
    }

    // MARK: - Pieces

    @ViewBuilder
    private func stageSection<Content: View>(
        title: String,
        isExpanded: Binding<Bool>,
        enabled: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: isExpanded) {
                content()
                    .padding(.top, 8)
                    .padding(.horizontal, 4)
            } label: {
                HStack {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    // Small dot indicates whether the stage will run on the
                    // next pipeline pass — a quick at-a-glance check that's
                    // visible even when the section is collapsed.
                    Circle()
                        .fill(enabled ? Color.accentColor : Color.secondary.opacity(0.4))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12)
            Divider().padding(.top, 8)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Show original", isOn: Binding(
                get: { state.showingOriginal },
                set: { state.showingOriginal = $0 }
            ))

            HStack(spacing: 8) {
                Button {
                    Task { await state.saveEnhanced() }
                } label: {
                    Label("Apply & Save", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(state.currentURL == nil || state.originalBuffer == nil)
            }

            statusRow
        }
        .padding(12)
    }

    @ViewBuilder
    private var statusRow: some View {
        if let err = state.lastError {
            Label(err, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .lineLimit(2)
        } else if state.isProcessing {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Processing…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if let url = state.currentURL {
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        } else {
            Text("No photo selected")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
