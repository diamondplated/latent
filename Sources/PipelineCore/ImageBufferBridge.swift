import Foundation
import CoreGraphics
import CoreVideo

// CGImage ⇄ ImageBuffer interop, plus CVPixelBuffer for ML inference.
//
// Lives in PipelineCore because every image-touching module (I/O, ML inference,
// UI rendering) needs to bridge to/from these system types. CoreGraphics and
// CoreVideo are free dependencies on Apple platforms.

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

// MARK: - CVPixelBuffer interop (CoreML / Vision)

extension ImageBuffer {

    /// Produce a CVPixelBuffer copy of the buffer in BGRA8 (the most common
    /// image-typed CoreML input). Picks BGRA8 specifically because:
    /// - CoreML accepts it natively (no autoconversion penalty)
    /// - Vision framework defaults to it
    /// - It's IOSurface-backed for zero-copy Metal interop
    ///
    /// Note: this conversion is destructive of the working format's float16
    /// precision (output is 8-bit). For models that need float32 RGB tensors,
    /// use the MLMultiArray path in the model wrapper instead.
    public func makeBGRA8PixelBuffer() throws -> CVPixelBuffer {
        let cgImage = try makeCGImage()

        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as [CFString: Any],
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attrs as CFDictionary,
            &pb
        )
        guard status == kCVReturnSuccess, let pixelBuffer = pb else {
            throw ImageBufferBridgeError.unsupportedFormat(reason: "CVPixelBufferCreate failed: status=\(status)")
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ImageBufferBridgeError.unsupportedFormat(reason: "CVPixelBuffer has no base address")
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo
        ) else {
            throw ImageBufferBridgeError.contextCreationFailed
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        return pixelBuffer
    }

    /// Read a CVPixelBuffer into the working format. Source format must be
    /// either BGRA8 or RGBA8; other formats can be added as needed.
    public static func fromCVPixelBuffer(_ pixelBuffer: CVPixelBuffer) throws -> ImageBuffer {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_32BGRA || pixelFormat == kCVPixelFormatType_32RGBA else {
            throw ImageBufferBridgeError.unsupportedFormat(
                reason: "expected BGRA8 or RGBA8 CVPixelBuffer, got \(String(format: "0x%08x", pixelFormat))"
            )
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw ImageBufferBridgeError.unsupportedFormat(reason: "CVPixelBuffer has no base address")
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo: UInt32
        if pixelFormat == kCVPixelFormatType_32BGRA {
            bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        } else {
            bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
        }
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: bitmapInfo
        ),
        let sourceCGImage = context.makeImage() else {
            throw ImageBufferBridgeError.contextCreationFailed
        }

        return try fromCGImage(sourceCGImage)
    }
}
