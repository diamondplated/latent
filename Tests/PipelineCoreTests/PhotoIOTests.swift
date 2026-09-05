import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PipelineCore
@testable import PhotoIO

final class ArchiveExtractorTests: XCTestCase {
    func testRunProcessBoundsLargeDiagnosticOutput() async {
        let command = """
        i=0
        while [ "$i" -lt 70000 ]; do printf o; i=$((i + 1)); done
        i=0
        while [ "$i" -lt 70000 ]; do printf e >&2; i=$((i + 1)); done
        exit 7
        """
        let extractor = ArchiveExtractor(limits: ArchiveExtractionLimits(maximumDiagnosticBytes: 1_024))

        do {
            try await extractor.runProcess(
                tool: "/bin/sh",
                args: ["-c", command],
                inputArchive: URL(fileURLWithPath: "/tmp/large-output.zip")
            )
            XCTFail("Expected the process to fail")
        } catch let ArchiveError.extractionFailed(_, code, stderr) {
            XCTAssertEqual(code, 7)
            XCTAssertLessThan(stderr.utf8.count, 1_100)
            XCTAssertTrue(stderr.hasPrefix("e"))
            XCTAssertTrue(stderr.contains("diagnostic output truncated"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunProcessTimesOutAndTerminatesTool() async {
        let extractor = ArchiveExtractor(limits: ArchiveExtractionLimits(timeout: 0.05, pollInterval: 0.01))
        do {
            try await extractor.runProcess(
                tool: "/bin/sleep",
                args: ["5"],
                inputArchive: URL(fileURLWithPath: "/tmp/slow.zip")
            )
            XCTFail("Expected timeout")
        } catch ArchiveError.extractionTimedOut {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRunProcessRespondsToTaskCancellation() async {
        let extractor = ArchiveExtractor(limits: ArchiveExtractionLimits(pollInterval: 0.01))
        let task = Task {
            try await extractor.runProcess(
                tool: "/bin/sleep",
                args: ["5"],
                inputArchive: URL(fileURLWithPath: "/tmp/cancelled.zip")
            )
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()

        do {
            try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testMemberPathValidationRejectsTraversalAndAbsolutePaths() throws {
        let archive = URL(fileURLWithPath: "/tmp/paths.zip")
        XCTAssertNoThrow(try ArchiveExtractor.validateMemberPath("photos/2026/image.jpg", archiveURL: archive))

        for unsafePath in ["../escape.jpg", "photos/../../escape.jpg", "/tmp/escape.jpg", "C:\\escape.jpg"] {
            XCTAssertThrowsError(try ArchiveExtractor.validateMemberPath(unsafePath, archiveURL: archive)) { error in
                guard case ArchiveError.unsafeArchive = error else {
                    return XCTFail("Expected unsafeArchive for \(unsafePath), got \(error)")
                }
            }
        }
    }

    func testFailedExtractionRemovesTemporaryDirectory() async throws {
        let fileManager = FileManager.default
        let temporaryDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let stem = "cleanup-\(UUID().uuidString)"
        let archive = temporaryDirectory.appendingPathComponent("\(stem).zip")
        let extractionPrefix = "pv-archive-\(stem)-"
        try Data("not a zip".utf8).write(to: archive)

        defer {
            try? fileManager.removeItem(at: archive)
            if let leftovers = try? fileManager.contentsOfDirectory(
                at: temporaryDirectory,
                includingPropertiesForKeys: nil
            ) {
                for url in leftovers where url.lastPathComponent.hasPrefix(extractionPrefix) {
                    try? fileManager.removeItem(at: url)
                }
            }
        }

        do {
            _ = try await ArchiveExtractor().extract(archive)
            XCTFail("Expected invalid archive extraction to fail")
        } catch {
            // Expected.
        }

        let leftovers = try fileManager.contentsOfDirectory(
            at: temporaryDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(extractionPrefix) }
        XCTAssertTrue(leftovers.isEmpty)
    }
}

final class ImageReaderTests: XCTestCase {
    func testPreviewAppliesExifOrientationAtFullResolution() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("oriented-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }

        try writeJPEG(width: 80, height: 40, orientation: 6, to: url)

        let preview = try XCTUnwrap(ImageReader.previewCGImage(url: url))
        XCTAssertEqual(preview.width, 40)
        XCTAssertEqual(preview.height, 80)
    }

    private func writeJPEG(width: Int, height: Int, orientation: Int, to url: URL) throws {
        let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(red: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(context.makeImage())
        let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(
            destination,
            image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary
        )
        XCTAssertTrue(CGImageDestinationFinalize(destination))
    }
}

final class ImageFileFormatTests: XCTestCase {
    func testPreferredFilenameExtensions() {
        XCTAssertEqual(ImageFileFormat.jpeg.preferredFilenameExtension, "jpg")
        XCTAssertEqual(ImageFileFormat.heic.preferredFilenameExtension, "heic")
        XCTAssertEqual(ImageFileFormat.png.preferredFilenameExtension, "png")
        XCTAssertEqual(ImageFileFormat.tiff.preferredFilenameExtension, "tiff")
    }
}

final class ImageWriterKeepBothTests: XCTestCase {
    func testAtomicExportKeepsExistingFileAndUsesNumberedSibling() throws {
        let fileManager = FileManager.default
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("latent-export-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: directory) }

        let preferred = directory.appendingPathComponent("portrait_enhanced.jpg")
        let sentinel = Data("existing export".utf8)
        try sentinel.write(to: preferred)

        let width = 4
        let height = 4
        let buffer = ImageBuffer(
            width: width,
            height: height,
            format: .working,
            pixels: Data(count: width * height * ImageFormat.working.bytesPerPixel)
        )
        let writer = ImageWriter()

        let second = try writer.writeKeepingBoth(buffer: buffer, metadata: nil, to: preferred)
        let third = try writer.writeKeepingBoth(buffer: buffer, metadata: nil, to: preferred)

        XCTAssertEqual(second.lastPathComponent, "portrait_enhanced 2.jpg")
        XCTAssertEqual(third.lastPathComponent, "portrait_enhanced 3.jpg")
        XCTAssertEqual(try Data(contentsOf: preferred), sentinel, "the previous export must not be replaced")
        XCTAssertTrue(fileManager.fileExists(atPath: second.path))
        XCTAssertTrue(fileManager.fileExists(atPath: third.path))

        let leftovers = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".latent-export-") }
        XCTAssertTrue(leftovers.isEmpty, "temporary export files should be removed after commit")
    }
}
