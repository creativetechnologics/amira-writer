import Foundation
import simd

/// A blended pose output from NLA evaluation. Holds joint rotations as quaternions
/// and blend shape weights as floats, keyed by joint/blend-shape name strings.
@available(macOS 26.0, *)
struct BlendedPose: Sendable {
    /// Joint rotations keyed by joint name (e.g. "leftUpperArm").
    var jointRotations: [String: simd_quatf]
    /// Blend shape weights keyed by morph target name (e.g. "mouthSmileLeft").
    var blendShapeWeights: [String: Float]
    /// Root position offset (hips translation).
    var rootPosition: SIMD3<Float>

    /// A rest pose with identity rotations, zero blend shapes, zero root position.
    static func rest() -> BlendedPose {
        BlendedPose(
            jointRotations: [:],
            blendShapeWeights: [:],
            rootPosition: .zero
        )
    }

    /// Blend another pose sample into this accumulated pose.
    ///
    /// - Parameters:
    ///   - sample: The incoming pose sample from a motion clip.
    ///   - weight: Combined influence (track * clip * blend-in/out curve), 0.0-1.0.
    ///   - mode: How to combine with the existing accumulated pose.
    ///   - mask: Which body parts this blend affects.
    mutating func blend(
        with sample: BlendedPose,
        weight: Float,
        mode: NLABlendMode,
        mask: BodyPartMask
    ) {
        guard weight > 0.001 else { return }

        // Blend joint rotations
        for (jointName, sampleQuat) in sample.jointRotations {
            // Check body mask: if we know which part this joint belongs to,
            // only blend if the mask includes it.
            if let part = BodyPartMask.partForJoint(jointName),
               !mask.contains(part) {
                continue
            }

            let current = jointRotations[jointName] ?? simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)

            switch mode {
            case .replace:
                // Slerp between current and sample
                jointRotations[jointName] = simd_slerp(current, sampleQuat, weight)

            case .additive:
                // Convert sample to a delta from identity, scale it, then apply
                let identity = simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
                let delta = simd_slerp(identity, sampleQuat, weight)
                jointRotations[jointName] = simd_mul(current, delta)

            case .override_:
                // Full replacement where mask matches — slerp at full weight
                jointRotations[jointName] = simd_slerp(current, sampleQuat, weight)
            }
        }

        // Blend blend-shape weights (linear interpolation, clamped 0-1)
        for (shapeName, sampleValue) in sample.blendShapeWeights {
            // Blend shapes are always face/mouth region; check mask
            if !mask.contains(.face) && !mask.contains(.mouth) {
                continue
            }

            let current = blendShapeWeights[shapeName] ?? 0.0

            switch mode {
            case .replace:
                blendShapeWeights[shapeName] = clampUnit(current + (sampleValue - current) * weight)

            case .additive:
                blendShapeWeights[shapeName] = clampUnit(current + sampleValue * weight)

            case .override_:
                blendShapeWeights[shapeName] = clampUnit(current + (sampleValue - current) * weight)
            }
        }

        // Blend root position
        if mask.contains(.hips) {
            switch mode {
            case .replace:
                rootPosition = rootPosition + (sample.rootPosition - rootPosition) * weight

            case .additive:
                rootPosition = rootPosition + sample.rootPosition * weight

            case .override_:
                rootPosition = rootPosition + (sample.rootPosition - rootPosition) * weight
            }
        }
    }

    private func clampUnit(_ v: Float) -> Float {
        max(0, min(1, v))
    }
}

/// Evaluates an NLATimeline at a given frame by walking tracks bottom-to-top,
/// sampling the active clip on each track, and blending into an accumulated pose.
///
/// Follows the same static-method pattern as `AnimationEngine`.
@available(macOS 26.0, *)
struct NLAEvaluator: Sendable {

    /// A closure type that resolves a MotionClip UUID to its data.
    /// The caller provides this — typically from the motion clip library cache on AnimateStore.
    typealias MotionClipResolver = @Sendable (UUID) -> MotionClipData?

    /// Minimal protocol-free struct representing the data NLAEvaluator needs from a MotionClip.
    struct MotionClipData: Sendable {
        var frameCount: Int
        /// Sample the clip at a given frame index, returning joint rotations and blend shapes.
        var sample: @Sendable (Int) -> BlendedPose
    }

    // MARK: - Evaluate

    /// Evaluate the full NLA timeline at a given frame.
    ///
    /// - Parameters:
    ///   - timeline: The NLA timeline to evaluate.
    ///   - frame: The current frame on the NLA timeline.
    ///   - resolveClip: Closure to look up MotionClipData by UUID.
    /// - Returns: The blended pose for the frame, or rest pose if no tracks are active.
    static func evaluate(
        timeline: NLATimeline,
        frame: Int,
        resolveClip: MotionClipResolver
    ) -> BlendedPose {
        var accumulated = BlendedPose.rest()
        let activeTracks = timeline.sortedTracks
        let hasSolo = activeTracks.contains { $0.solo }

        for track in activeTracks {
            if track.muted { continue }
            if hasSolo && !track.solo { continue }

            guard let (clip, clipData) = activeClipAndData(
                in: track, at: frame, resolveClip: resolveClip
            ) else { continue }

            let effectiveFrame = clipLocalFrame(clip: clip, clipData: clipData, timelineFrame: frame)
            let sample = clipData.sample(effectiveFrame)
            let weight = clipWeight(clip: clip, clipData: clipData, timelineFrame: frame) * track.influence

            accumulated.blend(
                with: sample,
                weight: weight,
                mode: track.blendMode,
                mask: track.bodyMask
            )
        }

        return accumulated
    }

    // MARK: - Clip Lookup

    /// Find the active clip in a track at a given timeline frame, plus its resolved data.
    private static func activeClipAndData(
        in track: NLATrack,
        at frame: Int,
        resolveClip: MotionClipResolver
    ) -> (NLAClip, MotionClipData)? {
        for clip in track.clips {
            guard let clipData = resolveClip(clip.motionClipID) else { continue }
            let endFrame = clip.endFrame(motionClipFrameCount: clipData.frameCount)
            if frame >= clip.startFrame && frame < endFrame {
                return (clip, clipData)
            }
        }
        return nil
    }

    // MARK: - Frame Mapping

    /// Map an NLA timeline frame to a local frame index within the source motion clip.
    /// Accounts for trim and speed.
    private static func clipLocalFrame(
        clip: NLAClip,
        clipData: MotionClipData,
        timelineFrame: Int
    ) -> Int {
        let offsetFromStart = timelineFrame - clip.startFrame
        let speedAdjusted = Float(offsetFromStart) * clip.speed
        let sourceFrame = clip.trimStartFrame + Int(speedAdjusted)
        let maxFrame = clipData.frameCount - 1 - clip.trimEndFrame
        return max(clip.trimStartFrame, min(sourceFrame, maxFrame))
    }

    // MARK: - Blend Weight

    /// Compute the effective blend weight for a clip at a timeline frame,
    /// including blend-in/blend-out cross-fade ramps and per-clip influence.
    private static func clipWeight(
        clip: NLAClip,
        clipData: MotionClipData,
        timelineFrame: Int
    ) -> Float {
        let offsetFromStart = timelineFrame - clip.startFrame
        let clipTimelineDuration = clip.timelineDuration(motionClipFrameCount: clipData.frameCount)
        let offsetFromEnd = clipTimelineDuration - offsetFromStart

        var weight: Float = clip.influence

        // Blend-in ramp
        if clip.blendInFrames > 0 && offsetFromStart < clip.blendInFrames {
            weight *= Float(offsetFromStart) / Float(clip.blendInFrames)
        }

        // Blend-out ramp
        if clip.blendOutFrames > 0 && offsetFromEnd < clip.blendOutFrames {
            weight *= Float(offsetFromEnd) / Float(clip.blendOutFrames)
        }

        return max(0, min(1, weight))
    }
}
