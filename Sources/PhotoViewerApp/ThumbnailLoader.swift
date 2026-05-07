import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Async thumbnail generation using ImageIO's downsample fast path.
/// Caches NSImage results by URL for the session.
@MainActor
final class ThumbnailLoader: ObservableObject {
    static let shared = ThumbnailLoader()

    private var cache: [URL: NSImage] = [:]
    private var inflight: [URL: Task<NSImage?, Never>] = [:]
    private let maxDimension: Int = 256

    func thumbnail(for url: URL) async -> NSImage? {
        if let cached = cache[url] { return cached }
        if let task = inflight[url] { return await task.value }

        let task = Task<NSImage?, Never> { [maxDimension] in
            await Self.makeThumbnail(url: url, maxDimension: maxDimension)
        }
        inflight[url] = task

        let result = await task.value
        inflight.removeValue(forKey: url)
        if let result { cache[url] = result }
        return result
    }

    private static func makeThumbnail(url: URL, maxDimension: Int) async -> NSImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let options: [CFString: Any] = [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,  // honors EXIF orientation
                    kCGImageSourceThumbnailMaxPixelSize: maxDimension,
                    kCGImageSourceShouldCacheImmediately: true,
                ]
                guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                let nsImage = NSImage(cgImage: cg, size: .init(width: cg.width, height: cg.height))
                continuation.resume(returning: nsImage)
            }
        }
    }
}
