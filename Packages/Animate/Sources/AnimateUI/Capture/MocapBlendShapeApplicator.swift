import Foundation
import SceneKit

@available(macOS 26.0, *)
@MainActor
struct MocapBlendShapeApplicator {

    static func apply(
        blendShapes: [BlendShapeName: Float],
        toRootNode rootNode: SCNNode
    ) {
        let stringWeights: [String: Double] = blendShapes.reduce(into: [:]) { result, pair in
            result[pair.key.rawValue] = Double(pair.value)
        }

        rootNode.enumerateChildNodes { node, _ in
            guard let morpher = node.morpher else { return }
            for (index, target) in morpher.targets.enumerated() {
                let name = target.name ?? ""
                guard let weight = stringWeights.first(where: { key, _ in
                    key.caseInsensitiveCompare(name) == .orderedSame
                })?.value else { continue }
                morpher.setWeight(CGFloat(weight), forTargetAt: index)
            }
        }
    }

    static func expressionState(from blendShapes: [BlendShapeName: Float]) -> CharacterExpressionState {
        let browInnerVal: Float = blendShapes[.browInnerUp] ?? 0
        let browOuterLeftVal: Float = blendShapes[.browOuterUpLeft] ?? 0
        let browOuterRightVal: Float = blendShapes[.browOuterUpRight] ?? 0
        let browOuterAvg: Float = (browOuterLeftVal + browOuterRightVal) * 0.25
        let browLiftRaw: Float = browInnerVal * 0.5 + browOuterAvg
        let browLiftFinal: Double = Double(browLiftRaw)

        let browDownLeftVal: Float = blendShapes[.browDownLeft] ?? 0
        let browDownRightVal: Float = blendShapes[.browDownRight] ?? 0
        let browDownAvg: Float = (browDownLeftVal + browDownRightVal) * 0.5
        let browDownFinal: Double = Double(browDownAvg)

        let browTiltFinal: Double = Double(browDownLeftVal - browDownRightVal)

        let eyeBlinkLeftVal: Float = blendShapes[.eyeBlinkLeft] ?? 0
        let eyeBlinkRightVal: Float = blendShapes[.eyeBlinkRight] ?? 0
        let eyeBlinkAvg: Float = (eyeBlinkLeftVal + eyeBlinkRightVal) * 0.5
        let eyeOpenFinal: Double = 1.0 - Double(eyeBlinkAvg)

        let smileLeftVal: Float = blendShapes[.mouthSmileLeft] ?? 0
        let smileRightVal: Float = blendShapes[.mouthSmileRight] ?? 0
        let smileAvg: Float = (smileLeftVal + smileRightVal) * 0.5
        let smileFinal: Double = Double(smileAvg)

        let blinkMax: Float = max(eyeBlinkLeftVal, eyeBlinkRightVal)
        let blinkFinal: Double = Double(blinkMax)

        let state = CharacterExpressionState(
            cue: "mocap",
            intensity: 1.0,
            browLift: 0,
            browTilt: 0,
            eyeOpen: 0,
            smile: 0,
            blink: 0,
            headPitch: 0
        )
        var result = state
        result.browLift = browLiftFinal - browDownFinal
        result.browTilt = browTiltFinal
        result.eyeOpen = eyeOpenFinal
        result.smile = smileFinal
        result.blink = blinkFinal
        return result
    }

    static func mouthState(from blendShapes: [BlendShapeName: Float]) -> CharacterMouthState {
        let jawOpen = Double(blendShapes[.jawOpen] ?? 0)
        let pucker = Double(blendShapes[.mouthPucker] ?? 0)
        let smileBlend = Double(
            ((blendShapes[.mouthSmileLeft] ?? 0) + (blendShapes[.mouthSmileRight] ?? 0)) * 0.5
        )
        let mouthWidth = 0.42 + smileBlend * 0.3 - pucker * 0.2
        let mouthHeight = 0.08 + jawOpen * 0.82

        return CharacterMouthState(
            cue: "mocap",
            viseme: jawOpen > 0.5 ? .ai : jawOpen > 0.2 ? .consonant : .rest,
            jawOpen: jawOpen,
            mouthWidth: mouthWidth,
            mouthHeight: mouthHeight,
            pucker: pucker,
            smileBlend: smileBlend
        )
    }
}
