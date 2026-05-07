import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import PipelineCore

public enum ImageReadError: Error, CustomStringConvertible {
    case sourceCreationFailed(URL)
    case noImagesInSource(URL)
    case primaryImageDecodeFailed(URL)
    case orientationBakingFailed
    case bridgeError(any Error)

    public var description: String {
        switch self {
        case .sourceCreationFailed(let url): "Could not open image source: \(url.lastPathComponent)"
        case .noImagesInSource(let url): "No images in source: \(url.lastPathComponent)"
        case .primaryImageDecodeFailed(let url): "Could not decode primary image: \(url.lastPathComponent)"
        case .orientationBakingFailed: "Failed to bake EXIF orientation into pixel data"
        case .bridgeError(let err): "Image-buffer bridge: \(err)"
        }
    }
}

/// Reads an image file into the pipeline's working format.
///
/// Returns `(ImageBuffer, ImageMetadata)`. The buffer is always in canonical
/// (up) orientation: any non-trivial EXIF orientation is baked into pixel data
/// here so the rest of the pipeline never has to think about it. The metadata
/// records the original orientation so writes can choose to either keep the
/// canonical pixels (with orientation = .up) or honor a sidecar override.
///
/// Color management: source pixels are converted to linear sRGB float16 by the
/// `ImageBuffer.fromCGImage` bridge, regardless of source profile (sRGB,
/// Display P3, Adobe RGB, etc.). The original color space is recorded in
/// metadata so writes can target the same gamut.
public struct ImageReader: Sendable {
    public init() {}

    public func read(url: URL) throws -> (ImageBuffer, ImageMetadata) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw ImageReadError.sourceCreationFailed(url)
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw ImageReadError.noImagesInSource(url)
        }

        // Properties dictionary at index 0 (primary image).
        let propertiesCF = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]

        let pixelWidth = (propertiesCF[kCGImagePropertyPixelWidth] as? Int) ?? 0
        let pixelHeight = (propertiesCF[kCGImagePropertyPixelHeight] as? Int) ?? 0
        let orientationRaw = (propertiesCF[kCGImagePropertyOrientation] as? Int) ?? 1
        let orientation = ExifOrientation(rawValue: orientationRaw) ?? .up

        // Extract source format from UTType reported by ImageIO.
        let utiString = (CGImageSourceGetType(source) as String?) ?? ""
        let sourceFormat = UTType(utiString).flatMap(ImageFileFormat.from(utType:))

        // Decode the primary image as a CGImage (no down-sampling, full pixels).
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw ImageReadError.primaryImageDecodeFailed(url)
        }

        // Bake orientation into pixel data via Core Image.
        let canonical = try bakeOrientation(cgImage: cgImage, orientation: orientation)

        // Detect color space from the produced canonical CGImage.
        let colorSpace = ColorSpaceTag(cgColorSpace: canonical.colorSpace)

        // Bridge to working format (linear sRGB float16). This also handles
        // the gamut conversion from any source space to sRGB primaries.
        let buffer: ImageBuffer
        do {
            buffer = try ImageBuffer.fromCGImage(canonical)
        } catch {
            throw ImageReadError.bridgeError(error)
        }

        let propertiesBlob = (try? MetadataPList.encode(propertiesCF)) ?? Data()

        let metadata = ImageMetadata(
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            originalOrientation: orientation,
            colorSpace: colorSpace,
            sourceFormat: sourceFormat,
            propertiesBlob: propertiesBlob
        )

        return (buffer, metadata)
    }

    /// Apply EXIF orientation to a CGImage, returning a new CGImage in
    /// canonical (up) orientation. Uses Core Image because CGImagePropertyOrientation
    /// values (1-8) match EXIF directly and the transform machinery is already
    /// built into CIImage.
    private func bakeOrientation(cgImage: CGImage, orientation: ExifOrientation) throws -> CGImage {
        if orientation == .up { return cgImage }

        let ciImage = CIImage(cgImage: cgImage).oriented(.init(rawValue: UInt32(orientation.rawValue)) ?? .up)
        let renderColorSpace = cgImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CIContext(options: [.workingColorSpace: renderColorSpace])

        guard let baked = context.createCGImage(ciImage, from: ciImage.extent, format: .RGBA16, colorSpace: renderColorSpace) else {
            throw ImageReadError.orientationBakingFailed
        }
        return baked
    }
}
