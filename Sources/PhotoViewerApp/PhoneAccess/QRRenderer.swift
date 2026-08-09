import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR generation via CoreImage. No dependency needed — `CIQRCodeGenerator`
/// has shipped since macOS 10.9.
enum QRRenderer {
    /// `size` is in points. The bitmap is rendered at `scale`× that so a
    /// Retina display has real pixels to draw rather than an upscale — a soft
    /// QR is a QR a camera has to work at.
    static func image(for string: String, size: CGFloat, scale: CGFloat = 2) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Medium correction: the code is read off a bright screen at close
        // range, so the extra redundancy of H buys nothing but density.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }

        let factor = (size * scale) / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: factor, y: factor))

        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}
