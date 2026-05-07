import Foundation
import CoreGraphics

// CGImage ⇄ ImageBuffer interop.
//
// Lives in PipelineCore because every image-touching module (I/O, ML inference,
// UI rendering) needs to bridge to/from CGImage. CoreGraphics is a free
// dependency on Apple platforms.

public enum ImageBufferBridgeError: Error, CustomStringConvertible {
    case workingColorSpaceUnavailable
    case contextCreationFailed
    case cgImageCreationFailed
    case unsupportedFormat(reason: String)

    public var description: String {
        switch self {
        case .workingColorSpaceUnavailable: "Linear sRGB color space unavailable on this system"
        case .contextCreationFailed: "Failed to create CGContext for working format"
        case .cgImageCreationFailed: "Failed to create CGImage from buffer"
        case .unsupportedFormat(let reason): "Unsupported pixel format: \(reason)"
        }
    }
}

extension ImageFormat.ColorSpace {
    var cgColorSpace: CGColorSpace? {
        switch self {
        case .linearSRGB: CGColorSpace(name: CGColorSpace.linearSRGB)
        case .sRGB: CGColorSpace(name: CGColorSpace.sRGB)
        case .linearDisplayP3: CGColorSpace(name: CGColorSpace.linearDisplayP3)
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)
        }
    }
}

extension ImageBuffer {

    /// Render any CGImage into the working format (linear sRGB, float16 RGBA).
    /// Color management is handled by the CGContext: source colorspace → working
    /// space conversion happens inside `context.draw`, including gamma decoding
    /// from sRGB to linear and any wide-gamut → sRGB primary conversion.
    public static func fromCGImage(_ cgImage: CGImage) throws -> ImageBuffer {
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else {
            throw ImageBufferBridgeError.unsupportedFormat(reason: "zero dimension")
        }

        let format = ImageFormat.working
        guard let space = format.colorSpace.cgColorSpace else {
            throw ImageBufferBridgeError.workingColorSpaceUnavailable
        }

        let bitsPerComponent = 16
        let bytesPerRow = width * format.bytesPerPixel
        let bitmapInfo = workingBitmapInfo(format: format)

        let byteCount = bytesPerRow * height
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 16)
        // Zero-fill so any rows the draw doesn't touch are deterministic.
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: byteCount)

        guard let context = CGContext(
            data: buffer,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo
        ) else {
            buffer.deallocate()
            throw ImageBufferBridgeError.contextCreationFailed
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let data = Data(bytesNoCopy: buffer, count: byteCount, deallocator: .custom { ptr, _ in
            ptr.deallocate()
        })

        return ImageBuffer(width: width, height: height, format: format, pixels: data)
    }

    /// Produce a CGImage in the buffer's native (working) color space. Useful
    /// for handing buffers to UI / Quick Look. To encode for output, render
    /// this CGImage into a destination color space via CGContext (the writer
    /// does this).
    public func makeCGImage() throws -> CGImage {
        guard format == .working else {
            throw ImageBufferBridgeError.unsupportedFormat(reason: "expected working format, got \(format)")
        }
        guard let space = format.colorSpace.cgColorSpace else {
            throw ImageBufferBridgeError.workingColorSpaceUnavailable
        }

        let bytesPerRow = width * format.bytesPerPixel
        let bitmapInfo = workingBitmapInfo(format: format)

        // CFData wraps the Data; CG retains/releases automatically so the
        // pixel bytes outlive the CGImage.
        let cfData = pixels as CFData
        guard let provider = CGDataProvider(data: cfData) else {
            throw ImageBufferBridgeError.cgImageCreationFailed
        }

        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 16,
            bitsPerPixel: 64,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else {
            throw ImageBufferBridgeError.cgImageCreationFailed
        }

        return cgImage
    }
}

private func workingBitmapInfo(format: ImageFormat) -> CGBitmapInfo {
    // RGBA float16 premultiplied. Host byte order on Apple Silicon = little-endian.
    let raw = CGBitmapInfo.floatComponents.rawValue
        | CGImageAlphaInfo.premultipliedLast.rawValue
        | CGBitmapInfo.byteOrder16Little.rawValue
    return CGBitmapInfo(rawValue: raw)
}
