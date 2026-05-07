import Foundation
import PipelineCore
import EnhancementStages
import PhotoIO

// Real-photo smoke test. Gated by PV_TEST_FOLDER so it only runs when
// pointed at an actual folder of images — otherwise CI / unit-test runs
// stay deterministic and offline.

func realPhotoFolderRoundTrip(folder: URL) async throws {
    let fm = FileManager.default
    let extensions: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tif", "tiff"]
    guard let items = try? fm.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
        options: [.skipsHiddenFiles]
    ) else {
        throw VerifyError(message: "could not list \(folder.path)")
    }
    let photos = items.filter { extensions.contains($0.pathExtension.lowercased()) }
    try require(!photos.isEmpty, "no images in \(folder.path)")

    let reader = ImageReader()
    let writer = ImageWriter()
    let cache = IntermediateCache(maxBytes: 256 * 1024 * 1024)

    var totalReadMs = 0.0
    var totalPipelineMs = 0.0
    var totalWriteMs = 0.0
    var smallestSec = Double.greatestFiniteMagnitude
    var largestSec = 0.0
    var smallestName = ""
    var largestName = ""

    print("    testing \(photos.count) photo(s) in \(folder.lastPathComponent)…")

    for url in photos {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let bytes = (attrs?[.size] as? Int) ?? 0

        // 1. Read
        let t0 = Date()
        let (buffer, metadata) = try reader.read(url: url)
        let readMs = Date().timeIntervalSince(t0) * 1000
        totalReadMs += readMs

        try require(buffer.width > 0 && buffer.height > 0,
                    "zero dim from \(url.lastPathComponent)")

        // 2. Pipeline (default: 5 stages; Sharpen runs CIUnsharpMask, Upscale
        // runs Lanczos 2x because no .mlpackage installed, others are identity)
        let pipeline = Pipeline(steps: StandardPipeline.defaultSteps(), cache: cache)
        let t1 = Date()
        let output = try await pipeline.run(input: buffer)
        let pipelineMs = Date().timeIntervalSince(t1) * 1000
        totalPipelineMs += pipelineMs

        // Upscale.scale=2 → output dims should be 2x (or 4x if scale=4)
        let expectedW = buffer.width * 2
        let expectedH = buffer.height * 2
        try require(output.width == expectedW && output.height == expectedH,
                    "\(url.lastPathComponent): expected \(expectedW)×\(expectedH), got \(output.width)×\(output.height)")

        // 3. Write to a temp file and re-read
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pv_real_\(UUID().uuidString).\(url.pathExtension)")
        defer { try? fm.removeItem(at: tmp) }

        let t2 = Date()
        try writer.write(buffer: output, metadata: metadata, to: tmp)
        let writeMs = Date().timeIntervalSince(t2) * 1000
        totalWriteMs += writeMs

        let (readBack, _) = try reader.read(url: tmp)
        try require(readBack.width == expectedW && readBack.height == expectedH,
                    "\(url.lastPathComponent): round-trip dims wrong: \(readBack.width)×\(readBack.height)")

        let totalSec = (readMs + pipelineMs + writeMs) / 1000
        if totalSec < smallestSec { smallestSec = totalSec; smallestName = url.lastPathComponent }
        if totalSec > largestSec { largestSec = totalSec; largestName = url.lastPathComponent }

        print(String(format: "      %@  %dx%d  %.1fMB  read=%.0fms pipe=%.0fms write=%.0fms",
                     url.lastPathComponent, buffer.width, buffer.height,
                     Double(bytes) / 1_000_000, readMs, pipelineMs, writeMs))
    }

    print(String(format: "    totals: %.0fms read, %.0fms pipeline, %.0fms write across %d photos",
                 totalReadMs, totalPipelineMs, totalWriteMs, photos.count))
    print(String(format: "    fastest: %@ (%.2fs); slowest: %@ (%.2fs)",
                 smallestName, smallestSec, largestName, largestSec))
}
