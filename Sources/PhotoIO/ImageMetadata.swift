import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

// MARK: - EXIF orientation

/// EXIF orientation tag (1-8). Defines how stored pixels relate to the visual
/// "up" direction of the photo. The reader bakes any non-`up` orientation into
/// pixel data so the rest of the pipeline always sees canonical (up=1) buffers.
public enum ExifOrientation: Int, Sendable, Codable, CaseIterable {
    case up = 1                // 0°
    case upMirrored = 2        // horizontal flip
    case down = 3              // 180°
    case downMirrored = 4      // vertical flip
    case leftMirrored = 5      // 90° CW + horizontal flip
    case right = 6             // 90° CW
    case rightMirrored = 7     // 90° CCW + horizontal flip
    case left = 8              // 90° CCW

    /// True if the orientation swaps width and height visually.
    public var swapsAxes: Bool {
        switch self {
        case .leftMirrored, .right, .rightMirrored, .left: true
        default: false
        }
    }
}

// MARK: - Color space tag

/// Identifies the color space of the source file. Used to drive
/// destination-color-space selection on write.
public enum ColorSpaceTag: Sendable, Codable, Equatable {
    case sRGB
    case displayP3
    case adobeRGB
    case proPhotoRGB
    /// Profile name was unrecognized; we'll assume sRGB on encode but record
    /// the raw name so callers can warn.
    case unknown(name: String)

    init(cgColorSpace: CGColorSpace?) {
        guard let cs = cgColorSpace, let nameRef = cs.name else { self = .unknown(name: "<no name>"); return }
        let name = nameRef as String

        // Local string constants since `case CGColorSpace.foo as String` isn't a valid pattern.
        let sRGBNames: Set<String> = [
            CGColorSpace.sRGB as String,
            CGColorSpace.linearSRGB as String,
            CGColorSpace.extendedSRGB as String,
        ]
        let displayP3Names: Set<String> = [
            CGColorSpace.displayP3 as String,
            CGColorSpace.linearDisplayP3 as String,
            CGColorSpace.extendedLinearDisplayP3 as String,
        ]
        let adobeName = CGColorSpace.adobeRGB1998 as String
        let proPhotoName = CGColorSpace.rommrgb as String

        if sRGBNames.contains(name) { self = .sRGB; return }
        if displayP3Names.contains(name) { self = .displayP3; return }
        if name == adobeName { self = .adobeRGB; return }
        if name == proPhotoName { self = .proPhotoRGB; return }
        self = .unknown(name: name)
    }

    /// Color space to use when writing. We always encode to a well-known space;
    /// `.unknown` is treated as sRGB for safety.
    var encodingCGColorSpace: CGColorSpace? {
        switch self {
        case .sRGB, .unknown: CGColorSpace(name: CGColorSpace.sRGB)
        case .displayP3: CGColorSpace(name: CGColorSpace.displayP3)
        case .adobeRGB: CGColorSpace(name: CGColorSpace.adobeRGB1998)
        case .proPhotoRGB: CGColorSpace(name: CGColorSpace.rommrgb)
        }
    }
}

// MARK: - File format

public enum ImageFileFormat: Sendable {
    case jpeg
    case heic
    case png
    case tiff

    var utType: UTType {
        switch self {
        case .jpeg: .jpeg
        case .heic: .heic
        case .png: .png
        case .tiff: .tiff
        }
    }

    static func from(utType: UTType) -> ImageFileFormat? {
        if utType.conforms(to: .jpeg) { return .jpeg }
        if utType.conforms(to: .heic) { return .heic }
        if utType.conforms(to: .png) { return .png }
        if utType.conforms(to: .tiff) { return .tiff }
        return nil
    }
}

// MARK: - Metadata

/// Image metadata extracted from a source file and copied through to writes.
///
/// The reader bakes EXIF orientation into pixel data, so the `orientation`
/// here is what was *originally* tagged — useful for round-trip preservation
/// in the sidecar and for telling the writer "the canonical image was rotated
/// from this orientation." On write we always emit orientation = .up because
/// pixel data already reflects upright.
public struct ImageMetadata: Sendable {
    public let pixelWidth: Int
    public let pixelHeight: Int
    public let originalOrientation: ExifOrientation
    public let colorSpace: ColorSpaceTag
    public let sourceFormat: ImageFileFormat?

    /// Binary plist of the full CGImageSource property dictionary. Preserved
    /// opaquely so we can copy through GPS, camera, lens, IPTC, XMP, etc.
    /// without enumerating every key. Use `properties()` to inspect.
    public let propertiesBlob: Data

    public init(
        pixelWidth: Int,
        pixelHeight: Int,
        originalOrientation: ExifOrientation,
        colorSpace: ColorSpaceTag,
        sourceFormat: ImageFileFormat?,
        propertiesBlob: Data
    ) {
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.originalOrientation = originalOrientation
        self.colorSpace = colorSpace
        self.sourceFormat = sourceFormat
        self.propertiesBlob = propertiesBlob
    }

    /// Decode the opaque plist back to the CGImageSource dictionary. Each call
    /// re-parses; cache the result if you need to read it many times.
    public func properties() throws -> [CFString: Any] {
        guard !propertiesBlob.isEmpty else { return [:] }
        let plist = try PropertyListSerialization.propertyList(from: propertiesBlob, options: [], format: nil)
        guard let dict = plist as? [String: Any] else { return [:] }
        var out: [CFString: Any] = [:]
        for (k, v) in dict { out[k as CFString] = v }
        return out
    }
}

// MARK: - Plist round-trip helpers

enum MetadataPList {

    /// Serialize a CGImage properties dictionary to a binary plist Data.
    /// Drops keys whose values aren't plist-compatible (e.g., raw makernotes
    /// CFData inside nested dictionaries are fine; arbitrary CFType isn't).
    static func encode(_ properties: [CFString: Any]) throws -> Data {
        var stringKeyed: [String: Any] = [:]
        for (k, v) in properties {
            stringKeyed[k as String] = filterToPListCompatible(v)
        }
        return try PropertyListSerialization.data(fromPropertyList: stringKeyed, format: .binary, options: 0)
    }

    /// Recursively keep only plist-compatible values (String, NSNumber, Data,
    /// Date, Array, Dictionary). Anything else is dropped — better to lose
    /// exotic metadata than to crash the encoder.
    private static func filterToPListCompatible(_ value: Any) -> Any {
        switch value {
        case let dict as [String: Any]:
            var filtered: [String: Any] = [:]
            for (k, v) in dict { filtered[k] = filterToPListCompatible(v) }
            return filtered
        case let array as [Any]:
            return array.map(filterToPListCompatible)
        case is String, is NSNumber, is Data, is Date, is Bool, is Int, is Double, is Float:
            return value
        case let cfString as CFString:
            return cfString as String
        case let cfNumber where CFGetTypeID(cfNumber as CFTypeRef) == CFNumberGetTypeID():
            return cfNumber as! NSNumber
        case let cfData where CFGetTypeID(cfData as CFTypeRef) == CFDataGetTypeID():
            return cfData as! Data
        case let cfBoolean where CFGetTypeID(cfBoolean as CFTypeRef) == CFBooleanGetTypeID():
            return CFBooleanGetValue((cfBoolean as! CFBoolean))
        default:
            return ""  // drop unknowns; they'll re-emerge as empty strings, harmless
        }
    }
}
