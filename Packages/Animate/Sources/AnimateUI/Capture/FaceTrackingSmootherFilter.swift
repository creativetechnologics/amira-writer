import Foundation
import simd

@available(macOS 26.0, *)
final class FaceTrackingSmootherFilter: @unchecked Sendable {

    private let minCutoff: Float
    private let beta: Float
    private let dCutoff: Float

    private var filters: [BlendShapeName: OneEuroFilter] = [:]
    private let lock = NSLock()

    init(minCutoff: Float = 1.0, beta: Float = 0.5, dCutoff: Float = 1.0) {
        self.minCutoff = minCutoff
        self.beta = beta
        self.dCutoff = dCutoff
    }

    func smooth(_ weights: [BlendShapeName: Float], timestamp: Double) -> [BlendShapeName: Float] {
        lock.lock()
        defer { lock.unlock() }

        var smoothed: [BlendShapeName: Float] = [:]
        for (name, value) in weights {
            if filters[name] == nil {
                filters[name] = OneEuroFilter(
                    minCutoff: minCutoff,
                    beta: beta,
                    dCutoff: dCutoff
                )
            }
            let filtered = filters[name]!.filter(value: SIMD3<Float>(value, value, value), timestamp: timestamp)
            smoothed[name] = filtered.x
        }
        return smoothed
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        filters.removeAll()
    }
}
