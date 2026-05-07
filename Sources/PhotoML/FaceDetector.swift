import Foundation
import Vision
import CoreGraphics
import CoreImage
import PipelineCore

/// One detected face in an image.
public struct DetectedFace: Sendable {
    /// Pixel-coordinate bounds in the source `ImageBuffer` (origin top-left).
    public let bounds: CGRect
    public let confidence: Float

    public init(bounds: CGRect, confidence: Float) {
        self.bounds = bounds
        self.confidence = confidence
    }
}

public enum FaceDetectorError: Error, CustomStringConvertible {
    case visionRequestFailed(any Error)
    case bridgeError(any Error)

    public var description: String {
        switch self {
        case .visionRequestFailed(let err): "Vision face detection failed: \(err)"
        case .bridgeError(let err): "Image bridge failed: \(err)"
        }
    }
}

/// Wraps Apple's `VNDetectFaceRectanglesRequest`. Returns face bounding boxes
/// in pixel coordinates (top-left origin) for direct use with `ImageBuffer`
/// cropping. Vision's native coordinates are normalized [0,1] with bottom-left
/// origin — we flip and scale here so callers don't have to think about it.
public struct FaceDetector: Sendable {
    public init() {}

    public func detect(in buffer: ImageBuffer) async throws -> [DetectedFace] {
        let cgImage: CGImage
        do {
            cgImage = try buffer.makeCGImage()
        } catch {
            throw FaceDetectorError.bridgeError(error)
        }

        let request = VNDetectFaceRectanglesRequest()
        request.revision = VNDetectFaceRectanglesRequestRevision3
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            throw FaceDetectorError.visionRequestFailed(error)
        }

        let observations = request.results ?? []
        return observations.map { obs in
            // Vision returns normalized (x, y, w, h) in bottom-left origin.
            // Convert to top-left pixel coordinates of the working buffer.
            let w = CGFloat(buffer.width)
            let h = CGFloat(buffer.height)
            let bx = obs.boundingBox.origin.x * w
            let bw = obs.boundingBox.size.width * w
            let bh = obs.boundingBox.size.height * h
            let by = h - (obs.boundingBox.origin.y * h) - bh  // flip Y
            return DetectedFace(
                bounds: CGRect(x: bx, y: by, width: bw, height: bh),
                confidence: obs.confidence
            )
        }
    }
}
