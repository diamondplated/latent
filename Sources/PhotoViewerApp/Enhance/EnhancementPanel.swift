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

                    // Sharpen first — it's the one stage that always works
                    // without any models installed, so it's the most useful
                    // default for a fresh user.
                    stageSection(
                        title: "Sharpen",
                        isExpanded: $sharpenExpanded,
                        enabled: state.sharpenEnabled,
                        status: StageStatusResolver.sharpen()
                    ) {
                        SharpenControls(state: state)
                    }
                    stageSection(
                        title: "Upscale",
                        isExpanded: $upscaleExpanded,
                        enabled: state.upscaleEnabled,
                        status: StageStatusResolver.upscale(params: state.upscaleParams)
                    ) {
                        UpscaleControls(state: state)
                    }
                    stageSection(
                        title: "Denoise",
                        isExpanded: $denoiseExpanded,
                        enabled: state.denoiseEnabled,
                        status: StageStatusResolver.denoise()
                    ) {
                        DenoiseControls(state: state)
                    }
                    stageSection(
                        title: "Artifact Removal",
                        isExpanded: $artifactRemovalExpanded,
                        enabled: state.artifactRemovalEnabled,
                        status: StageStatusResolver.artifactRemoval()
                    ) {
                        ArtifactRemovalControls(state: state)
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
        status: StageStatus,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureGroup(isExpanded: isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    if !status.isOperational {
                        // Inline disclosure for placebo stages — explains
                        // exactly why the toggle is disabled. Includes the
                        // conversion-script command so the user can do
                        // something about it.
                        modelMissingNote(title: title)
                    }
                    content()
                        .disabled(!status.isOperational)
                        .opacity(status.isOperational ? 1 : 0.5)
                }
                .padding(.top, 8)
                .padding(.horizontal, 4)
            } label: {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let badge = status.badge {
                        Text(badge)
                            .font(.system(.caption2, design: .rounded))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    // Status dot: green = real (classical or ML installed),
                    // orange = degraded fallback, gray = placebo.
                    Circle()
                        .fill(status.dotColor.opacity(enabled ? 1 : 0.35))
                        .frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 12)
            Divider().padding(.top, 8)
        }
    }

    /// Shown inline inside a stage section when its model isn't installed.
    /// Tells the user what they're missing and exactly how to fix it.
    private func modelMissingNote(title: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(title) needs its CoreML model.")
                    .font(.caption.weight(.medium))
                Text("Run scripts/convert_*.py to install. The toggle is disabled until it's available.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Compare-mode picker: enhanced / original / side-by-side. Hold
            // B at any time to flash the original on top of any of these.
            // Switching away from .original kicks off the heavy decode +
            // pipeline run if not already done — that's how we keep nav
            // fast in the default case.
            Picker("View", selection: $state.compareMode) {
                ForEach(CompareMode.allCases) { mode in
                    Label(mode.label, systemImage: mode.symbol).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .onChange(of: state.compareMode) { _, newMode in
                if newMode != .original {
                    state.ensureEnhancedAvailable()
                }
            }

            HStack(spacing: 8) {
                Button {
                    Task { await state.saveEnhanced() }
                } label: {
                    Label("Apply & Save", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .keyboardShortcut("s", modifiers: .command)
                // Enabled as soon as a photo is selected — the save path
                // lazy-loads the buffer if we haven't done the heavy decode
                // yet (default browsing case).
                .disabled(state.currentURL == nil)
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
