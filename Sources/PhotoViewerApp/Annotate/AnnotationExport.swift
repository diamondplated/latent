import Foundation
import AppKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PipelineCore

/// Renders an image + annotation list into a single flattened CGImage and
/// writes it to disk (next to the source as `<stem>_annotated.<ext>`) or
/// puts it on the system pasteboard.
///
/// Coordinate system: annotations are stored in the on-screen pane's
/// coordinates. To export against the source image's full resolution we
/// rescale by `imageSize / paneSize`.
enum AnnotationExport {

    struct ExportResult {
        let url: URL?       // nil when we only copied to clipboard
        let pixelSize: CGSize
    }

    /// Save annotations baked into a copy of the source. Returns the new URL.
    /// Uses JPEG at quality 0.95 unless the source is PNG/TIFF — those keep
    /// their lossless encoding.
    static func saveAnnotated(
        sourceURL: URL,
        annotations: [PhotoAnnotation],
        paneSize: CGSize
    ) throws -> URL {
        let cg = try renderFlat(sourceURL: sourceURL, annotations: annotations, paneSize: paneSize)
        let outURL = annotatedURL(for: sourceURL)
        let utType = preferredOutputType(for: sourceURL)
        try writeCGImage(cg, to: outURL, utType: utType)
        return outURL
    }

    /// Write annotated bitmap to NSPasteboard so the user can paste it into
    /// Slack / Mail / a chat with Claude.
    static func copyAnnotatedToClipboard(
        sourceURL: URL,
        annotations: [PhotoAnnotation],
        paneSize: CGSize
    ) throws {
        let cg = try renderFlat(sourceURL: sourceURL, annotations: annotations, paneSize: paneSize)
        let nsImage = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([nsImage])
    }

    // MARK: - Internals

    /// Render the source image plus annotations to a single CGImage at the
    /// source's native pixel resolution. Annotations get scaled from
    /// pane-space to image-space.
    private static func renderFlat(
        sourceURL: URL,
        annotations: [PhotoAnnotation],
        paneSize: CGSize
    ) throws -> CGImage {
        guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
              let sourceImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
            throw NSError(domain: "AnnotationExport", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not read \(sourceURL.lastPathComponent)"])
        }

        let imgW = CGFloat(sourceImage.width)
        let imgH = CGFloat(sourceImage.height)
        // SwiftUI's image fits to the pane preserving aspect ratio. Compute
        // the on-screen box of the image so annotation coords (pane-space)
        // can be rebased to image-pixel-space correctly.
        let scale = min(paneSize.width / imgW, paneSize.height / imgH)
        let drawnW = imgW * scale
        let drawnH = imgH * scale
        let originX = (paneSize.width - drawnW) / 2
        let originY = (paneSize.height - drawnH) / 2

        let bytesPerRow = sourceImage.width * 4
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(
            data: nil,
            width: sourceImage.width,
            height: sourceImage.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw NSError(domain: "AnnotationExport", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create flatten context"])
        }

        // Draw the source full-bleed.
        ctx.draw(sourceImage, in: CGRect(x: 0, y: 0, width: sourceImage.width, height: sourceImage.height))

        // CGContext has y-up origin (bottom-left). SwiftUI's coord space is
        // y-down. Convert by flipping y around the image height.
        ctx.saveGState()
        ctx.translateBy(x: 0, y: imgH)
        ctx.scaleBy(x: 1, y: -1)

        for annotation in annotations {
            drawAnnotation(annotation, in: ctx, paneSize: paneSize, drawnOrigin: CGPoint(x: originX, y: originY), drawnSize: CGSize(width: drawnW, height: drawnH), imgSize: CGSize(width: imgW, height: imgH))
        }

        ctx.restoreGState()

        guard let out = ctx.makeImage() else {
            throw NSError(domain: "AnnotationExport", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "Could not make CGImage from context"])
        }
        return out
    }

    private static func drawAnnotation(
        _ ann: PhotoAnnotation,
        in ctx: CGContext,
        paneSize: CGSize,
        drawnOrigin: CGPoint,
        drawnSize: CGSize,
        imgSize: CGSize
    ) {
        // Map a pane-space point into image-pixel-space.
        func toImage(_ p: CGPoint) -> CGPoint {
            let dx = (p.x - drawnOrigin.x) / drawnSize.width * imgSize.width
            let dy = (p.y - drawnOrigin.y) / drawnSize.height * imgSize.height
            return CGPoint(x: dx, y: dy)
        }
        // Rescale stroke width into image-pixel-space.
        let stroke: (CGFloat) -> CGFloat = { w in
            w / drawnSize.width * imgSize.width
        }

        switch ann {
        case .arrow(_, let s, let e, let color, let w):
            ctx.setStrokeColor(color.nsColor.cgColor)
            ctx.setFillColor(color.nsColor.cgColor)
            ctx.setLineWidth(stroke(w))
            ctx.setLineCap(.round)
            let imgS = toImage(s)
            let imgE = toImage(e)
            ctx.move(to: imgS)
            ctx.addLine(to: imgE)
            ctx.strokePath()
            // Arrow head
            let dx = imgE.x - imgS.x
            let dy = imgE.y - imgS.y
            let len = hypot(dx, dy)
            if len > 0 {
                let headLen = max(stroke(w) * 4, 14.0)
                let angle = atan2(dy, dx)
                let p1 = CGPoint(x: imgE.x - headLen * cos(angle - .pi / 7),
                                 y: imgE.y - headLen * sin(angle - .pi / 7))
                let p2 = CGPoint(x: imgE.x - headLen * cos(angle + .pi / 7),
                                 y: imgE.y - headLen * sin(angle + .pi / 7))
                ctx.move(to: imgE)
                ctx.addLine(to: p1)
                ctx.addLine(to: p2)
                ctx.closePath()
                ctx.fillPath()
            }
        case .rectangle(_, let r, let color, let w):
            ctx.setStrokeColor(color.nsColor.cgColor)
            ctx.setLineWidth(stroke(w))
            let p1 = toImage(r.origin)
            let p2 = toImage(CGPoint(x: r.maxX, y: r.maxY))
            ctx.stroke(CGRect(origin: p1, size: CGSize(width: p2.x - p1.x, height: p2.y - p1.y)))
        case .ellipse(_, let r, let color, let w):
            ctx.setStrokeColor(color.nsColor.cgColor)
            ctx.setLineWidth(stroke(w))
            let p1 = toImage(r.origin)
            let p2 = toImage(CGPoint(x: r.maxX, y: r.maxY))
            ctx.strokeEllipse(in: CGRect(origin: p1, size: CGSize(width: p2.x - p1.x, height: p2.y - p1.y)))
        case .freehand(_, let points, let color, let w):
            guard let first = points.first else { return }
            ctx.setStrokeColor(color.nsColor.cgColor)
            ctx.setLineWidth(stroke(w))
            ctx.setLineCap(.round)
            ctx.setLineJoin(.round)
            ctx.move(to: toImage(first))
            for p in points.dropFirst() { ctx.addLine(to: toImage(p)) }
            ctx.strokePath()
        case .text(_, let p, let text, let color, let fontSize):
            // Use NSAttributedString.draw which handles font + color in CG.
            let pixelOrigin = toImage(p)
            let scaledFontSize = stroke(fontSize)
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: scaledFontSize, weight: .bold),
                .foregroundColor: color.nsColor,
            ]
            let str = NSAttributedString(string: text, attributes: attrs)
            // Compute size for the dark background pill
            let size = str.size()
            let padX: CGFloat = 4 * imgSize.width / drawnSize.width
            let padY: CGFloat = 2 * imgSize.height / drawnSize.height
            let bgRect = CGRect(
                x: pixelOrigin.x - padX,
                y: pixelOrigin.y - padY,
                width: size.width + padX * 2,
                height: size.height + padY * 2
            )
            // We're inside a y-flipped CGContext. NSAttributedString.draw
            // interprets the flip correctly when called via NSGraphicsContext.
            NSGraphicsContext.saveGraphicsState()
            let nsCtx = NSGraphicsContext(cgContext: ctx, flipped: true)
            NSGraphicsContext.current = nsCtx
            // Background pill
            ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
            let bgPath = CGPath(roundedRect: bgRect, cornerWidth: 4, cornerHeight: 4, transform: nil)
            ctx.addPath(bgPath)
            ctx.fillPath()
            // Text on top
            str.draw(at: pixelOrigin)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func annotatedURL(for source: URL) -> URL {
        let stem = source.deletingPathExtension().lastPathComponent
        let ext = source.pathExtension
        return source.deletingLastPathComponent()
            .appendingPathComponent("\(stem)_annotated.\(ext)")
    }

    private static func preferredOutputType(for source: URL) -> CFString {
        let ext = source.pathExtension.lowercased()
        switch ext {
        case "png": return UTType.png.identifier as CFString
        case "tif", "tiff": return UTType.tiff.identifier as CFString
        case "heic", "heif": return UTType.heic.identifier as CFString
        default: return UTType.jpeg.identifier as CFString
        }
    }

    private static func writeCGImage(_ cg: CGImage, to url: URL, utType: CFString) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, utType, 1, nil) else {
            throw NSError(domain: "AnnotationExport", code: -4,
                          userInfo: [NSLocalizedDescriptionKey: "Could not create destination at \(url.path)"])
        }
        let props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        if !CGImageDestinationFinalize(dest) {
            throw NSError(domain: "AnnotationExport", code: -5,
                          userInfo: [NSLocalizedDescriptionKey: "Failed to finalize \(url.path)"])
        }
    }
}
