import Foundation
import simd

@available(macOS 26.0, *)
struct BlendShapeEstimator: Sendable {

    func estimate(from landmarks: VisionFaceLandmarks) -> [BlendShapeName: Float] {
        var weights: [BlendShapeName: Float] = [:]

        let jawOpenValue = estimateJawOpen(landmarks: landmarks)
        weights[.jawOpen] = jawOpenValue
        weights[.jawForward] = 0
        weights[.jawLeft] = 0
        weights[.jawRight] = 0

        let mouthSmile = estimateMouthSmile(landmarks: landmarks)
        weights[.mouthSmileLeft] = mouthSmile.left
        weights[.mouthSmileRight] = mouthSmile.right

        let mouthFrown = estimateMouthFrown(landmarks: landmarks)
        weights[.mouthFrownLeft] = mouthFrown.left
        weights[.mouthFrownRight] = mouthFrown.right

        let puckerValue = estimateMouthPucker(landmarks: landmarks)
        weights[.mouthPucker] = puckerValue
        weights[.mouthFunnel] = estimateMouthFunnel(landmarks: landmarks)

        weights[.mouthClose] = max(0, 1.0 - jawOpenValue * 3.0)
        weights[.mouthLeft] = 0
        weights[.mouthRight] = 0
        weights[.mouthDimpleLeft] = mouthSmile.left * 0.5
        weights[.mouthDimpleRight] = mouthSmile.right * 0.5
        weights[.mouthStretchLeft] = max(0, mouthSmile.left - 0.3) * 0.5
        weights[.mouthStretchRight] = max(0, mouthSmile.right - 0.3) * 0.5
        weights[.mouthRollLower] = 0
        weights[.mouthRollUpper] = 0
        weights[.mouthShrugLower] = jawOpenValue * 0.3
        weights[.mouthShrugUpper] = jawOpenValue * 0.2
        weights[.mouthPressLeft] = max(0, 1.0 - jawOpenValue * 2.0) * 0.5
        weights[.mouthPressRight] = max(0, 1.0 - jawOpenValue * 2.0) * 0.5

        let mouthVertical = estimateMouthVertical(landmarks: landmarks)
        weights[.mouthUpperUpLeft] = mouthVertical.upperUp * jawOpenValue
        weights[.mouthUpperUpRight] = mouthVertical.upperUp * jawOpenValue
        weights[.mouthLowerDownLeft] = mouthVertical.lowerDown * jawOpenValue
        weights[.mouthLowerDownRight] = mouthVertical.lowerDown * jawOpenValue

        let eyeBlink = estimateEyeBlink(landmarks: landmarks)
        weights[.eyeBlinkLeft] = eyeBlink.left
        weights[.eyeBlinkRight] = eyeBlink.right

        let eyeWide = estimateEyeWide(landmarks: landmarks)
        weights[.eyeWideLeft] = eyeWide.left
        weights[.eyeWideRight] = eyeWide.right

        let eyeSquint = estimateEyeSquint(landmarks: landmarks)
        weights[.eyeSquintLeft] = eyeSquint.left
        weights[.eyeSquintRight] = eyeSquint.right

        weights[.eyeLookUpLeft] = 0
        weights[.eyeLookUpRight] = 0
        weights[.eyeLookDownLeft] = 0
        weights[.eyeLookDownRight] = 0
        weights[.eyeLookInLeft] = 0
        weights[.eyeLookInRight] = 0
        weights[.eyeLookOutLeft] = 0
        weights[.eyeLookOutRight] = 0

        let browDown = estimateBrowDown(landmarks: landmarks)
        weights[.browDownLeft] = browDown.left
        weights[.browDownRight] = browDown.right

        let browInnerUp = estimateBrowInnerUp(landmarks: landmarks)
        weights[.browInnerUp] = browInnerUp

        let browOuterUp = estimateBrowOuterUp(landmarks: landmarks)
        weights[.browOuterUpLeft] = browOuterUp.left
        weights[.browOuterUpRight] = browOuterUp.right

        weights[.cheekPuff] = 0
        weights[.cheekSquintLeft] = eyeSquint.left * 0.7
        weights[.cheekSquintRight] = eyeSquint.right * 0.7

        let noseSneer = estimateNoseSneer(landmarks: landmarks)
        weights[.noseSneerLeft] = noseSneer.left
        weights[.noseSneerRight] = noseSneer.right

        weights[.tongueOut] = 0

        return weights
    }

    private func estimateJawOpen(landmarks: VisionFaceLandmarks) -> Float {
        let innerLips = landmarks.innerLips
        guard innerLips.count >= 6 else { return 0 }
        let topCenter = innerLips[0]
        let bottomCenter = innerLips[innerLips.count / 2]
        let mouthGap = distance(topCenter, bottomCenter)

        let faceHeight = Float(landmarks.boundingBox.height)
        guard faceHeight > 0 else { return 0 }
        let normalized = mouthGap / faceHeight
        return clamp01(normalized / 0.15)
    }

    private func estimateMouthSmile(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let outerLips = landmarks.outerLips
        guard outerLips.count >= 6 else { return (0, 0) }
        let leftCorner = outerLips[0]
        let rightCorner = outerLips[outerLips.count / 2]
        let topCenter = outerLips[outerLips.count / 4]
        let bottomCenter = outerLips[3 * outerLips.count / 4]
        let mouthCenterY = (topCenter.y + bottomCenter.y) / 2

        let leftSmile = (leftCorner.y - mouthCenterY) / Float(landmarks.boundingBox.height)
        let rightSmile = (rightCorner.y - mouthCenterY) / Float(landmarks.boundingBox.height)

        return (
            left: clamp01(leftSmile * 15.0),
            right: clamp01(rightSmile * 15.0)
        )
    }

    private func estimateMouthFrown(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let smile = estimateMouthSmile(landmarks: landmarks)
        return (
            left: clamp01(-smile.left + 0.1),
            right: clamp01(-smile.right + 0.1)
        )
    }

    private func estimateMouthPucker(landmarks: VisionFaceLandmarks) -> Float {
        let innerLips = landmarks.innerLips
        guard innerLips.count >= 4 else { return 0 }
        let leftCorner = innerLips[0]
        let rightCorner = innerLips[innerLips.count / 2]
        let innerWidth = abs(rightCorner.x - leftCorner.x)
        let faceWidth = Float(landmarks.boundingBox.width)
        guard faceWidth > 0 else { return 0 }
        let normalizedWidth = innerWidth / faceWidth
        return clamp01(1.0 - normalizedWidth / 0.25)
    }

    private func estimateMouthFunnel(landmarks: VisionFaceLandmarks) -> Float {
        let jawOpen = estimateJawOpen(landmarks: landmarks)
        let pucker = estimateMouthPucker(landmarks: landmarks)
        return clamp01(jawOpen * pucker * 2.0)
    }

    private func estimateMouthVertical(landmarks: VisionFaceLandmarks) -> (upperUp: Float, lowerDown: Float) {
        let innerLips = landmarks.innerLips
        guard innerLips.count >= 6 else { return (0, 0) }
        let topCenter = innerLips[0]
        let bottomCenter = innerLips[innerLips.count / 2]
        let faceHeight = Float(landmarks.boundingBox.height)
        guard faceHeight > 0 else { return (0, 0) }
        let gap = bottomCenter.y - topCenter.y
        let normalizedGap = abs(gap) / faceHeight
        return (
            upperUp: clamp01(normalizedGap * 5.0),
            lowerDown: clamp01(normalizedGap * 6.0)
        )
    }

    private func estimateEyeBlink(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let leftBlink = eyeAspectRatioToBlink(landmarks.leftEye)
        let rightBlink = eyeAspectRatioToBlink(landmarks.rightEye)
        return (left: leftBlink, right: rightBlink)
    }

    private func estimateEyeWide(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let leftAR = eyeAspectRatio(landmarks.leftEye)
        let rightAR = eyeAspectRatio(landmarks.rightEye)
        return (
            left: clamp01((leftAR - 0.28) * 5.0),
            right: clamp01((rightAR - 0.28) * 5.0)
        )
    }

    private func estimateEyeSquint(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let leftAR = eyeAspectRatio(landmarks.leftEye)
        let rightAR = eyeAspectRatio(landmarks.rightEye)
        return (
            left: clamp01((0.22 - leftAR) * 6.0),
            right: clamp01((0.22 - rightAR) * 6.0)
        )
    }

    private func estimateBrowDown(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let leftDist = browToEyeDistance(brow: landmarks.leftEyebrow, eye: landmarks.leftEye)
        let rightDist = browToEyeDistance(brow: landmarks.rightEyebrow, eye: landmarks.rightEye)
        let faceHeight = Float(landmarks.boundingBox.height)
        guard faceHeight > 0 else { return (0, 0) }
        let leftNorm = leftDist / faceHeight
        let rightNorm = rightDist / faceHeight
        return (
            left: clamp01((0.06 - leftNorm) * 20.0),
            right: clamp01((0.06 - rightNorm) * 20.0)
        )
    }

    private func estimateBrowInnerUp(landmarks: VisionFaceLandmarks) -> Float {
        let leftBrow = landmarks.leftEyebrow
        let rightBrow = landmarks.rightEyebrow
        guard !leftBrow.isEmpty, !rightBrow.isEmpty else { return 0 }
        let leftInner = leftBrow.last ?? leftBrow[0]
        let rightInner = rightBrow.first ?? rightBrow[0]
        let leftEyeCenter = centroid(landmarks.leftEye)
        let rightEyeCenter = centroid(landmarks.rightEye)

        let faceHeight = Float(landmarks.boundingBox.height)
        guard faceHeight > 0 else { return 0 }
        let leftOffset = (leftInner.y - leftEyeCenter.y) / faceHeight
        let rightOffset = (rightInner.y - rightEyeCenter.y) / faceHeight
        let avgOffset = (leftOffset + rightOffset) / 2
        return clamp01((avgOffset - 0.05) * 15.0)
    }

    private func estimateBrowOuterUp(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let leftBrow = landmarks.leftEyebrow
        let rightBrow = landmarks.rightEyebrow
        guard !leftBrow.isEmpty, !rightBrow.isEmpty else { return (0, 0) }
        let leftOuter = leftBrow.first ?? leftBrow[0]
        let rightOuter = rightBrow.last ?? rightBrow[0]
        let leftEyeCenter = centroid(landmarks.leftEye)
        let rightEyeCenter = centroid(landmarks.rightEye)

        let faceHeight = Float(landmarks.boundingBox.height)
        guard faceHeight > 0 else { return (0, 0) }
        let leftOffset = (leftOuter.y - leftEyeCenter.y) / faceHeight
        let rightOffset = (rightOuter.y - rightEyeCenter.y) / faceHeight
        return (
            left: clamp01((leftOffset - 0.05) * 12.0),
            right: clamp01((rightOffset - 0.05) * 12.0)
        )
    }

    private func estimateNoseSneer(landmarks: VisionFaceLandmarks) -> (left: Float, right: Float) {
        let nose = landmarks.nose
        guard nose.count >= 4 else { return (0, 0) }
        let leftNostril = nose[0]
        let rightNostril = nose[nose.count - 1]
        let noseCenter = centroid(nose)
        let faceWidth = Float(landmarks.boundingBox.width)
        guard faceWidth > 0 else { return (0, 0) }
        let leftSpread = abs(leftNostril.x - noseCenter.x) / faceWidth
        let rightSpread = abs(rightNostril.x - noseCenter.x) / faceWidth
        return (
            left: clamp01((leftSpread - 0.04) * 15.0),
            right: clamp01((rightSpread - 0.04) * 15.0)
        )
    }

    private func distance(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        simd_distance(a, b)
    }

    private func centroid(_ points: [SIMD2<Float>]) -> SIMD2<Float> {
        guard !points.isEmpty else { return .zero }
        let sum = points.reduce(SIMD2<Float>.zero, +)
        return sum / Float(points.count)
    }

    private func eyeAspectRatio(_ eyePoints: [SIMD2<Float>]) -> Float {
        guard eyePoints.count >= 4 else { return 0.25 }
        let xs = eyePoints.map(\.x)
        let ys = eyePoints.map(\.y)
        let width = (xs.max() ?? 0) - (xs.min() ?? 0)
        let height = (ys.max() ?? 0) - (ys.min() ?? 0)
        guard width > 0 else { return 0.25 }
        return height / width
    }

    private func eyeAspectRatioToBlink(_ eyePoints: [SIMD2<Float>]) -> Float {
        let ar = eyeAspectRatio(eyePoints)
        return clamp01((0.25 - ar) / 0.20)
    }

    private func browToEyeDistance(brow: [SIMD2<Float>], eye: [SIMD2<Float>]) -> Float {
        let browCenter = centroid(brow)
        let eyeCenter = centroid(eye)
        return abs(browCenter.y - eyeCenter.y)
    }

    private func clamp01(_ value: Float) -> Float {
        min(1.0, max(0.0, value))
    }
}
