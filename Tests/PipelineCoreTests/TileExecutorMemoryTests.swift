import Foundation
import XCTest
@testable import PipelineCore
@testable import PhotoML

private struct UnexpectedProcessError: Error {}

final class TileExecutorMemoryTests: XCTestCase {
    func testRejectsOversizedSingleTileBeforeCallingModel() async throws {
        let input = ImageBuffer(
            width: 2,
            height: 2,
            format: .working,
            pixels: Data(count: 2 * 2 * ImageFormat.working.bytesPerPixel)
        )
        let executor = TileExecutor(
            tileSize: 2,
            overlap: 0,
            scale: 2,
            maxWorkingMemoryBytes: 447
        )

        do {
            _ = try await executor.execute(input: input) { _ in
                throw UnexpectedProcessError()
            }
            XCTFail("expected an output-too-large error")
        } catch let error as TileExecutorError {
            guard case .outputTooLarge = error else {
                return XCTFail("unexpected TileExecutor error: \(error)")
            }
        }
    }

    func testRejectsOversizedOutputBeforeProcessingTiles() async throws {
        let input = ImageBuffer(
            width: 3,
            height: 3,
            format: .working,
            pixels: Data(count: 3 * 3 * ImageFormat.working.bytesPerPixel)
        )
        let executor = TileExecutor(
            tileSize: 2,
            overlap: 0,
            scale: 2,
            maxWorkingMemoryBytes: 1_000
        )

        do {
            _ = try await executor.execute(input: input) { _ in
                throw UnexpectedProcessError()
            }
            XCTFail("expected an output-too-large error")
        } catch let error as TileExecutorError {
            guard case .outputTooLarge(let width, let height, let estimatedBytes, let maxBytes) = error else {
                return XCTFail("unexpected TileExecutor error: \(error)")
            }
            XCTAssertEqual(width, 6)
            XCTAssertEqual(height, 6)
            XCTAssertEqual(estimatedBytes, 1_008)
            XCTAssertEqual(maxBytes, 1_000)
            XCTAssertTrue(error.description.contains("lower scale"))
        }
    }
}
