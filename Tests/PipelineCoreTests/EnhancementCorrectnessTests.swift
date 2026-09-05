import XCTest
import Foundation
@testable import PipelineCore
@testable import EnhancementStages
@testable import PhotoML

private func makeWorkingBuffer(
    width: Int,
    height: Int,
    pixels: [[Float]]
) -> ImageBuffer {
    precondition(pixels.count == width * height)
    var data = Data(count: width * height * ImageFormat.working.bytesPerPixel)
    data.withUnsafeMutableBytes { raw in
        let destination = raw.bindMemory(to: Float16.self).baseAddress!
        for (pixelIndex, pixel) in pixels.enumerated() {
            precondition(pixel.count == 4)
            for channel in 0..<4 {
                destination[pixelIndex * 4 + channel] = Float16(pixel[channel])
            }
        }
    }
    return ImageBuffer(width: width, height: height, format: .working, pixels: data)
}

private func workingPixels(_ buffer: ImageBuffer) -> [[Float]] {
    buffer.pixels.withUnsafeBytes { raw in
        let source = raw.bindMemory(to: Float16.self).baseAddress!
        return (0..<(buffer.width * buffer.height)).map { pixel in
            (0..<4).map { channel in Float(source[pixel * 4 + channel]) }
        }
    }
}

final class EnhancementParameterCorrectnessTests: XCTestCase {
    func testRestorationStrengthBlendsRGBAndPreservesOriginalAlpha() throws {
        let original = makeWorkingBuffer(
            width: 1,
            height: 1,
            pixels: [[0.10, 0.20, 0.30, 0.50]]
        )
        // Deliberately use a different result alpha to prove an RGB restoration
        // cannot overwrite source transparency.
        let processed = makeWorkingBuffer(
            width: 1,
            height: 1,
            pixels: [[0.40, 0.10, 0.00, 1.00]]
        )

        let output = try blendRestoration(
            original: original,
            processed: processed,
            strength: 0.25
        )
        let pixel = workingPixels(output)[0]

        XCTAssertEqual(pixel[0], 0.175, accuracy: 0.001)
        XCTAssertEqual(pixel[1], 0.175, accuracy: 0.001)
        XCTAssertEqual(pixel[2], 0.225, accuracy: 0.001)
        XCTAssertEqual(pixel[3], 0.500, accuracy: 0.001)
    }

    func testDenoiseDetailBiasProtectsEdgesButStillProcessesFlatAreas() throws {
        let original = makeWorkingBuffer(
            width: 5,
            height: 1,
            pixels: [
                [0.20, 0.20, 0.20, 1],
                [0.20, 0.20, 0.20, 1],
                [0.80, 0.80, 0.80, 1],
                [0.80, 0.80, 0.80, 1],
                [0.80, 0.80, 0.80, 1],
            ]
        )
        let denoised = makeWorkingBuffer(
            width: 5,
            height: 1,
            pixels: Array(repeating: [0.50, 0.50, 0.50, 1], count: 5)
        )

        let output = try blendRestoration(
            original: original,
            processed: denoised,
            strength: 1,
            preserveDetailBias: 1
        )
        let pixels = workingPixels(output)

        XCTAssertEqual(pixels[0][0], 0.50, accuracy: 0.001, "flat dark region should be denoised")
        XCTAssertEqual(pixels[2][0], 0.80, accuracy: 0.001, "high-contrast edge should be protected")
        XCTAssertEqual(pixels[4][0], 0.50, accuracy: 0.001, "flat light region should be denoised")
    }

    func testSharpenThresholdRejectsSmallHighPassAndKeepsLargeHighPass() throws {
        let original = makeWorkingBuffer(
            width: 2,
            height: 1,
            pixels: [
                [0.10, 0.10, 0.10, 0.50],
                [0.10, 0.10, 0.10, 0.50],
            ]
        )
        let sharpened = makeWorkingBuffer(
            width: 2,
            height: 1,
            pixels: [
                [0.11, 0.11, 0.11, 1.00], // straight delta 0.02: below threshold
                [0.20, 0.20, 0.20, 1.00], // straight delta 0.20: above threshold
            ]
        )

        let output = try applySharpenThreshold(
            original: original,
            sharpened: sharpened,
            amount: 1,
            threshold: 0.05
        )
        let pixels = workingPixels(output)

        XCTAssertEqual(pixels[0][0], 0.10, accuracy: 0.001)
        XCTAssertEqual(pixels[1][0], 0.20, accuracy: 0.001)
        XCTAssertEqual(pixels[0][3], 0.50, accuracy: 0.001)
        XCTAssertEqual(pixels[1][3], 0.50, accuracy: 0.001)
    }

    func testLegacyArtifactQualityHintDecodesButIsNoLongerPersisted() throws {
        let legacy = Data(#"{"strength":0.4,"qualityHint":35}"#.utf8)
        let decoded = try JSONDecoder().decode(ArtifactRemoval.Params.self, from: legacy)
        XCTAssertEqual(decoded.strength, 0.4, accuracy: 0.0001)

        let encoded = try JSONEncoder().encode(decoded)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(object["qualityHint"])
    }
}

final class ModelTensorConversionTests: XCTestCase {
    func testSRGBTransferFunctionMatchesReferencePoints() {
        XCTAssertEqual(ModelTensorConverter.linearToSRGB(0.0031308), 0.04045, accuracy: 0.00001)
        XCTAssertEqual(ModelTensorConverter.linearToSRGB(0.21404114), 0.5, accuracy: 0.00001)
        XCTAssertEqual(ModelTensorConverter.sRGBToLinear(0.04045), 0.0031308, accuracy: 0.00001)
        XCTAssertEqual(ModelTensorConverter.sRGBToLinear(0.5), 0.21404114, accuracy: 0.00001)
    }

    func testInputConversionUnpremultipliesAppliesTransferRangeAndBGRLayout() throws {
        // Straight RGB is (0.214041, 0.033105, 1.0), premultiplied by alpha 0.5.
        // Its sRGB representation is approximately (0.5, 0.2, 1.0).
        let input = makeWorkingBuffer(
            width: 1,
            height: 1,
            pixels: [[0.10702057, 0.01655242, 0.5, 0.5]]
        )
        let spec = TensorSpec(
            inputName: "input",
            outputName: "output",
            channelOrder: .bgr,
            layout: .nchw,
            inputRange: (-1, 1),
            inputTransferFunction: .sRGB
        )

        let values = try ModelTensorConverter.makeInputValues(from: input, spec: spec)

        XCTAssertEqual(values[0], 1.0, accuracy: 0.002)  // B
        XCTAssertEqual(values[1], -0.6, accuracy: 0.002) // G
        XCTAssertEqual(values[2], 0.0, accuracy: 0.002)  // R
    }

    func testOutputConversionDecodesSRGBAndPreservesResampledAlpha() throws {
        let source = makeWorkingBuffer(
            width: 2,
            height: 1,
            pixels: [
                [0, 0, 0, 0],
                [0.5, 0.5, 0.5, 1],
            ]
        )
        let spec = TensorSpec(
            inputName: "input",
            outputName: "output",
            channelOrder: .rgb,
            layout: .nhwc,
            outputTransferFunction: .sRGB
        )
        let tensor = CoreMLImageModel.TensorOutput(
            values: Array(repeating: 0.5, count: 4 * 3),
            shape: [1, 1, 4, 3]
        )

        let output = try ModelTensorConverter.makeImageBuffer(
            from: tensor,
            preservingAlphaFrom: source,
            spec: spec
        )
        let pixels = workingPixels(output)
        let expectedAlpha: [Float] = [0, 0.25, 0.75, 1]
        let decodedGray: Float = 0.21404114

        for index in pixels.indices {
            XCTAssertEqual(pixels[index][3], expectedAlpha[index], accuracy: 0.001)
            XCTAssertEqual(pixels[index][0], decodedGray * expectedAlpha[index], accuracy: 0.001)
            XCTAssertEqual(pixels[index][1], decodedGray * expectedAlpha[index], accuracy: 0.001)
            XCTAssertEqual(pixels[index][2], decodedGray * expectedAlpha[index], accuracy: 0.001)
        }
    }

    func testImageTensorRejectsMismatchedValueCountInsteadOfReadingPastEnd() {
        let source = makeWorkingBuffer(width: 1, height: 1, pixels: [[0, 0, 0, 1]])
        let malformed = CoreMLImageModel.TensorOutput(values: [0, 0], shape: [1, 3, 1, 1])

        XCTAssertThrowsError(
            try ModelTensorConverter.makeImageBuffer(
                from: malformed,
                preservingAlphaFrom: source,
                spec: .realESRGANx2
            )
        )
    }
}
