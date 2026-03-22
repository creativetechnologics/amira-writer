import Foundation

/// Core animation engine that evaluates keyframe tracks at a given frame,
/// producing interpolated values for rendering.
///
/// Supports cubic Bezier easing, stepped (hold) interpolation, and per-property
/// animation tracks. Works with the sparse keyframe data from `TimelineTrack`.
struct AnimationEngine: Sendable {

    // MARK: - Interpolation

    /// Evaluate a numeric value between two keyframes at the given frame.
    static func interpolate(
        from a: Double, to b: Double,
        frameA: Int, frameB: Int,
        currentFrame: Int,
        easing: EasingCurve
    ) -> Double {
        guard frameB > frameA else { return a }

        let t = Double(currentFrame - frameA) / Double(frameB - frameA)
        let clamped = max(0, min(1, t))
        let eased = applyEasing(clamped, curve: easing)

        return a + (b - a) * eased
    }

    /// Interpolate a full CharacterTransform between two keyframes.
    static func interpolateTransform(
        from a: CharacterTransform, to b: CharacterTransform,
        frameA: Int, frameB: Int,
        currentFrame: Int,
        easing: EasingCurve
    ) -> CharacterTransform {
        CharacterTransform(
            x: interpolate(from: a.x, to: b.x, frameA: frameA, frameB: frameB, currentFrame: currentFrame, easing: easing),
            y: interpolate(from: a.y, to: b.y, frameA: frameA, frameB: frameB, currentFrame: currentFrame, easing: easing),
            rotation: interpolateAngle(from: a.rotation, to: b.rotation, frameA: frameA, frameB: frameB, currentFrame: currentFrame, easing: easing),
            scaleX: interpolate(from: a.scaleX, to: b.scaleX, frameA: frameA, frameB: frameB, currentFrame: currentFrame, easing: easing),
            scaleY: interpolate(from: a.scaleY, to: b.scaleY, frameA: frameA, frameB: frameB, currentFrame: currentFrame, easing: easing),
            opacity: interpolate(from: a.opacity, to: b.opacity, frameA: frameA, frameB: frameB, currentFrame: currentFrame, easing: easing),
            zOrder: currentFrame < frameB ? a.zOrder : b.zOrder  // z-order snaps, no interpolation
        )
    }

    /// Interpolate angles taking the shortest path.
    static func interpolateAngle(
        from a: Double, to b: Double,
        frameA: Int, frameB: Int,
        currentFrame: Int,
        easing: EasingCurve
    ) -> Double {
        var delta = b - a
        // Normalize to [-180, 180] for shortest path
        while delta > 180 { delta -= 360 }
        while delta < -180 { delta += 360 }
        return a + interpolate(from: 0, to: delta, frameA: frameA, frameB: frameB, currentFrame: currentFrame, easing: easing)
    }

    // MARK: - Track Evaluation

    /// Evaluate a timeline track at a given frame, returning the active keyframe value.
    static func evaluate(track: TimelineTrack, at frame: Int) -> KeyframeValue? {
        let (before, after) = track.surroundingKeyframes(at: frame)

        guard let before else { return nil }

        // If no next keyframe or we're exactly on the keyframe, return it directly
        guard let after, after.frame > before.frame, frame < after.frame else {
            return before.value
        }

        // Interpolate based on kind
        switch (before.value, after.value) {
        case let (.transform(tA), .transform(tB)):
            let interp = interpolateTransform(
                from: tA, to: tB,
                frameA: before.frame, frameB: after.frame,
                currentFrame: frame,
                easing: before.easing
            )
            return .transform(interp)

        case let (.visibility(opA, visA), .visibility(opB, _)):
            let opInterp = interpolate(
                from: opA, to: opB,
                frameA: before.frame, frameB: after.frame,
                currentFrame: frame,
                easing: before.easing
            )
            return .visibility(opacity: opInterp, visible: visA)

        case (.drawing, .drawing),
             (.expression, .expression):
            // Drawing swaps and expressions are stepped — hold until next keyframe
            return before.value

        default:
            return before.value
        }
    }

    /// Evaluate all tracks for a scene at a given frame.
    static func evaluateScene(
        tracks: [String: TimelineTrack],
        at frame: Int
    ) -> [String: KeyframeValue] {
        var results: [String: KeyframeValue] = [:]
        for (name, track) in tracks {
            if let value = evaluate(track: track, at: frame) {
                results[name] = value
            }
        }
        return results
    }

    // MARK: - Easing Curves

    /// Apply an easing curve to a normalized t value (0...1).
    static func applyEasing(_ t: Double, curve: EasingCurve) -> Double {
        switch curve {
        case .linear:
            return t

        case .stepped:
            return 0  // Hold at start value until next keyframe

        case .easeIn:
            return cubicBezier(t: t, x1: 0.42, y1: 0, x2: 1.0, y2: 1.0)

        case .easeOut:
            return cubicBezier(t: t, x1: 0.0, y1: 0.0, x2: 0.58, y2: 1.0)

        case .easeInOut:
            return cubicBezier(t: t, x1: 0.42, y1: 0, x2: 0.58, y2: 1.0)

        case let .custom(cx1, cy1, cx2, cy2):
            return cubicBezier(t: t, x1: Double(cx1), y1: Double(cy1), x2: Double(cx2), y2: Double(cy2))
        }
    }

    /// Evaluate a cubic Bezier curve at parameter t.
    /// Uses Newton's method to solve for the t parameter given the x-axis Bezier control points,
    /// then evaluates the y-axis Bezier at that parameter.
    private static func cubicBezier(t: Double, x1: Double, y1: Double, x2: Double, y2: Double) -> Double {
        // For t=0 or t=1, return exact values
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }

        // Newton's method to find the Bezier parameter for the given x
        var guess = t
        for _ in 0..<8 {
            let currentX = bezierValue(guess, p1: x1, p2: x2)
            let dx = bezierDerivative(guess, p1: x1, p2: x2)
            if abs(dx) < 1e-7 { break }
            guess -= (currentX - t) / dx
        }

        // Evaluate y at the found parameter
        return bezierValue(guess, p1: y1, p2: y2)
    }

    /// Cubic Bezier value: B(t) = 3(1-t)^2*t*p1 + 3(1-t)*t^2*p2 + t^3
    private static func bezierValue(_ t: Double, p1: Double, p2: Double) -> Double {
        let mt = 1.0 - t
        return 3.0 * mt * mt * t * p1 + 3.0 * mt * t * t * p2 + t * t * t
    }

    /// Derivative of cubic Bezier.
    private static func bezierDerivative(_ t: Double, p1: Double, p2: Double) -> Double {
        let mt = 1.0 - t
        return 3.0 * mt * mt * p1 + 6.0 * mt * t * (p2 - p1) + 3.0 * t * t * (1.0 - p2)
    }

    // MARK: - Keyframe Generation Helpers

    /// Generate transform keyframes for a linear movement between two positions.
    static func generateMovement(
        from start: CharacterTransform,
        to end: CharacterTransform,
        startFrame: Int,
        endFrame: Int,
        easing: EasingCurve = .easeInOut
    ) -> [TimelineKeyframe] {
        [
            TimelineKeyframe(frame: startFrame, kind: .transform, easing: easing, value: .transform(start)),
            TimelineKeyframe(frame: endFrame, kind: .transform, easing: .linear, value: .transform(end)),
        ]
    }

    /// Generate expression change keyframe.
    static func generateExpressionChange(
        expression: String,
        at frame: Int
    ) -> TimelineKeyframe {
        TimelineKeyframe(frame: frame, kind: .expression, easing: .stepped, value: .expression(name: expression))
    }

    /// Generate visibility keyframes for a fade in/out.
    static func generateFade(
        fadeIn: Bool,
        startFrame: Int,
        endFrame: Int,
        easing: EasingCurve = .easeInOut
    ) -> [TimelineKeyframe] {
        let startOp: Double = fadeIn ? 0 : 1
        let endOp: Double = fadeIn ? 1 : 0
        return [
            TimelineKeyframe(frame: startFrame, kind: .visibility, easing: easing, value: .visibility(opacity: startOp, visible: true)),
            TimelineKeyframe(frame: endFrame, kind: .visibility, easing: .linear, value: .visibility(opacity: endOp, visible: fadeIn)),
        ]
    }
}
