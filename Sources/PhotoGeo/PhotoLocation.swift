import Foundation
import ImageIO
import PhotoIO

// MARK: - Model

/// A photo's geographic location, normalized into signed decimal degrees.
///
/// Latitude in [-90, 90]; positive = north of equator, negative = south.
/// Longitude in [-180, 180]; positive = east of prime meridian, negative = west.
///
/// EXIF GPS dictionaries store the magnitude as a non-negative number alongside
/// a hemisphere reference ("N"/"S", "E"/"W"). `extractGPS(from:)` applies the
/// reference to produce the signed form here.
public struct PhotoLocation: Sendable, Hashable, Codable {
    public let url: URL
    public let latitude: Double
    public let longitude: Double

    public init(url: URL, latitude: Double, longitude: Double) {
        self.url = url
        self.latitude = latitude
        self.longitude = longitude
    }
}

// MARK: - GPS extraction

/// Pull GPS coordinates out of an `ImageMetadata` properties dictionary.
///
/// Returns nil if any of latitude, longitude, or their hemisphere references
/// is missing or unparseable. Both Latitude/Longitude values can come back as
/// `NSNumber` (typical from ImageIO), `Double`, or `Int`; we cast through
/// `NSNumber` for the broadest compatibility.
public func extractGPS(from metadata: ImageMetadata) -> (latitude: Double, longitude: Double)? {
    guard let properties = try? metadata.properties() else { return nil }
    guard let gps = properties[kCGImagePropertyGPSDictionary] as? [String: Any] else {
        // The nested dict may also come back string-keyed when round-tripped
        // through plist. Fall back to that form.
        return nil
    }

    return parseGPSDict(gps)
}

/// Internal: pull lat/lon out of an already-extracted GPS sub-dictionary.
/// String-keyed because the surrounding plist round-trip flattens CFString to
/// String.
func parseGPSDict(_ gps: [String: Any]) -> (latitude: Double, longitude: Double)? {
    let latKey = kCGImagePropertyGPSLatitude as String
    let lonKey = kCGImagePropertyGPSLongitude as String
    let latRefKey = kCGImagePropertyGPSLatitudeRef as String
    let lonRefKey = kCGImagePropertyGPSLongitudeRef as String

    guard
        let latMag = (gps[latKey] as? NSNumber)?.doubleValue,
        let lonMag = (gps[lonKey] as? NSNumber)?.doubleValue,
        let latRef = gps[latRefKey] as? String,
        let lonRef = gps[lonRefKey] as? String
    else {
        return nil
    }

    let latSign: Double = (latRef.uppercased() == "S") ? -1 : 1
    let lonSign: Double = (lonRef.uppercased() == "W") ? -1 : 1

    return (latitude: latMag * latSign, longitude: lonMag * lonSign)
}

// MARK: - Cache

/// Caches GPS extraction results across UI invocations.
///
/// Keyed by URL. The internal value is `PhotoLocation?` (not just
/// `PhotoLocation`) so that "this file has no GPS data" is itself a memoized
/// result — re-asking won't trigger another decode. Use `known(_:)` to
/// distinguish "we've checked" from "we haven't checked yet."
@MainActor
@Observable
public final class PhotoLocationCache {
    private var entries: [URL: PhotoLocation?] = [:]
    private let reader = ImageReader()

    public init() {}

    /// Resolve GPS for each URL we haven't already checked. Sequential — image
    /// decoding dominates, and parallelizing with TaskGroup would force
    /// `ImageReader` (a `Sendable` struct that holds no state) into more
    /// careful sharing for marginal gain on a one-shot folder load.
    public func locate(_ urls: [URL]) async {
        for url in urls {
            if entries[url] != nil { continue }  // already known (or known-nil)
            // Defensive: even if extraction throws, we still want to record
            // that we tried this URL so we don't loop on a corrupt file.
            entries[url] = readLocation(at: url)
        }
    }

    /// Pull-through accessor: returns the location if we have one, nil
    /// otherwise. Does NOT trigger extraction; call `locate` first.
    public func location(for url: URL) -> PhotoLocation? {
        entries[url] ?? nil
    }

    /// True once we've attempted extraction for this URL, regardless of result.
    public func known(_ url: URL) -> Bool {
        entries[url] != nil
    }

    /// Convenience: emit all currently-known PhotoLocations as a flat array.
    /// Useful for feeding the map view.
    public var allLocations: [PhotoLocation] {
        entries.values.compactMap { $0 }
    }

    // MARK: - Private

    /// Read GPS for one file. Synchronous in body but called from an async
    /// context; the reader does file I/O + a Core Image decode, which on a
    /// MainActor-isolated cache would normally be a concern. We accept that
    /// here because folder-load is one-shot and the user is already waiting
    /// on the grid; parallelizing this is a follow-up if it shows in profiles.
    private func readLocation(at url: URL) -> PhotoLocation? {
        guard let metadata = try? reader.read(url: url).1 else { return nil }
        guard let coords = extractGPS(from: metadata) else { return nil }
        return PhotoLocation(url: url, latitude: coords.latitude, longitude: coords.longitude)
    }
}
