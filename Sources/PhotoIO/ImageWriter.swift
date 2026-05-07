import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PipelineCore

public enum ImageWriteError: Error, CustomStringConvertible {
    case destinationCreationFailed(URL)
    case finalizeFailed(URL)
    case sourceBufferInvalid(reason: String)
    case formatConversionFailed
    case bridgeError(any Error)

    public var description: String {
        switch self {
        case .destinationCreationFailed(let url): "Could not create destination at \(url.path)"
        case .finalizeFailed(let url): "Failed to finalize destination at \(url.path)"
        case .sourceBufferInvalid(let r): "Source buffer invalid: \(r)"
        case .formatConversionFailed: "Failed to convert pixel format for destination"
        case .bridgeError(let err): "Image-buffer bridge: \(err)"
        }
    }
}

public struct ImageWriteOptions: Sendable {
    /// Format to encode as. If nil, defaults to the source format from
    /// metadata, or JPEG if the source had no recognized format.
    public var format: ImageFileFormat?

    /// JPEG/HEIC quality 0.0-1.0. Default 0.95 (high quality, ~minimal artifacts).
    /// PNG ignores this.
    public var quality: Double

    /// If true, copy through EXIF/IPTC/GPS/etc. from the source metadata blob.
    /// Set to false for "privacy export" mode.
    public var preserveMetadata: Bool

    /// Output color space. If nil, mirrors the source color space.
    public var outputColorSpace: ColorSpaceTag?

    public init(
        format: ImageFileFormat? = nil,
        quality: Double = 0.95,
        preserveMetadata: Bool = true,
        outputColorSpace: ColorSpaceTag? = nil
    ) {
        self.format = format
        self.quality = quality
        self.preserveMetadata = preserveMetadata
        self.outputColorSpace = outputColorSpace
    }
}

/// Writes an `ImageBuffer` (working format) to a URL in a chosen file format.
///
/// Pixel pipeline: buffer (linear sRGB float16) → CIImage → CGImage rendered
/// in the destination color space at 8-bit per channel → CGImageDestination.
///
/// Metadata pipeline: original CGImageSource properties (from the read) are
/// copied through verbatim, with `kCGImagePropertyOrientation` overridden to
/// `.up` (since the reader baked rotation into pixels). Pass
/// `preserveMetadata: false` to strip everything for privacy export.
public struct ImageWriter: Sendable {
    public init() {}

    public func write(
        buffer: ImageBuffer,
        metadata: ImageMetadata?,
        to url: URL,
        options: ImageWriteOptions = ImageWriteOptions()
    ) throws {
        guard buffer.format == .working else {
            throw ImageWriteError.sourceBufferInvalid(reason: "expected working format, got \(buffer.format)")
        }

        let format = options.format ?? metadata?.sourceFormat ?? .jpeg

        // Determine destination color space.
        let outputCS = options.outputColorSpace ?? metadata?.colorSpace ?? .sRGB
        let destColorSpace = outputCS.encodingCGColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!

        // Render working-format buffer → 8-bit destination CGImage.
        let cgImage = try render(buffer: buffer, to: destColorSpace)

        // Build destination.
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            format.utType.identifier as CFString,
            1,
            nil
        ) else {
            throw ImageWriteError.destinationCreationFailed(url)
        }

        // Properties to attach.
        var properties: [CFString: Any] = [:]
        if options.preserveMetadata, let metadata {
            properties = (try? metadata.properties()) ?? [:]
        }
        // Always force orientation to .up — pixels are canonical now.
        properties[kCGImagePropertyOrientation] = ExifOrientation.up.rawValue

        // Quality applies to lossy formats.
        switch format {
        case .jpeg, .heic:
            properties[kCGImageDestinationLossyCompressionQuality] = max(0.0, min(1.0, options.quality))
        case .png, .tiff:
            break
        }

        CGImageDestinationAddImage(destination, cgImage, properties as CFDictionary)

        guard CGImageDestinationFinalize(destination) else {
            throw ImageWriteError.finalizeFailed(url)
        }
    }

    /// Render the working-format buffer to an 8-bit RGBA CGImage in the
    /// destination color space. CGContext handles the linear → gamma encoding
    /// and the gamut conversion.
    private func render(buffer: ImageBuffer, to destColorSpace: CGColorSpace) throws -> CGImage {
        // Get the buffer as a working-space CGImage.
        let sourceCG: CGImage
        do {
            sourceCG = try buffer.makeCGImage()
        } catch {
            throw ImageWriteError.bridgeError(error)
        }

        // Allocate an 8-bit destination context in the target color space.
        let bitmapInfo = CGBitmapInfo(rawValue:
            CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
        let bytesPerRow = buffer.width * 4

        guard let context = CGContext(
            data: nil,
            width: buffer.width,
            height: buffer.height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: destColorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            throw ImageWriteError.formatConversionFailed
        }

        context.draw(sourceCG, in: CGRect(x: 0, y: 0, width: buffer.width, height: buffer.height))

        guard let cgImage = context.makeImage() else {
            throw ImageWriteError.formatConversionFailed
        }
        return cgImage
    }
}
