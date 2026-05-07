import SwiftUI
import AppKit

/// Floating toolbar shown while annotation mode is active. Tool picker on
/// the left, color/width in the middle, actions on the right (undo, clear,
/// copy, save).
struct AnnotationToolbar: View {
    @Bindable var state: AnnotationState
    let onCopy: () -> Void
    let onSave: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            toolPicker
            Divider().frame(height: 22)
            colorPicker
            widthSlider
            Divider().frame(height: 22)
            actions
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.tertiary, lineWidth: 0.5))
    }

    private var toolPicker: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    state.tool = tool
                } label: {
                    Image(systemName: tool.symbol)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.borderless)
                .background(state.tool == tool ? Color.accentColor.opacity(0.25) : .clear,
                            in: RoundedRectangle(cornerRadius: 4))
                .help(tool.rawValue.capitalized)
            }
        }
    }

    private var colorPicker: some View {
        HStack(spacing: 4) {
            ForEach(AnnotationColor.allCases) { c in
                Button {
                    state.color = c
                } label: {
                    Circle()
                        .fill(c.swiftUIColor)
                        .frame(width: 16, height: 16)
                        .overlay(
                            Circle().strokeBorder(.primary,
                                                  lineWidth: state.color == c ? 2 : 0.5)
                        )
                }
                .buttonStyle(.plain)
                .help(c.rawValue.capitalized)
            }
        }
    }

    private var widthSlider: some View {
        HStack(spacing: 4) {
            Image(systemName: "line.diagonal")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Slider(value: $state.width, in: 1...20)
                .frame(width: 80)
            Text("\(Int(state.width))pt")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 28, alignment: .leading)
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                state.undo()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .disabled(state.annotations.isEmpty)
            .help("Undo last annotation")

            Button {
                state.clear()
            } label: {
                Image(systemName: "trash")
            }
            .disabled(state.annotations.isEmpty && state.inFlight == nil)
            .help("Clear all annotations")

            Button {
                onCopy()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .disabled(state.annotations.isEmpty)
            .help("Copy annotated image to clipboard")

            Button {
                onSave()
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .disabled(state.annotations.isEmpty)
            .help("Save annotated copy next to original")
        }
        .buttonStyle(.borderless)
    }
}
