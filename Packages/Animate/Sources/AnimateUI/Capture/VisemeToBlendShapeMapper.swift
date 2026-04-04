import Foundation

/// Maps Preston Blair visemes to ARKit-style face blend shape coefficients.
/// Uses the project's BlendShapeName enum (matches ARKit blend shape names).
@available(macOS 26.0, *)
struct VisemeToBlendShapeMapper: Sendable {

    /// Blend shape weights for each Preston Blair viseme.
    static let mapping: [PrestonBlairViseme: [BlendShapeName: Float]] = [
        .rest: [:],

        .ai: [
            .jawOpen: 0.6,
            .mouthStretchLeft: 0.3,
            .mouthStretchRight: 0.3,
        ],

        .e: [
            .jawOpen: 0.3,
            .mouthSmileLeft: 0.5,
            .mouthSmileRight: 0.5,
        ],

        .o: [
            .jawOpen: 0.5,
            .mouthFunnel: 0.6,
        ],

        .u: [
            .jawOpen: 0.2,
            .mouthPucker: 0.7,
        ],

        .mbp: [
            .jawOpen: 0.0,
            .mouthClose: 0.8,
        ],

        .fv: [
            .jawOpen: 0.1,
            .mouthLowerDownLeft: 0.3,
            .mouthLowerDownRight: 0.3,
        ],

        .l: [
            .jawOpen: 0.3,
            .tongueOut: 0.2,
        ],

        .consonant: [
            .jawOpen: 0.2,
        ],

        .wq: [
            .jawOpen: 0.2,
            .mouthPucker: 0.5,
        ],
    ]

    /// Convert viseme weights to a blended set of blend shapes.
    /// Takes multiple viseme weights (summing to ~1) and produces a single
    /// set of blend shape values.
    static func blendShapes(
        from visemeWeights: [PrestonBlairViseme: Float]
    ) -> [BlendShapeName: Float] {
        var result: [BlendShapeName: Float] = [:]

        for (viseme, weight) in visemeWeights where weight > 0.01 {
            guard let shapes = mapping[viseme] else { continue }
            for (shapeName, value) in shapes {
                result[shapeName, default: 0] += value * weight
            }
        }

        // Clamp all values to [0, 1]
        for key in result.keys {
            result[key] = max(0, min(1, result[key]!))
        }

        return result
    }

    /// Convert a single dominant viseme to blend shapes (convenience).
    static func blendShapes(for viseme: PrestonBlairViseme) -> [BlendShapeName: Float] {
        mapping[viseme] ?? [:]
    }

    /// Convert BlendShapeName keyed dictionary to String keyed (for MotionClip storage).
    static func toStringKeyed(_ shapes: [BlendShapeName: Float]) -> [String: Float] {
        Dictionary(uniqueKeysWithValues: shapes.map { ($0.key.rawValue, $0.value) })
    }
}
