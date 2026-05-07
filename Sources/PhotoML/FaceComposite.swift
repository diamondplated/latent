import Foundation
import CoreImage
import CoreGraphics
import PipelineCore

/// Helpers for cropping a face region, resizing for model inference, and
/// alpha-blending the restored crop back into the source image with feathered
/// edges so the face↔background transition isn't visible.
public enum FaceComposite {

    /// Pad and clamp a face bounding box to image bounds. Padding is a fraction
    /// of the smaller dimension — gives the restoration model surrounding
    /// context (chin, hair, ears) which matters for identity preservation.
    public static func paddedFaceRect(
        face: DetectedFace,
        imageWidth: Int,
        imageHeight: Int,
        paddingFraction: Double = 0.3
    ) -> CGRect {
        let pad = min(face.bounds.width, face.bounds.height) * paddingFraction
        let padded = face.bounds.insetBy(dx: -pad, dy: -pad)
        return padded.intersection(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
            .integral  // round to int pixels
    }

    /// Crop a sub-region of an `ImageBuffer`. Coordinates in pixel space,
    /// origin top-left. Returned buffer is in working format.
    public static func crop(_ source: ImageBuffer, rect: CGRect) -> ImageBuffer {
        let x = Int(rect.origin.x)
        let y = Int(rect.origin.y)
        let w = Int(rect.width)
        let h = Int(rect.height)
        let bpp = source.format.bytesPerPixel
        let srcRow = source.width * bpp
        let dstRow = w * bpp
        var data = Data(count: dstRow * h)
        source.pixels.withUnsafeBytes { src in
            data.withUnsafeMutableBytes { dst in
                let srcPtr = src.bindMemory(to: UInt8.self).baseAddress!
                let dstPtr = dst.bindMemory(to: UInt8.self).baseAddress!
                for row in 0..<h {
                    memcpy(
                        dstPtr + row * dstRow,
                        srcPtr + (y + row) * srcRow + x * bpp,
                        dstRow
                    )
                }
            }
        }
        return ImageBuffer(width: w, height: h, format: source.format, pixels: data)
    }

    /// Resize a buffer using Core Image Lanczos. Working format in / working
    /// format out; color-managed in linear sRGB.
    public static func resize(_ source: ImageBuffer, toWidth: Int, height: Int) throws -> ImageBuffer {
        let cgImage = try source.makeCGImage()
        let scaleX = CGFloat(toWidth) / CGFloat(source.width)
        let scaleY = CGFloat(height) / CGFloat(source.height)

        let ciImage = CIImage(cgImage: cgImage)
            .applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: scaleY,
                kCIInputAspectRatioKey: scaleX / scaleY,
            ])

        let workingSpace = CGColorSpace(name: CGColorSpace.linearSRGB)!
        let context = CIContext(options: [.workingColorSpace: workingSpace])
        guard let outCG = context.createCGImage(
            ciImage,
            from: CGRect(x: 0, y: 0, width: toWidth, height: height),
            format: .RGBA16,
            colorSpace: workingSpace
        ) else {
            return source
        }
        return try ImageBuffer.fromCGImage(outCG)
    }

    /// Alpha-blend `restored` into a region of `base` with linear feathered
    /// alpha at the edges. `featherWidth` controls the width of the fade band
    /// in pixels of the destination rect; smaller = sharper transition.
    /// `strength` (0…1) globally scales the alpha — at 0, no change; at 1,
    /// the inner solid region is fully replaced.
    ///
    /// Modifies `base.pixels` in place via a copy. Returns a new buffer.
    public static func blend(
        base: ImageBuffer,
        restored: ImageBuffer,
        atRect rect: CGRect,
        featherWidth: Int = 16,
        strength: Float = 1.0
    ) -> ImageBuffer {
        precondition(base.format == .working && restored.format == .working)

        let rx = Int(rect.origin.x)
        let ry = Int(rect.origin.y)
        let rw = Int(rect.width)
        let rh = Int(rect.height)
        precondition(restored.width == rw && restored.height == rh, "restored size must match rect")

        var output = base.pixels
        let baseW = base.width
        let baseH = base.height

        output.withUnsafeMutableBytes { outRaw in
            restored.pixels.withUnsafeBytes { restRaw in
                let dst = outRaw.bindMemory(to: Float16.self).baseAddress!
                let rest = restRaw.bindMemory(to: Float16.self).baseAddress!

                for ty in 0..<rh {
                    let py = ry + ty
                    if py < 0 || py >= baseH { continue }
                    for tx in 0..<rw {
                        let px = rx + tx
                        if px < 0 || px >= baseW { continue }

                        let dxLeft = tx
                        let dxRight = rw - 1 - tx
                        let dyTop = ty
                        let dyBottom = rh - 1 - ty
                        let edgeDist = min(dxLeft, dxRight, dyTop, dyBottom)
                        let feather: Float = featherWidth == 0 ? 1.0 :
                            min(Float(edgeDist) / Float(featherWidth), 1.0)
                        let alpha = feather * strength

                        let basePx = py * baseW + px
                        let restPx = ty * rw + tx

                        for c in 0..<3 {  // RGB; leave alpha channel intact
                            let b = Float(dst[basePx * 4 + c])
                            let r = Float(rest[restPx * 4 + c])
                            dst[basePx * 4 + c] = Float16(b * (1 - alpha) + r * alpha)
                        }
                    }
                }
            }
        }

        return ImageBuffer(width: base.width, height: base.height, format: .working, pixels: output)
    }
}
