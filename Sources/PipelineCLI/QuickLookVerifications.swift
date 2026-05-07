import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotoQuickLook

// MARK: - QuickLookRenderer verifications
//
// Companion to QuickLookRenderer. Lives in PipelineCLI alongside Vim/Geo
// verifications so all UI-adjacent libraries get exercised by `pv-pipeline`
// without dragging Xcode into the loop.

public func quickLookRenderRespectsMaxDimension() async throws {
    // Synthesize a 200×120 JPEG; renderer cap at 96; expect both dims ≤ 96.
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("ql_renderer_\(UUID().uuidString).jpg")
    defer { try? FileManager.default.removeItem(at: url) }

    let cg = makeQLFixtureImage(width: 200, height: 120)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, cg, nil)
    if !CGImageDestinationFinalize(dest) {
        throw VerifyError(message: "failed to write QL fixture JPEG")
    }

    let renderer = QuickLookRenderer(maxDimension: 96)
    let preview = try renderer.render(url: url)
    try require(preview.width <= 96 && preview.height <= 96,
                "expected both dims ≤ 96, got \(preview.width)×\(preview.height)")
    try require(preview.width > 0 && preview.height > 0,
                "preview should have positive dimensions")
}

public func quickLookRenderRejectsUnsupported() async throws {
    // .txt isn't an image — renderer should refuse fast (cheap pre-filter
    // before hitting CGImageSourceCreate).
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("not_an_image_\(UUID().uuidString).txt")
    try "definitely not a JPEG".write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    let renderer = QuickLookRenderer(maxDimension: 256)
    do {
        _ = try renderer.render(url: url)
        throw VerifyError(message: "expected unsupportedType, got success")
    } catch let err as QuickLookRendererError {
        if case .unsupportedType = err { return }
        throw VerifyError(message: "wrong error variant: \(err)")
    }
}

private func makeQLFixtureImage(width: Int, height: Int) -> CGImage {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    ctx.setFillColor(red: 0.5, green: 0.6, blue: 0.7, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}
