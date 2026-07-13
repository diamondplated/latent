import XCTest
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import PhotoIO

final class ArchiveExtractorTests: XCTestCase {
    func testRunProcessDrainsLargeOutput() async {
        let command = """
        i=0
        while [ "$i" -lt 70000 ]; do printf o; i=$((i + 1)); done
        i=0
        while [ "$i" -lt 70000 ]; do printf e >&2; i=$((i + 1)); done
        exit 7
        """

        do {
            try await ArchiveExtractor().runProcess(
                tool: "/bin/sh",
                args: ["-c", command],
                inputArchive: URL(fileURLWithPath: "/tmp/large-output.zip")
            )
            XCTFail("Expected the process to fail")
        } catch let ArchiveError.extractionFailed(_, code, stderr) {
            XCTAssertEqual(code, 7)
            XCTAssertEqual(stderr.utf8.count, 70_000)
        } catch {
            XCTFail("Unexpected error: \(error)")
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
