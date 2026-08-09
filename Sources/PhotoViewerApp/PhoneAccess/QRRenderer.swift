import Foundation
import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// QR generation via CoreImage. No dependency needed — `CIQRCodeGenerator`
/// has shipped since macOS 10.9.
enum QRRenderer {
    static func image(for string: String, size: CGFloat) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(string.utf8)
        // Medium correction: the code is read off a bright screen at close
        // range, so the extra redundancy of H buys nothing but density.
        filter.correctionLevel = "M"
        guard let output = filter.outputImage, output.extent.width > 0 else { return nil }

        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        let context = CIContext()
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: size, height: size))
    }
}
