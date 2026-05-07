import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum QuickLookRendererError: Error, CustomStringConvertible {
    case sourceCreationFailed(URL)
    case thumbnailCreationFailed(URL)
    case unsupportedType(URL)

    public var description: String {
        switch self {
        case .sourceCreationFailed(let url): "Could not open image source: \(url.lastPathComponent)"
        case .thumbnailCreationFailed(let url): "Could not generate thumbnail for: \(url.lastPathComponent)"
        case .unsupportedType(let url): "Unsupported file type for preview: \(url.pathExtension)"
        }
    }
}

/// Renders a preview image for a given URL — the same code a Quick Look
/// extension would call. Lives here as a library so a future QL extension
/// target (added during the Xcode-project migration) can import it directly
/// without copying logic. CommandLineTools-only builds reach it via
/// `pv-pipeline` for verification.
///
/// Uses ImageIO's `CGImageSourceCreateThumbnailAtIndex` fast path:
/// - decodes from any format ImageIO supports (JPEG/HEIC/PNG/TIFF/WebP/RAW…)
/// - applies EXIF orientation automatically
/// - downsamples directly to the requested max dimension instead of
///   decoding full-resolution then resizing — fast even on 50MP files
public struct QuickLookRenderer: Sendable {
    /// Maximum pixel dimension on either axis. The output respects the
    /// source's aspect ratio.
    public let maxDimension: Int

    public init(maxDimension: Int = 1024) {
        precondition(maxDimension > 0, "maxDimension must be positive")
        self.maxDimension = maxDimension
    }

    /// Render the URL to a `CGImage` at most `maxDimension` pixels on either axis.
    /// EXIF orientation is baked in (the QL preview should match what Photos.app
    /// displays). For animated formats, returns the first frame.
    public func render(url: URL) throws -> CGImage {
        guard isSupported(url: url) else {
            throw QuickLookRendererError.unsupportedType(url)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            throw QuickLookRendererError.sourceCreationFailed(url)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw QuickLookRendererError.thumbnailCreationFailed(url)
        }
        return cg
    }

    /// Quick check based on file extension. Real validation happens at
    /// CGImageSourceCreate time; this is just a cheap pre-filter the
    /// extension's `LSItemContentTypes` would also enforce.
    public func isSupported(url: URL) -> Bool {
        Self.supportedExtensions.contains(url.pathExtension.lowercased())
    }

    public static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "tif", "tiff",
        "webp", "avif", "jxl", "gif", "bmp",
        // RAW formats ImageIO can preview via embedded JPEG:
        "cr2", "cr3", "nef", "arw", "raf", "dng", "orf", "rw2",
    ]
}

// MARK: - QL extension shim
//
// When the project migrates to an Xcode workspace, the Quick Look extension
// target subclasses `QLPreviewProvider` and calls into `QuickLookRenderer`.
// Sketch (cannot compile here without the QuickLookUI framework hooked up
// to an extension target):
//
// import QuickLookUI
// final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
//     private let renderer = QuickLookRenderer(maxDimension: 1600)
//     func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
//         let cg = try renderer.render(url: request.fileURL)
//         return QLPreviewReply(contextSize: CGSize(width: cg.width, height: cg.height),
//                               isBitmap: true,
//                               drawingBlock: { ctx in
//             ctx.draw(cg, in: CGRect(origin: .zero, size: CGSize(width: cg.width, height: cg.height)))
//             return true
//         })
//     }
// }
