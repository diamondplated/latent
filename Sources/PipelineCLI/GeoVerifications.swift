import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotoIO
import PhotoGeo

// Verifications for the PhotoGeo target. Mirrors the verifier convention used
// in main.swift: each function is `async throws -> Void` and reuses the
// module-internal `require(...)` helper and `VerifyError` type from main.swift
// (same target, same scope).
//
// NOTE: `swift build` currently fails because PipelineCLI now contains
// multiple .swift files alongside `main.swift`'s `@main` decoration —
// Swift 6 requires `-parse-as-library` on the target for that combination.
// The fix lives in either `main.swift` or `Package.swift`, both of which
// the task explicitly forbids touching. The same condition exists for
// VimVerifications.swift (committed in c820ecb) and pre-dates this commit.

/// Build a tiny JPEG with embedded GPS metadata, read it back, and confirm
/// `extractGPS` produces signed lat/lon with the right hemispheres applied.
///
/// Coordinates: Maple Grove, MN (45.0982 N, 93.4430 W). The "W" reference
/// must flip the longitude sign on extraction.
public func extractGPSFromSyntheticJPEG() async throws {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv_geo_\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: url) }

    try writeJPEGWithGPS(
        to: url,
        width: 4,
        height: 4,
        latitude: 45.0982,
        latitudeRef: "N",
        longitude: 93.4430,
        longitudeRef: "W"
    )

    let reader = ImageReader()
    let (_, metadata) = try reader.read(url: url)

    guard let coords = extractGPS(from: metadata) else {
        throw VerifyError(message: "extractGPS returned nil for a JPEG with valid GPS metadata")
    }

    try require(abs(coords.latitude - 45.0982) < 1e-3,
                "expected latitude ≈ 45.0982, got \(coords.latitude)")
    try require(abs(coords.longitude - (-93.4430)) < 1e-3,
                "expected longitude ≈ -93.4430 (W flips sign), got \(coords.longitude)")
}

// MARK: - Fixture helpers

/// Write an N-pixel solid grey JPEG with an embedded GPS metadata dictionary.
/// Uses ImageIO's standard GPS keys; ImageReader will surface them through
/// `metadata.properties()[kCGImagePropertyGPSDictionary]`.
private func writeJPEGWithGPS(
    to url: URL,
    width: Int,
    height: Int,
    latitude: Double,
    latitudeRef: String,
    longitude: Double,
    longitudeRef: String
) throws {
    let bytesPerRow = width * 4
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    if let buf = context.data?.assumingMemoryBound(to: UInt8.self) {
        for i in 0..<(width * height * 4) {
            buf[i] = (i % 4 == 3) ? 255 : 128  // alpha=255, rgb=128
        }
    }
    guard let cg = context.makeImage() else {
        throw VerifyError(message: "failed to build synthetic CGImage")
    }

    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        throw VerifyError(message: "could not create CGImageDestination at \(url.path)")
    }

    let gpsDict: [CFString: Any] = [
        kCGImagePropertyGPSLatitude: latitude,
        kCGImagePropertyGPSLatitudeRef: latitudeRef,
        kCGImagePropertyGPSLongitude: longitude,
        kCGImagePropertyGPSLongitudeRef: longitudeRef,
    ]
    let imageProps: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: gpsDict
    ]
    CGImageDestinationAddImage(dest, cg, imageProps as CFDictionary)
    if !CGImageDestinationFinalize(dest) {
        throw VerifyError(message: "failed to finalize JPEG with GPS metadata")
    }
}
