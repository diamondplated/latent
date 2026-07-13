import Foundation
import PipelineCore

public enum TileExecutorError: Error, CustomStringConvertible {
    case processProducedWrongSize(expected: (Int, Int), got: (Int, Int))
    case outputTooLarge(outputWidth: Int, outputHeight: Int, estimatedWorkingBytes: UInt64, maxWorkingBytes: UInt64)
    case outputDimensionsOverflow(inputWidth: Int, inputHeight: Int, scale: Int)
    case bufferAllocationFailed

    public var description: String {
        switch self {
        case .processProducedWrongSize(let expected, let got):
            return "process() returned \(got.0)x\(got.1), expected \(expected.0)x\(expected.1)"
        case .outputTooLarge(let width, let height, let estimatedBytes, let maxBytes):
            let estimated = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: estimatedBytes),
                countStyle: .memory
            )
            let maximum = ByteCountFormatter.string(
                fromByteCount: Int64(clamping: maxBytes),
                countStyle: .memory
            )
            return "Output \(width)x\(height) needs about \(estimated) of working memory; the safety limit is \(maximum). Use a smaller image or lower scale."
        case .outputDimensionsOverflow(let width, let height, let scale):
            return "Output dimensions for \(width)x\(height) at \(scale)x scale exceed the supported range. Use a smaller image or lower scale."
        case .bufferAllocationFailed:
            return "Failed to allocate output buffer"
        }
    }
}

/// Tiles a large `ImageBuffer`, runs a per-tile transform, blends results with
/// feathered alpha at overlap regions.
///
/// Used to apply CoreML models that have fixed-or-bounded input sizes to
/// arbitrary-resolution photos. Most super-resolution / denoise / face-restore
/// models are trained on 256–512px patches and break down or run out of memory
/// on full-resolution input — tiling with overlap-and-blend is the standard fix.
///
/// `process` receives an `ImageBuffer` of size up to `tileSize × tileSize` (edge
/// tiles may be smaller) and must return one of size `(input.w × scale, input.h × scale)`.
/// `scale = 1` for denoise/face-restore; `2` or `4` for upscalers.
///
/// Math is done in Float32 for precision, then quantized to Float16 for storage.
public struct TileExecutor: Sendable {
    /// Keep whole-output buffers below one eighth of physical memory, capped at 2 GiB.
    public static var defaultMaxWorkingMemoryBytes: UInt64 {
        min(ProcessInfo.processInfo.physicalMemory / 8, 2 * 1024 * 1024 * 1024)
    }

    public let tileSize: Int
    public let overlap: Int
    public let scale: Int
    public let maxWorkingMemoryBytes: UInt64

    public init(
        tileSize: Int = 512,
        overlap: Int = 32,
        scale: Int = 1,
        maxWorkingMemoryBytes: UInt64 = TileExecutor.defaultMaxWorkingMemoryBytes
    ) {
        precondition(tileSize > 0, "tileSize must be positive")
        precondition(overlap >= 0, "overlap must be non-negative")
        precondition(overlap * 2 < tileSize, "overlap (\(overlap)) must be less than half of tileSize (\(tileSize))")
        precondition(scale >= 1, "scale must be >= 1")
        precondition(maxWorkingMemoryBytes > 0, "maxWorkingMemoryBytes must be positive")
        self.tileSize = tileSize
        self.overlap = overlap
        self.scale = scale
        self.maxWorkingMemoryBytes = maxWorkingMemoryBytes
    }

    public func execute(
        input: ImageBuffer,
        progress: ProgressReporter = .noop,
        process: @Sendable (ImageBuffer) async throws -> ImageBuffer
    ) async throws -> ImageBuffer {
        precondition(input.format == .working, "TileExecutor requires working format")

        let (outWResult, widthOverflow) = input.width.multipliedReportingOverflow(by: scale)
        let (outHResult, heightOverflow) = input.height.multipliedReportingOverflow(by: scale)
        guard !widthOverflow, !heightOverflow else {
            throw TileExecutorError.outputDimensionsOverflow(
                inputWidth: input.width,
                inputHeight: input.height,
                scale: scale
            )
        }
        let outW = outWResult
        let outH = outHResult

        // Account for the Float32 RGBA accumulator, Float32 weights, and
        // Float16 RGBA output before either path asks a model for pixels.
        let (pixelCount64, pixelCountOverflow) = UInt64(outW).multipliedReportingOverflow(by: UInt64(outH))
        let bytesPerPixel = UInt64(MemoryLayout<Float>.size * 5 + ImageFormat.working.bytesPerPixel)
        let (estimatedBytes, byteCountOverflow) = pixelCount64.multipliedReportingOverflow(by: bytesPerPixel)
        guard !pixelCountOverflow,
              !byteCountOverflow,
              estimatedBytes <= maxWorkingMemoryBytes else {
            throw TileExecutorError.outputTooLarge(
                outputWidth: outW,
                outputHeight: outH,
                estimatedWorkingBytes: pixelCountOverflow || byteCountOverflow ? .max : estimatedBytes,
                maxWorkingBytes: maxWorkingMemoryBytes
            )
        }

        // Fast path: input fits in a single tile, no tiling needed.
        if input.width <= tileSize && input.height <= tileSize {
            progress.report(0.0)
            let output = try await process(input)
            guard output.width == outW, output.height == outH else {
                throw TileExecutorError.processProducedWrongSize(
                    expected: (outW, outH),
                    got: (output.width, output.height)
                )
            }
            progress.report(1.0)
            return output
        }

        // Compute tile grid.
        let stride = tileSize - overlap
        let tilesX = max(1, Int((Double(input.width - overlap) / Double(stride)).rounded(.up)))
        let tilesY = max(1, Int((Double(input.height - overlap) / Double(stride)).rounded(.up)))
        let totalTiles = tilesX * tilesY

        // Accumulator and weight buffers in Float32.
        let pixelCount = Int(pixelCount64)
        var accum = [Float](repeating: 0, count: pixelCount * 4)  // RGBA
        var weights = [Float](repeating: 0, count: pixelCount)

        var tileIndex = 0
        for ty in 0..<tilesY {
            for tx in 0..<tilesX {
                let tileX = min(tx * stride, input.width - tileSize)
                let tileY = min(ty * stride, input.height - tileSize)
                let actualX = max(0, tileX)
                let actualY = max(0, tileY)
                let tileW = min(tileSize, input.width - actualX)
                let tileH = min(tileSize, input.height - actualY)

                // Extract input tile.
                let tile = try extractTile(
                    from: input,
                    x: actualX, y: actualY,
                    width: tileW, height: tileH
                )

                // Process tile.
                let processed = try await process(tile)
                let expectedW = tileW * scale
                let expectedH = tileH * scale
                guard processed.width == expectedW, processed.height == expectedH else {
                    throw TileExecutorError.processProducedWrongSize(
                        expected: (expectedW, expectedH),
                        got: (processed.width, processed.height)
                    )
                }

                // Blend processed tile into accumulators with feathered alpha.
                blendTile(
                    tile: processed,
                    intoAccum: &accum,
                    weights: &weights,
                    outX: actualX * scale,
                    outY: actualY * scale,
                    outW: outW,
                    outH: outH,
                    isLeftEdge: tx == 0,
                    isRightEdge: tx == tilesX - 1,
                    isTopEdge: ty == 0,
                    isBottomEdge: ty == tilesY - 1
                )

                tileIndex += 1
                progress.report(Double(tileIndex) / Double(totalTiles))
            }
        }

        // Normalize accumulator by weights, convert to Float16 storage.
        var output = Data(count: pixelCount * MemoryLayout<Float16>.size * 4)
        output.withUnsafeMutableBytes { rawPtr in
            let outPtr = rawPtr.bindMemory(to: Float16.self).baseAddress!
            for p in 0..<pixelCount {
                let w = max(weights[p], 1e-6) // guard against div-by-zero in unreachable corners
                outPtr[p * 4 + 0] = Float16(accum[p * 4 + 0] / w)
                outPtr[p * 4 + 1] = Float16(accum[p * 4 + 1] / w)
                outPtr[p * 4 + 2] = Float16(accum[p * 4 + 2] / w)
                outPtr[p * 4 + 3] = Float16(accum[p * 4 + 3] / w)
            }
        }

        return ImageBuffer(width: outW, height: outH, format: .working, pixels: output)
    }

    /// Copy a sub-rectangle of `source` into a new ImageBuffer.
    private func extractTile(from source: ImageBuffer, x: Int, y: Int, width: Int, height: Int) throws -> ImageBuffer {
        precondition(x >= 0 && y >= 0)
        precondition(x + width <= source.width && y + height <= source.height)

        let bpp = source.format.bytesPerPixel
        let srcRowBytes = source.width * bpp
        let dstRowBytes = width * bpp
        var tileData = Data(count: dstRowBytes * height)

        source.pixels.withUnsafeBytes { srcRaw in
            tileData.withUnsafeMutableBytes { dstRaw in
                let src = srcRaw.bindMemory(to: UInt8.self).baseAddress!
                let dst = dstRaw.bindMemory(to: UInt8.self).baseAddress!
                for row in 0..<height {
                    let srcOffset = (y + row) * srcRowBytes + x * bpp
                    let dstOffset = row * dstRowBytes
                    memcpy(dst + dstOffset, src + srcOffset, dstRowBytes)
                }
            }
        }

        return ImageBuffer(width: width, height: height, format: source.format, pixels: tileData)
    }

    /// Add a processed tile to the accumulator with feathered alpha at overlap edges.
    /// Edges that touch the input border get full opacity (no fade) so the
    /// boundary pixels match the source exactly.
    private func blendTile(
        tile: ImageBuffer,
        intoAccum accum: inout [Float],
        weights: inout [Float],
        outX: Int, outY: Int,
        outW: Int, outH: Int,
        isLeftEdge: Bool, isRightEdge: Bool, isTopEdge: Bool, isBottomEdge: Bool
    ) {
        let scaledOverlap = overlap * scale
        let tw = tile.width
        let th = tile.height

        tile.pixels.withUnsafeBytes { rawPtr in
            let src = rawPtr.bindMemory(to: Float16.self).baseAddress!
            for ty in 0..<th {
                for tx in 0..<tw {
                    // Compute alpha based on distance to interior edges.
                    let dxLeft = isLeftEdge ? scaledOverlap : tx
                    let dxRight = isRightEdge ? scaledOverlap : (tw - 1 - tx)
                    let dyTop = isTopEdge ? scaledOverlap : ty
                    let dyBottom = isBottomEdge ? scaledOverlap : (th - 1 - ty)

                    let dxMin = min(dxLeft, dxRight)
                    let dyMin = min(dyTop, dyBottom)
                    let edgeDist = min(dxMin, dyMin)

                    // Linear ramp: 0 at edge, 1.0 at distance >= scaledOverlap.
                    let alpha: Float = scaledOverlap == 0 ? 1.0 : Float(min(edgeDist, scaledOverlap)) / Float(scaledOverlap)

                    let outPx = (outY + ty) * outW + (outX + tx)
                    let r = Float(src[(ty * tw + tx) * 4 + 0])
                    let g = Float(src[(ty * tw + tx) * 4 + 1])
                    let b = Float(src[(ty * tw + tx) * 4 + 2])
                    let a = Float(src[(ty * tw + tx) * 4 + 3])

                    accum[outPx * 4 + 0] += alpha * r
                    accum[outPx * 4 + 1] += alpha * g
                    accum[outPx * 4 + 2] += alpha * b
                    accum[outPx * 4 + 3] += alpha * a
                    weights[outPx] += alpha
                }
            }
        }
    }
}
