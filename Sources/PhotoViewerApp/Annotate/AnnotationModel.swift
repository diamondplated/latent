import Foundation
import SwiftUI
import AppKit

/// One drawn annotation. Stored as a tagged value type so the overlay's
/// rendering and the export code can pattern-match without inheritance.
public enum PhotoAnnotation: Sendable, Equatable, Identifiable {
    case arrow(id: UUID, start: CGPoint, end: CGPoint, color: AnnotationColor, width: CGFloat)
    case rectangle(id: UUID, rect: CGRect, color: AnnotationColor, width: CGFloat)
    case ellipse(id: UUID, rect: CGRect, color: AnnotationColor, width: CGFloat)
    case freehand(id: UUID, points: [CGPoint], color: AnnotationColor, width: CGFloat)
    case text(id: UUID, point: CGPoint, text: String, color: AnnotationColor, fontSize: CGFloat)

    public var id: UUID {
        switch self {
        case .arrow(let id, _, _, _, _): return id
        case .rectangle(let id, _, _, _): return id
        case .ellipse(let id, _, _, _): return id
        case .freehand(let id, _, _, _): return id
        case .text(let id, _, _, _, _): return id
        }
    }
}

/// Codable color — SwiftUI Color isn't Sendable/Codable on its own. Stored
/// per-annotation; renderer maps to NSColor + Color at draw time.
public enum AnnotationColor: String, Sendable, Codable, CaseIterable, Identifiable {
    case red, yellow, green, blue, magenta, white, black

    public var id: String { rawValue }

    public var swiftUIColor: Color {
        switch self {
        case .red: .red
        case .yellow: .yellow
        case .green: .green
        case .blue: .blue
        case .magenta: .pink
        case .white: .white
        case .black: .black
        }
    }

    public var nsColor: NSColor {
        switch self {
        case .red: .systemRed
        case .yellow: .systemYellow
        case .green: .systemGreen
        case .blue: .systemBlue
        case .magenta: .systemPink
        case .white: .white
        case .black: .black
        }
    }
}

public enum AnnotationTool: String, CaseIterable, Identifiable {
    case arrow, rectangle, ellipse, freehand, text

    public var id: String { rawValue }
    public var symbol: String {
        switch self {
        case .arrow: "arrow.up.right"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .freehand: "pencil.line"
        case .text: "textformat"
        }
    }
}

/// Active annotation editor state. Holds the in-progress shape (during a
/// drag) plus the committed list, plus the current tool/color/width. Lives
/// on the BrowserView level so vim keys can be suppressed while editing.
@MainActor
@Observable
final class AnnotationState {
    /// Whether the annotation overlay is active. When false, mouse/keyboard
    /// behave as in normal browse mode.
    var isActive: Bool = false

    /// Current tool. Changed via the toolbar.
    var tool: AnnotationTool = .arrow
    /// Current color.
    var color: AnnotationColor = .red
    /// Current stroke width (pt).
    var width: CGFloat = 4

    /// Committed annotations on the current photo.
    var annotations: [PhotoAnnotation] = []
    /// In-progress shape, while the user is mid-drag. Rendered alongside
    /// `annotations` but not persisted until release.
    var inFlight: PhotoAnnotation? = nil
    /// The photo URL these annotations belong to. When the user changes
    /// photos, annotations are cleared (they don't move with the user).
    var url: URL? = nil

    /// Reset everything — call when the selected photo changes or the user
    /// hits Clear.
    func clear() {
        annotations.removeAll()
        inFlight = nil
    }

    func bind(to url: URL?) {
        if self.url != url {
            self.url = url
            clear()
        }
    }

    func undo() {
        if !annotations.isEmpty { annotations.removeLast() }
    }

    /// Begin a shape at the given point.
    func beginShape(at point: CGPoint) {
        switch tool {
        case .arrow:
            inFlight = .arrow(id: UUID(), start: point, end: point, color: color, width: width)
        case .rectangle:
            inFlight = .rectangle(id: UUID(), rect: CGRect(origin: point, size: .zero), color: color, width: width)
        case .ellipse:
            inFlight = .ellipse(id: UUID(), rect: CGRect(origin: point, size: .zero), color: color, width: width)
        case .freehand:
            inFlight = .freehand(id: UUID(), points: [point], color: color, width: width)
        case .text:
            // Text uses click-to-place + sheet; not drag-driven.
            break
        }
    }

    /// Update the in-flight shape as the drag progresses.
    func updateShape(to point: CGPoint, from start: CGPoint) {
        guard let current = inFlight else { return }
        switch current {
        case .arrow(let id, let s, _, let c, let w):
            inFlight = .arrow(id: id, start: s, end: point, color: c, width: w)
        case .rectangle(let id, _, let c, let w):
            inFlight = .rectangle(id: id, rect: rectFromCorners(start, point), color: c, width: w)
        case .ellipse(let id, _, let c, let w):
            inFlight = .ellipse(id: id, rect: rectFromCorners(start, point), color: c, width: w)
        case .freehand(let id, var points, let c, let w):
            points.append(point)
            inFlight = .freehand(id: id, points: points, color: c, width: w)
        case .text:
            break
        }
    }

    /// Commit the in-flight shape (drop trivially-small rectangles/arrows).
    func commitShape() {
        guard let shape = inFlight else { return }
        defer { inFlight = nil }
        switch shape {
        case .arrow(_, let s, let e, _, _):
            if hypot(e.x - s.x, e.y - s.y) < 6 { return } // ignore taps
        case .rectangle(_, let r, _, _), .ellipse(_, let r, _, _):
            if r.width < 6 || r.height < 6 { return }
        case .freehand(_, let pts, _, _):
            if pts.count < 2 { return }
        case .text: break
        }
        annotations.append(shape)
    }

    /// Used by the text tool: place a text annotation at point.
    func addText(_ text: String, at point: CGPoint) {
        guard !text.isEmpty else { return }
        annotations.append(.text(id: UUID(), point: point, text: text, color: color, fontSize: max(12, width * 4)))
    }
}

private func rectFromCorners(_ a: CGPoint, _ b: CGPoint) -> CGRect {
    CGRect(
        x: min(a.x, b.x),
        y: min(a.y, b.y),
        width: abs(a.x - b.x),
        height: abs(a.y - b.y)
    )
}
