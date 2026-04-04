import Foundation
import simd

@available(macOS 26.0, *)
struct LowPassFilter: Sendable {
    private var hatXPrev: Float?
    private(set) var hadPrev: Bool = false

    mutating func filter(value: Float, alpha: Float) -> Float {
        if let prev = hatXPrev {
            let result = alpha * value + (1.0 - alpha) * prev
            hatXPrev = result
            return result
        } else {
            hatXPrev = value
            return value
        }
    }

    mutating func reset() {
        hatXPrev = nil
        hadPrev = false
    }
}

@available(macOS 26.0, *)
struct OneEuroFilter: Sendable {
    let minCutoff: Float
    let beta: Float
    let dCutoff: Float

    private var xFilterX = LowPassFilter()
    private var xFilterY = LowPassFilter()
    private var xFilterZ = LowPassFilter()
    private var dxFilterX = LowPassFilter()
    private var dxFilterY = LowPassFilter()
    private var dxFilterZ = LowPassFilter()
    private var prevValue: SIMD3<Float>?
    private var prevTimestamp: Double?

    init(minCutoff: Float = 1.0, beta: Float = 0.007, dCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    mutating func filter(value: SIMD3<Float>, timestamp: Double) -> SIMD3<Float> {
        guard let prev = prevValue, let prevT = prevTimestamp else {
            prevValue = value
            prevTimestamp = timestamp
            _ = xFilterX.filter(value: value.x, alpha: 1.0)
            _ = xFilterY.filter(value: value.y, alpha: 1.0)
            _ = xFilterZ.filter(value: value.z, alpha: 1.0)
            _ = dxFilterX.filter(value: 0.0, alpha: 1.0)
            _ = dxFilterY.filter(value: 0.0, alpha: 1.0)
            _ = dxFilterZ.filter(value: 0.0, alpha: 1.0)
            return value
        }

        let dt = Float(max(timestamp - prevT, 1e-6))
        let dx = (value - prev) / dt

        let edAlpha = Self.alpha(cutoff: dCutoff, dt: dt)
        let edx = SIMD3<Float>(
            dxFilterX.filter(value: dx.x, alpha: edAlpha),
            dxFilterY.filter(value: dx.y, alpha: edAlpha),
            dxFilterZ.filter(value: dx.z, alpha: edAlpha)
        )

        let cutoffX = minCutoff + beta * abs(edx.x)
        let cutoffY = minCutoff + beta * abs(edx.y)
        let cutoffZ = minCutoff + beta * abs(edx.z)

        let result = SIMD3<Float>(
            xFilterX.filter(value: value.x, alpha: Self.alpha(cutoff: cutoffX, dt: dt)),
            xFilterY.filter(value: value.y, alpha: Self.alpha(cutoff: cutoffY, dt: dt)),
            xFilterZ.filter(value: value.z, alpha: Self.alpha(cutoff: cutoffZ, dt: dt))
        )

        prevValue = value
        prevTimestamp = timestamp

        return result
    }

    mutating func reset() {
        xFilterX.reset()
        xFilterY.reset()
        xFilterZ.reset()
        dxFilterX.reset()
        dxFilterY.reset()
        dxFilterZ.reset()
        prevValue = nil
        prevTimestamp = nil
    }

    static func alpha(cutoff: Float, dt: Float) -> Float {
        let tau = 1.0 / (2.0 * Float.pi * cutoff)
        return 1.0 / (1.0 + tau / dt)
    }
}

@available(macOS 26.0, *)
struct TemporalFilterManager: Sendable {
    private var filters: [JointName: OneEuroFilter] = [:]
    var minCutoff: Float = 1.0
    var beta: Float = 0.007
    var dCutoff: Float = 1.0

    mutating func filter(
        joints: [JointName: SIMD3<Float>],
        timestamp: Double
    ) -> [JointName: SIMD3<Float>] {
        var result: [JointName: SIMD3<Float>] = [:]
        for (name, position) in joints {
            if filters[name] == nil {
                filters[name] = OneEuroFilter(
                    minCutoff: minCutoff,
                    beta: beta,
                    dCutoff: dCutoff
                )
            }
            result[name] = filters[name]!.filter(value: position, timestamp: timestamp)
        }
        return result
    }

    mutating func reset() {
        filters.removeAll()
    }
}