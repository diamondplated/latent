import SwiftUI
import AppKit

/// Renders + edits annotations over an image-displaying view. Sized to its
/// parent (`.allowsHitTesting(true)` when active so it captures drags); when
/// inactive it just renders existing annotations and lets clicks pass
/// through to the photo's pan/zoom gestures.
struct AnnotationOverlay: View {
    @Bindable var state: AnnotationState
    /// Bounds of the image as drawn on screen (so click coords map sanely).
    /// In single-pane mode we paint over the whole pane; the points are
    /// stored in pane-local coords, which is fine since we always render
    /// with the same transform.
    let isInteractive: Bool

    @State private var dragStart: CGPoint? = nil
    @State private var pendingTextPoint: CGPoint? = nil
    @State private var pendingText: String = ""

    var body: some View {
        Canvas { ctx, size in
            // Render committed annotations first, then the in-flight one
            // on top so the user sees their drag preview.
            for ann in state.annotations { draw(ann, in: &ctx, size: size) }
            if let pending = state.inFlight { draw(pending, in: &ctx, size: size) }
        }
        .contentShape(Rectangle())  // make hit-testing fill the canvas
        .allowsHitTesting(isInteractive)
        .gesture(drawGesture, including: isInteractive ? .all : .none)
        .sheet(item: textSheetBinding) { entry in
            TextEntrySheet(initialText: "") { text in
                state.addText(text, at: entry.point)
                pendingTextPoint = nil
                pendingText = ""
            } onCancel: {
                pendingTextPoint = nil
                pendingText = ""
            }
        }
    }

    // MARK: - Drawing

    private func draw(_ ann: PhotoAnnotation, in ctx: inout GraphicsContext, size: CGSize) {
        switch ann {
        case .arrow(_, let s, let e, let color, let w):
            drawArrow(from: s, to: e, color: color, width: w, in: &ctx)
        case .rectangle(_, let r, let color, let w):
            ctx.stroke(Path(r), with: .color(color.swiftUIColor), lineWidth: w)
        case .ellipse(_, let r, let color, let w):
            ctx.stroke(Path(ellipseIn: r), with: .color(color.swiftUIColor), lineWidth: w)
        case .freehand(_, let points, let color, let w):
            guard let first = points.first else { return }
            var path = Path()
            path.move(to: first)
            for p in points.dropFirst() { path.addLine(to: p) }
            ctx.stroke(path, with: .color(color.swiftUIColor),
                       style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
        case .text(_, let p, let text, let color, let fontSize):
            let res = ctx.resolve(Text(text)
                .font(.system(size: fontSize, weight: .bold))
                .foregroundStyle(color.swiftUIColor))
            // Background pill for readability
            let measured = res.measure(in: size)
            let bgRect = CGRect(x: p.x - 4, y: p.y - 2, width: measured.width + 8, height: measured.height + 4)
            ctx.fill(Path(roundedRect: bgRect, cornerRadius: 4), with: .color(.black.opacity(0.55)))
            ctx.draw(res, at: p, anchor: .topLeading)
        }
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, color: AnnotationColor, width: CGFloat, in ctx: inout GraphicsContext) {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let len = hypot(dx, dy)
        guard len > 0 else { return }

        // Shaft
        var shaft = Path()
        shaft.move(to: start)
        shaft.addLine(to: end)
        ctx.stroke(shaft, with: .color(color.swiftUIColor),
                   style: StrokeStyle(lineWidth: width, lineCap: .round))

        // Head — equilateral triangle whose base is normal to the shaft
        let headLen = max(width * 4, 14.0)
        let angle = atan2(dy, dx)
        let p1 = CGPoint(
            x: end.x - headLen * cos(angle - .pi / 7),
            y: end.y - headLen * sin(angle - .pi / 7)
        )
        let p2 = CGPoint(
            x: end.x - headLen * cos(angle + .pi / 7),
            y: end.y - headLen * sin(angle + .pi / 7)
        )
        var head = Path()
        head.move(to: end)
        head.addLine(to: p1)
        head.addLine(to: p2)
        head.closeSubpath()
        ctx.fill(head, with: .color(color.swiftUIColor))
    }

    // MARK: - Gesture

    private var drawGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isInteractive else { return }
                if state.tool == .text {
                    // Text is a tap; treat the start as a single click.
                    return
                }
                if dragStart == nil {
                    dragStart = value.startLocation
                    state.beginShape(at: value.startLocation)
                }
                state.updateShape(to: value.location, from: value.startLocation)
            }
            .onEnded { value in
                defer { dragStart = nil }
                guard isInteractive else { return }
                if state.tool == .text {
                    pendingTextPoint = value.location
                    return
                }
                state.updateShape(to: value.location, from: value.startLocation)
                state.commitShape()
            }
    }

    // MARK: - Text sheet

    /// Wraps `pendingTextPoint` in an Identifiable value so .sheet(item:)
    /// can present and dismiss based on its non-nil state.
    private struct PendingTextEntry: Identifiable {
        let id = UUID()
        let point: CGPoint
    }

    private var textSheetBinding: Binding<PendingTextEntry?> {
        Binding(
            get: { pendingTextPoint.map { PendingTextEntry(point: $0) } },
            set: { newValue in
                if newValue == nil { pendingTextPoint = nil }
            }
        )
    }
}

private struct TextEntrySheet: View {
    @State private var text: String
    let onSubmit: (String) -> Void
    let onCancel: () -> Void

    init(initialText: String, onSubmit: @escaping (String) -> Void, onCancel: @escaping () -> Void) {
        self._text = State(initialValue: initialText)
        self.onSubmit = onSubmit
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Annotation text")
                .font(.headline)
            TextField("Type a label…", text: $text)
                .textFieldStyle(.roundedBorder)
                .onSubmit { onSubmit(text) }
            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add") { onSubmit(text) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.isEmpty)
            }
        }
        .padding()
        .frame(width: 360)
    }
}
