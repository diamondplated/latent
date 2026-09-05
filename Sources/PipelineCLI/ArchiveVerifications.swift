import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import PhotoIO

// MARK: - ArchiveExtractor verifications

public func archiveDetectsCommonFormats() async throws {
    // Pure-string detection — no I/O needed, fast smoke test.
    let cases: [(String, ArchiveFormat?)] = [
        ("photos.zip", .zip),
        ("photos.tar", .tar),
        ("photos.tar.gz", .tarGz),
        ("photos.tgz", .tarGz),
        ("photos.tar.bz2", .tarBz2),
        ("photos.tbz2", .tarBz2),
        ("photos.tar.xz", .tarXz),
        ("photos.txz", .tarXz),
        ("photos.jpg", nil),
        ("not_an_archive", nil),
        // Compound extension precedence: must NOT mis-detect "tar.gz" as "tar".
        ("foo.tar.gz", .tarGz),
    ]
    for (name, expected) in cases {
        let url = URL(fileURLWithPath: "/tmp").appendingPathComponent(name)
        let got = ArchiveFormat.detect(from: url)
        try require(got == expected, "detect('\(name)'): expected \(String(describing: expected)), got \(String(describing: got))")
    }
}

public func archiveExtractRoundTripZip() async throws {
    // Build a tiny zip by:
    //   1. Synthesizing two JPEGs in a temp source dir (one in a subdir).
    //   2. Calling /usr/bin/zip to compress them.
    //   3. Extracting via ArchiveExtractor.
    //   4. Asserting both files exist at the expected relative paths.
    let fm = FileManager.default
    let runID = UUID().uuidString
    let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv-archive-test-\(runID)", isDirectory: true)
    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: workDir) }

    let sourceDir = workDir.appendingPathComponent("photos", isDirectory: true)
    let nestedDir = sourceDir.appendingPathComponent("vacation", isDirectory: true)
    try fm.createDirectory(at: nestedDir, withIntermediateDirectories: true)

    let topURL = sourceDir.appendingPathComponent("top.jpg")
    let nestedURL = nestedDir.appendingPathComponent("beach.jpg")
    try writeTinyJPEG(width: 8, height: 8, to: topURL)
    try writeTinyJPEG(width: 16, height: 8, to: nestedURL)

    // /usr/bin/zip ships with macOS. -r for recursive, -q for quiet.
    let zipURL = workDir.appendingPathComponent("photos.zip")
    let zipProcess = Process()
    zipProcess.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
    zipProcess.currentDirectoryURL = workDir
    zipProcess.arguments = ["-rq", zipURL.path, "photos"]
    zipProcess.standardOutput = Pipe()
    zipProcess.standardError = Pipe()
    try zipProcess.run()
    zipProcess.waitUntilExit()
    try require(zipProcess.terminationStatus == 0, "zip exited \(zipProcess.terminationStatus)")
    try require(fm.fileExists(atPath: zipURL.path), "zip didn't write \(zipURL.path)")

    // Extract via the actor.
    let extractor = ArchiveExtractor()
    let extractedDir = try await extractor.extract(zipURL)
    defer { Task { await extractor.cleanup(extractedDir) } }

    let extractedTop = extractedDir.appendingPathComponent("photos/top.jpg")
    let extractedNested = extractedDir.appendingPathComponent("photos/vacation/beach.jpg")
    try require(fm.fileExists(atPath: extractedTop.path), "missing extracted top.jpg at \(extractedTop.path)")
    try require(fm.fileExists(atPath: extractedNested.path), "missing extracted nested beach.jpg at \(extractedNested.path)")

    // The extracted files should still be valid JPEGs we can read.
    let topAttrs = try fm.attributesOfItem(atPath: extractedTop.path)
    let topSize = (topAttrs[.size] as? Int) ?? 0
    try require(topSize > 0, "extracted top.jpg is empty")
}

public func archiveExtractRejectsBadFormat() async throws {
    let extractor = ArchiveExtractor()
    let bogus = URL(fileURLWithPath: "/tmp/not-an-archive.foo")
    do {
        _ = try await extractor.extract(bogus)
        throw VerifyError(message: "expected unsupportedFormat error, got success")
    } catch let err as ArchiveError {
        if case .unsupportedFormat = err { return }
        throw VerifyError(message: "wrong ArchiveError variant: \(err)")
    }
}

public func archiveRejectsEscapingSymlink() async throws {
    let fm = FileManager.default
    let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv-archive-symlink-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: workDir) }

    let payload = workDir.appendingPathComponent("payload", isDirectory: true)
    try fm.createDirectory(at: payload, withIntermediateDirectories: true)
    try fm.createSymbolicLink(
        atPath: payload.appendingPathComponent("escape").path,
        withDestinationPath: "../../outside-latent-archive-test"
    )

    let archive = workDir.appendingPathComponent("escaping-link.tar")
    try runArchiveFixtureTool(
        "/usr/bin/tar",
        arguments: ["-cf", archive.path, "-C", workDir.path, "payload"]
    )

    let extractor = ArchiveExtractor()
    do {
        let extracted = try await extractor.extract(archive)
        await extractor.cleanup(extracted)
        throw VerifyError(message: "expected escaping symlink to be rejected")
    } catch ArchiveError.unsafeArchive {
        // Expected: the extracted link resolves outside the private temp root.
    }
}

public func archiveRejectsExpandedFileOverLimit() async throws {
    let fm = FileManager.default
    let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("pv-archive-limit-test-\(UUID().uuidString)", isDirectory: true)
    try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: workDir) }

    let payload = workDir.appendingPathComponent("large.jpg")
    try Data(repeating: 0x5a, count: 4_096).write(to: payload)
    let archive = workDir.appendingPathComponent("oversized.tar")
    try runArchiveFixtureTool(
        "/usr/bin/tar",
        arguments: ["-cf", archive.path, "-C", workDir.path, payload.lastPathComponent]
    )

    let limits = ArchiveExtractionLimits(
        maximumExpandedBytes: 1_024,
        maximumSingleFileBytes: 1_024,
        pollInterval: 0.01
    )
    let extractor = ArchiveExtractor(limits: limits)
    do {
        let extracted = try await extractor.extract(archive)
        await extractor.cleanup(extracted)
        throw VerifyError(message: "expected expanded-size limit to be enforced")
    } catch ArchiveError.resourceLimitExceeded {
        // Expected.
    }
}

// MARK: - Helpers

private func runArchiveFixtureTool(_ tool: String, arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = arguments
    let stderr = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
        let message = String(decoding: stderr.fileHandleForReading.availableData, as: UTF8.self)
        throw VerifyError(message: "fixture tool failed (exit \(process.terminationStatus)): \(message)")
    }
}

private func writeTinyJPEG(width: Int, height: Int, to url: URL) throws {
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
    ctx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let cg = ctx.makeImage()!
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else {
        throw VerifyError(message: "can't open destination for \(url.path)")
    }
    CGImageDestinationAddImage(dest, cg, nil)
    if !CGImageDestinationFinalize(dest) {
        throw VerifyError(message: "couldn't finalize fixture jpeg")
    }
}
