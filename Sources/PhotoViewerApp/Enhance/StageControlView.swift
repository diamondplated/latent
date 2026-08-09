import SwiftUI
import EnhancementStages

// One concrete control view per stage. Generics over StageParameters would
// require a non-trivial view-builder shim because each stage has a different
// number and type of fields; concrete views keep the binding paths obvious
// and let SwiftUI's diffing avoid spurious rebuilds.
//
// Every view follows the same shape:
//   - Toggle("Enabled") on first row
//   - Sliders/Pickers for each Param field, dimmed when disabled
//   - Each control calls `state.runPipeline()` on commit so the result
//     refreshes after the user releases the mouse.

@MainActor
struct ArtifactRemovalControls: View {
    @Bindable var state: EnhancementState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enabled", isOn: Binding(
                get: { state.artifactRemovalEnabled },
                set: { state.artifactRemovalEnabled = $0; state.runPipeline() }
            ))
            sliderRow(
                label: "Strength",
                value: Binding(
                    get: { state.artifactRemovalParams.strength },
                    set: { state.artifactRemovalParams.strength = $0 }
                ),
                range: 0...1,
                format: "%.2f",
                onCommit: { state.runPipeline() }
            )
            .disabled(!state.artifactRemovalEnabled)
        }
    }
}

@MainActor
struct DenoiseControls: View {
    @Bindable var state: EnhancementState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enabled", isOn: Binding(
                get: { state.denoiseEnabled },
                set: { state.denoiseEnabled = $0; state.runPipeline() }
            ))
            sliderRow(
                label: "Strength",
                value: Binding(
                    get: { state.denoiseParams.strength },
                    set: { state.denoiseParams.strength = $0 }
                ),
                range: 0...1,
                format: "%.2f",
                onCommit: { state.runPipeline() }
            )
            sliderRow(
                label: "Preserve detail",
                value: Binding(
                    get: { state.denoiseParams.preserveDetailBias },
                    set: { state.denoiseParams.preserveDetailBias = $0 }
                ),
                range: 0...1,
                format: "%.2f",
                onCommit: { state.runPipeline() }
            )
        }
        .disabled(!state.denoiseEnabled)
    }
}

@MainActor
struct UpscaleControls: View {
    @Bindable var state: EnhancementState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enabled", isOn: Binding(
                get: { state.upscaleEnabled },
                set: { state.upscaleEnabled = $0; state.runPipeline() }
            ))
            HStack {
                Text("Scale").frame(width: 110, alignment: .leading)
                // Upscale.Params validates 2 or 4 in its initializer; pick a
                // segmented Picker so the user can't enter an invalid value.
                Picker("", selection: Binding(
                    get: { state.upscaleParams.scale },
                    set: { state.upscaleParams.scale = $0; state.runPipeline() }
                )) {
                    Text("2×").tag(2)
                    Text("4×").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            HStack {
                Text("Model").frame(width: 110, alignment: .leading)
                Picker("", selection: Binding(
                    get: { state.upscaleParams.model },
                    set: { state.upscaleParams.model = $0; state.runPipeline() }
                )) {
                    Text("Real-ESRGAN x4+").tag(Upscale.Model.realESRGANx4plus)
                    Text("SwinIR Large").tag(Upscale.Model.swinIRLarge)
                }
                .labelsHidden()
            }
            sliderRow(
                label: "Tile size",
                value: Binding(
                    get: { Double(state.upscaleParams.tileSize) },
                    set: { state.upscaleParams.tileSize = Int($0) }
                ),
                range: 128...1024,
                step: 64,
                format: "%.0f",
                onCommit: { state.runPipeline() }
            )
        }
        .disabled(!state.upscaleEnabled)
    }
}

@MainActor
struct SharpenControls: View {
    @Bindable var state: EnhancementState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Enabled", isOn: Binding(
                get: { state.sharpenEnabled },
                set: { state.sharpenEnabled = $0; state.runPipeline() }
            ))
            sliderRow(
                label: "Amount",
                value: Binding(
                    get: { state.sharpenParams.amount },
                    set: { state.sharpenParams.amount = $0 }
                ),
                range: 0...2,
                format: "%.2f",
                onCommit: { state.runPipeline() }
            )
            sliderRow(
                label: "Radius",
                value: Binding(
                    get: { state.sharpenParams.radius },
                    set: { state.sharpenParams.radius = $0 }
                ),
                range: 0.1...10,
                format: "%.2f",
                onCommit: { state.runPipeline() }
            )
            sliderRow(
                label: "Threshold",
                value: Binding(
                    get: { state.sharpenParams.threshold },
                    set: { state.sharpenParams.threshold = $0 }
                ),
                range: 0...0.5,
                format: "%.3f",
                onCommit: { state.runPipeline() }
            )
        }
        .disabled(!state.sharpenEnabled)
    }
}

// MARK: - Slider helper

/// Label + slider + numeric readout in a fixed-width row. `onCommit` fires
/// when the user releases the slider so we don't kick off a pipeline run for
/// every tick of an active drag.
@MainActor
fileprivate func sliderRow(
    label: String,
    value: Binding<Double>,
    range: ClosedRange<Double>,
    step: Double? = nil,
    format: String,
    onCommit: @escaping () -> Void
) -> some View {
    HStack(spacing: 8) {
        Text(label)
            .frame(width: 110, alignment: .leading)
        if let step {
            Slider(
                value: value,
                in: range,
                step: step,
                onEditingChanged: { editing in if !editing { onCommit() } }
            )
        } else {
            Slider(
                value: value,
                in: range,
                onEditingChanged: { editing in if !editing { onCommit() } }
            )
        }
        Text(String(format: format, value.wrappedValue))
            .font(.system(.caption, design: .monospaced))
            .frame(width: 56, alignment: .trailing)
            .foregroundStyle(.secondary)
    }
}
