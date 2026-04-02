import Foundation

/// Provides smooth interpolation between viseme states for natural-looking lip sync
@available(macOS 26.0, *)
struct VisemeBlendEngine: Sendable {

    /// A snapshot of mouth parameters at a point in time
    struct MouthSnapshot: Sendable {
        var jawOpen: Double
        var mouthWidth: Double
        var mouthHeight: Double
        var pucker: Double
        var smileBlend: Double

        static let rest = MouthSnapshot(
            jawOpen: 0.02, mouthWidth: 0.42, mouthHeight: 0.08, pucker: 0, smileBlend: 0
        )

        func lerped(to target: MouthSnapshot, t: Double) -> MouthSnapshot {
            let t = max(0, min(1, t))
            let s = 1 - t
            return MouthSnapshot(
                jawOpen: jawOpen * s + target.jawOpen * t,
                mouthWidth: mouthWidth * s + target.mouthWidth * t,
                mouthHeight: mouthHeight * s + target.mouthHeight * t,
                pucker: pucker * s + target.pucker * t,
                smileBlend: smileBlend * s + target.smileBlend * t
            )
        }
    }

    /// Co-articulation weight matrix: how much the next viseme "pulls" the current one
    /// Higher values = more anticipatory blending
    private static let coarticulationWeights: [PrestonBlairViseme: Double] = [
        .rest: 0.1,
        .ai: 0.4,
        .e: 0.35,
        .o: 0.45,
        .u: 0.5,
        .consonant: 0.2,
        .fv: 0.15,
        .l: 0.25,
        .mbp: 0.1,  // MBP needs crisp closure
        .wq: 0.45
    ]

    /// Default mouth shapes for each viseme (matching CharacterMouthEngine defaults)
    static let visemeSnapshots: [PrestonBlairViseme: MouthSnapshot] = [
        .rest: MouthSnapshot(jawOpen: 0.02, mouthWidth: 0.42, mouthHeight: 0.08, pucker: 0, smileBlend: 0),
        .ai: MouthSnapshot(jawOpen: 0.85, mouthWidth: 0.72, mouthHeight: 0.9, pucker: 0, smileBlend: 0.04),
        .e: MouthSnapshot(jawOpen: 0.52, mouthWidth: 0.82, mouthHeight: 0.46, pucker: 0, smileBlend: 0.12),
        .o: MouthSnapshot(jawOpen: 0.58, mouthWidth: 0.5, mouthHeight: 0.64, pucker: 0.45, smileBlend: 0),
        .u: MouthSnapshot(jawOpen: 0.42, mouthWidth: 0.38, mouthHeight: 0.48, pucker: 0.68, smileBlend: 0),
        .consonant: MouthSnapshot(jawOpen: 0.28, mouthWidth: 0.62, mouthHeight: 0.22, pucker: 0.05, smileBlend: 0),
        .fv: MouthSnapshot(jawOpen: 0.2, mouthWidth: 0.66, mouthHeight: 0.2, pucker: 0.04, smileBlend: 0),
        .l: MouthSnapshot(jawOpen: 0.34, mouthWidth: 0.68, mouthHeight: 0.3, pucker: 0, smileBlend: 0),
        .mbp: MouthSnapshot(jawOpen: 0.06, mouthWidth: 0.52, mouthHeight: 0.08, pucker: 0, smileBlend: 0),
        .wq: MouthSnapshot(jawOpen: 0.2, mouthWidth: 0.34, mouthHeight: 0.2, pucker: 0.9, smileBlend: 0),
    ]

    /// A viseme keyframe with timing
    struct TimedViseme: Sendable {
        var frame: Int
        var viseme: PrestonBlairViseme
        var durationFrames: Int
    }

    /// Calculate the blended mouth state at a given frame, given a sequence of timed visemes
    /// Uses co-articulation to anticipate the next viseme shape
    static func blendedState(
        at frame: Int,
        keyframes: [TimedViseme],
        transitionFrames: Int = 3,
        fps: Int = 24
    ) -> MouthSnapshot {
        guard !keyframes.isEmpty else { return .rest }

        // Find the current and next keyframe
        var currentIndex = 0
        for (i, kf) in keyframes.enumerated() {
            if kf.frame <= frame {
                currentIndex = i
            } else {
                break
            }
        }

        let current = keyframes[currentIndex]
        let currentSnapshot = visemeSnapshots[current.viseme] ?? .rest

        // If we're past the last keyframe, just hold it
        let nextIndex = currentIndex + 1
        guard nextIndex < keyframes.count else {
            return currentSnapshot
        }

        let next = keyframes[nextIndex]
        let nextSnapshot = visemeSnapshots[next.viseme] ?? .rest

        // Calculate transition zone
        let framesUntilNext = next.frame - frame
        let effectiveTransition = min(transitionFrames, current.durationFrames / 2)

        if framesUntilNext <= effectiveTransition && effectiveTransition > 0 {
            // We're in the transition zone — blend toward next viseme
            let progress = 1.0 - (Double(framesUntilNext) / Double(effectiveTransition))
            let coartWeight = coarticulationWeights[next.viseme] ?? 0.3
            let blendAmount = progress * coartWeight

            // Use smoothstep for natural easing
            let smooth = blendAmount * blendAmount * (3 - 2 * blendAmount)
            return currentSnapshot.lerped(to: nextSnapshot, t: smooth)
        }

        // Check if we just transitioned from previous
        let framesSinceCurrent = frame - current.frame
        if framesSinceCurrent < effectiveTransition && currentIndex > 0 {
            let prev = keyframes[currentIndex - 1]
            let prevSnapshot = visemeSnapshots[prev.viseme] ?? .rest
            let progress = Double(framesSinceCurrent) / Double(effectiveTransition)
            let smooth = progress * progress * (3 - 2 * progress)
            return prevSnapshot.lerped(to: currentSnapshot, t: smooth)
        }

        return currentSnapshot
    }

    /// Convert a sequence of VisemeKeyframes (from LipSyncEngine) into smoothly blended snapshots
    /// for every frame in the range
    static func generateSmoothedFrames(
        keyframes: [TimedViseme],
        startFrame: Int,
        endFrame: Int,
        transitionFrames: Int = 3,
        fps: Int = 24
    ) -> [MouthSnapshot] {
        guard startFrame < endFrame else { return [] }
        return (startFrame..<endFrame).map { frame in
            blendedState(at: frame, keyframes: keyframes, transitionFrames: transitionFrames, fps: fps)
        }
    }
}
