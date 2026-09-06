import Foundation
import XCTest
@testable import PhotoIO

final class FolderPathMapperTests: XCTestCase {
    func testDarwinPrivateAliasesStayRelativeAndRebaseToSelectedRoot() throws {
        let root = URL(fileURLWithPath: "/tmp/latent-path-map-fixture", isDirectory: true)
        let mapper = FolderPathMapper(rootURL: root)
        let privateChild = URL(
            fileURLWithPath: "/private/tmp/latent-path-map-fixture/nested/photo.jpg"
        )

        XCTAssertEqual(mapper.relativePath(of: privateChild), "nested/photo.jpg")
        XCTAssertEqual(
            mapper.rebaseToRoot(privateChild).path,
            "/tmp/latent-path-map-fixture/nested/photo.jpg"
        )
        XCTAssertEqual(
            mapper.url(forRelativePath: "nested/photo.jpg")?.path,
            "/tmp/latent-path-map-fixture/nested/photo.jpg"
        )

        let privateRoot = URL(
            fileURLWithPath: "/private/tmp/latent-path-map-fixture",
            isDirectory: true
        )
        let privateMapper = FolderPathMapper(rootURL: privateRoot)
        let shortChild = URL(
            fileURLWithPath: "/tmp/latent-path-map-fixture/nested/photo.jpg"
        )
        XCTAssertEqual(privateMapper.rootPath, privateRoot.path)
        XCTAssertEqual(privateMapper.relativePath(of: shortChild), "nested/photo.jpg")
        XCTAssertEqual(
            privateMapper.rebaseToRoot(shortChild).path,
            "/private/tmp/latent-path-map-fixture/nested/photo.jpg"
        )

        let varMapper = FolderPathMapper(
            rootURL: URL(fileURLWithPath: "/var/folders/latent-fixture", isDirectory: true)
        )
        XCTAssertEqual(
            varMapper.relativePath(of: URL(
                fileURLWithPath: "/private/var/folders/latent-fixture/photo.png"
            )),
            "photo.png"
        )
        XCTAssertNil(mapper.url(forRelativePath: "/private/tmp/outside.jpg"))
        XCTAssertNil(mapper.url(forRelativePath: "../outside.jpg"))
    }

    func testResolvedSymlinkRootEnumeratesDirectAndRecursiveChildren() throws {
        let suffix = UUID().uuidString
        let target = URL(
            fileURLWithPath: "/tmp/latent-path-target-\(suffix)",
            isDirectory: true
        )
        let link = URL(
            fileURLWithPath: "/tmp/latent-path-link-\(suffix)",
            isDirectory: true
        )
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: target)
        }

        let nested = target.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data([1]).write(to: target.appendingPathComponent("direct.jpg"))
        try Data([2]).write(to: nested.appendingPathComponent("deep.jpg"))
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let mapper = FolderPathMapper(rootURL: link)
        XCTAssertTrue(try mapper.enumerationRootURL.resourceValues(
            forKeys: [.isDirectoryKey]
        ).isDirectory == true)

        let direct = try FileManager.default.contentsOfDirectory(
            at: mapper.enumerationRootURL,
            includingPropertiesForKeys: nil
        ).map { mapper.rebaseToRoot($0) }
        XCTAssertTrue(direct.contains { $0.path == link.appendingPathComponent("direct.jpg").path })

        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: mapper.enumerationRootURL,
            includingPropertiesForKeys: nil
        ))
        let recursive = enumerator.compactMap { entry in
            (entry as? URL).map { mapper.rebaseToRoot($0) }
        }
        XCTAssertTrue(recursive.contains {
            $0.path == link.appendingPathComponent("nested/deep.jpg").path
        })
    }
}
