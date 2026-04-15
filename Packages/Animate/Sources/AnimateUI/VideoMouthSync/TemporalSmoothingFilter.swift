import Accelerate
import CoreVideo
import Foundation

@available(macOS 26.0, *)
struct TemporalSmoothingFilter: Sendable {

    let strength: Int

    var blendAlpha: Float {
        strength > 0 ? max(0.5, 1.0 - Float(strength) * 0.1) : 1.0
    }

    init(strength: Int = 2) {
        self.strength = max(0, min(5, strength))
    }

    func smooth(
        current: CVPixelBuffer,
        previous: CVPixelBuffer?,
        mouthRegions: [CGRect],
        alpha: Float? = nil
    ) -> CVPixelBuffer {
        guard strength > 0, let previous, !mouthRegions.isEmpty else {
            return current
        }

        let blendFactor = alpha ?? blendAlpha
        let width = CVPixelBufferGetWidth(current)
        let height = CVPixelBufferGetHeight(current)

        var outputBuffer: CVPixelBuffer?
        CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            nil,
            &outputBuffer
        )
        guard let output = outputBuffer else { return current }

        CVPixelBufferLockBaseAddress(current, .readOnly)
        CVPixelBufferLockBaseAddress(previous, .readOnly)
        CVPixelBufferLockBaseAddress(output, [])

        let curBPRow = CVPixelBufferGetBytesPerRow(current)
        let prevBPRow = CVPixelBufferGetBytesPerRow(previous)
        let outBPRow = CVPixelBufferGetBytesPerRow(output)

        guard let curBase = CVPixelBufferGetBaseAddress(current),
              let prevBase = CVPixelBufferGetBaseAddress(previous),
              let outBase = CVPixelBufferGetBaseAddress(output)
        else {
            CVPixelBufferUnlockBaseAddress(current, .readOnly)
            CVPixelBufferUnlockBaseAddress(previous, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
            return current
        }

        let copyBytes = min(curBPRow, outBPRow)
        for row in 0..<height {
            memcpy(
                outBase.advanced(by: row * outBPRow),
                curBase.advanced(by: row * curBPRow),
                copyBytes
            )
        }

        let oneMinusAlpha = 1.0 - blendFactor

        for region in mouthRegions {
            let rx = max(0, Int(region.origin.x))
            let ry = max(0, Int(region.origin.y))
            let rw = min(Int(region.width), width - rx)
            let rh = min(Int(region.height), height - ry)
            guard rw > 0, rh > 0 else { continue }

            let byteCount = rw * 4
            var curFloat = [Float](repeating: 0, count: byteCount)
            var prevFloat = [Float](repeating: 0, count: byteCount)
            var blended = [Float](repeating: 0, count: byteCount)
            var temp = [Float](repeating: 0, count: byteCount)
            var alphaV = blendFactor
            var oneMinusV = oneMinusAlpha
            let length = vDSP_Length(byteCount)

            for row in ry..<(ry + rh) {
                let curPtr = curBase.advanced(by: row * curBPRow + rx * 4)
                    .assumingMemoryBound(to: UInt8.self)
                let prevPtr = prevBase.advanced(by: row * prevBPRow + rx * 4)
                    .assumingMemoryBound(to: UInt8.self)
                let outPtr = outBase.advanced(by: row * outBPRow + rx * 4)
                    .assumingMemoryBound(to: UInt8.self)

                vDSP_vfltu8(curPtr, 1, &curFloat, 1, length)
                vDSP_vfltu8(prevPtr, 1, &prevFloat, 1, length)
                vDSP_vsmul(curFloat, 1, &alphaV, &blended, 1, length)
                vDSP_vsmul(prevFloat, 1, &oneMinusV, &temp, 1, length)
                vDSP_vadd(blended, 1, temp, 1, &blended, 1, length)
                vDSP_vfixru8(blended, 1, outPtr, 1, length)
            }
        }

        CVPixelBufferUnlockBaseAddress(current, .readOnly)
        CVPixelBufferUnlockBaseAddress(previous, .readOnly)
        CVPixelBufferUnlockBaseAddress(output, [])

        return output
    }
}
