import Foundation
import Darwin
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PipelineCore

public enum ImageWriteError: Error, CustomStringConvertible {
    case destinationCreationFailed(URL)
    case finalizeFailed(URL)
    case commitFailed(URL, any Error)
    case sourceBufferInvalid(reason: String)
    case formatConversionFailed
    case bridgeError(any Error)

    public var description: String {
        switch self {
        case .destinationCreationFailed(let url): "Could not create destination at \(url.path)"
        case .finalizeFailed(let url): "Failed to finalize destination at \(url.path)"
        case .commitFailed(let url, let error): "Could not commit export at \(url.path): \(error.localizedDescription)"
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

    /// Encode beside the destination and atomically move the completed file
    /// into place. Existing files are never replaced: if `preferredURL`
    /// exists, Finder-style numbered siblings (`name 2.ext`, `name 3.ext`, …)
    /// are tried until one can be claimed.
    ///
    /// Encoding to a same-directory temporary file ensures a failed encode
    /// cannot leave a partial result under the user-visible filename, while
    /// the final move is an atomic rename on the destination volume.
    @discardableResult
    public func writeKeepingBoth(
        buffer: ImageBuffer,
        metadata: ImageMetadata?,
        to preferredURL: URL,
        options: ImageWriteOptions = ImageWriteOptions()
    ) throws -> URL {
        let fileManager = FileManager.default
        let directory = preferredURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(
            ".latent-export-\(UUID().uuidString).tmp",
            isDirectory: false
        )
        defer { try? fileManager.removeItem(at: temporaryURL) }

        try write(buffer: buffer, metadata: metadata, to: temporaryURL, options: options)

        var copyNumber = 1
        while true {
            let candidate = Self.keepBothCandidate(for: preferredURL, copyNumber: copyNumber)
            let result = Self.renameExclusively(from: temporaryURL, to: candidate)
            if result == 0 {
                return candidate
            }
            if result == EEXIST {
                // The exclusive rename closes the existence-check race: another
                // app instance may claim this exact name at any time, but it can
                // never be replaced by our commit. Retry with the next suffix.
                copyNumber += 1
                continue
            }
            let error = NSError(domain: NSPOSIXErrorDomain, code: Int(result))
            throw ImageWriteError.commitFailed(candidate, error)
        }
    }

    /// Atomically rename `source` only if `destination` does not exist. Plain
    /// POSIX `rename` can replace an existing destination, so a separate
    /// `fileExists` check is not enough to uphold Export Copy's never-overwrite
    /// contract when two Latent processes export concurrently.
    private static func renameExclusively(from source: URL, to destination: URL) -> Int32 {
        source.withUnsafeFileSystemRepresentation { sourcePath in
            destination.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else { return EINVAL }
                if renamex_np(sourcePath, destinationPath, UInt32(RENAME_EXCL)) == 0 {
                    return 0
                }
                return errno
            }
        }
    }

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

    private static func keepBothCandidate(for preferredURL: URL, copyNumber: Int) -> URL {
        guard copyNumber > 1 else { return preferredURL }

        let directory = preferredURL.deletingLastPathComponent()
        let ext = preferredURL.pathExtension
        let stem = preferredURL.deletingPathExtension().lastPathComponent
        let numbered = directory.appendingPathComponent("\(stem) \(copyNumber)", isDirectory: false)
        return ext.isEmpty ? numbered : numbered.appendingPathExtension(ext)
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
