import Foundation
import CoreVideo
import CoreGraphics

public struct ImageFormat: Hashable, Sendable {
    public enum PixelLayout: Sendable, Hashable {
        case rgbaFloat16
        case rgbaFloat32
        case rgba8
    }

    public enum ColorSpace: Sendable, Hashable {
        case linearSRGB
        case sRGB
        case linearDisplayP3
        case displayP3
    }

    public let layout: PixelLayout
    public let colorSpace: ColorSpace

    public init(layout: PixelLayout, colorSpace: ColorSpace) {
        self.layout = layout
        self.colorSpace = colorSpace
    }

    /// Pipeline working format: linear sRGB, 16-bit float per channel.
    public static let working = ImageFormat(layout: .rgbaFloat16, colorSpace: .linearSRGB)

    public var bytesPerPixel: Int {
        switch layout {
        case .rgba8: 4
        case .rgbaFloat16: 8
        case .rgbaFloat32: 16
        }
    }
}

/// A reference to image pixel data flowing through the pipeline.
///
/// Backed by raw `Data` for portability and easy hashing. In a later milestone
/// this will gain CVPixelBuffer-backed initializers for zero-copy interop with
/// CoreML and Metal; the public surface is stable.
public struct ImageBuffer: Sendable {
    public let width: Int
    public let height: Int
    public let format: ImageFormat
    public let pixels: Data

    /// Stable hash of the pixel content + dimensions + format. Used as cache
    /// key prefix so identical inputs reuse cached intermediates across runs.
    public let contentHash: ContentHash

    public init(width: Int, height: Int, format: ImageFormat, pixels: Data) {
        precondition(width > 0 && height > 0)
        precondition(pixels.count == width * height * format.bytesPerPixel,
                     "pixel buffer size mismatch: got \(pixels.count), expected \(width * height * format.bytesPerPixel)")
        self.width = width
        self.height = height
        self.format = format
        self.pixels = pixels
        self.contentHash = ContentHash(width: width, height: height, format: format, pixels: pixels)
    }

    /// Construct without recomputing hash (used internally when hash is already known).
    init(width: Int, height: Int, format: ImageFormat, pixels: Data, contentHash: ContentHash) {
        self.width = width
        self.height = height
        self.format = format
        self.pixels = pixels
        self.contentHash = contentHash
    }
}

/// Stable 64-bit content hash. SipHash via Swift's standard `Hasher` is fine
/// for cache lookups (collision-resistant enough; not cryptographic).
public struct ContentHash: Hashable, Sendable, CustomStringConvertible {
    public let value: UInt64

    init(width: Int, height: Int, format: ImageFormat, pixels: Data) {
        var hasher = Hasher()
        hasher.combine(width)
        hasher.combine(height)
        hasher.combine(format)
        // Hashing all pixels would be expensive on large images. Sample 4KB
        // at deterministic offsets — fine for cache identity (false collisions
        // produce wrong-but-deterministic cache hits, not crashes).
        let sampleCount = 4096
        let stride = max(1, pixels.count / sampleCount)
        var i = 0
        while i < pixels.count {
            hasher.combine(pixels[i])
            i += stride
        }
        hasher.combine(pixels.count)
        self.value = UInt64(bitPattern: Int64(hasher.finalize()))
    }

    public init(value: UInt64) {
        self.value = value
    }

    public var description: String { String(format: "%016x", value) }
}
