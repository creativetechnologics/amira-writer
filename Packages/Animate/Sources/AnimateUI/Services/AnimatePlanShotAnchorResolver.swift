import Foundation

@available(macOS 26.0, *)
@MainActor
struct AnimatePlanShotAnchorResolver {
    let store: AnimateStore

    func resolve(
        _ plan: LLMAnimationPlan,
        for scene: AnimationScene
    ) -> (plan: LLMAnimationPlan, issues: [LLMAnimationValidationIssue]) {
        let segments = AnimateShotSegmentationService(store: store, previewPlan: nil)
            .shotSegments(for: scene)
        let lookup = ShotLookup(segments: segments)
        var issues: [LLMAnimationValidationIssue] = []
        var resolved = plan

        resolved.characterPlacements = plan.characterPlacements.map { placement in
            var placement = placement
            if let frame = resolvePointFrame(
                baseFrame: placement.frame,
                shotID: placement.shotID,
                shotName: placement.shotName,
                frameOffset: placement.frameOffset,
                lookup: lookup,
                label: "placement for \(placement.characterName)",
                issues: &issues
            ) {
                placement.frame = frame
            }
            return placement
        }

        resolved.objectPlacements = plan.objectPlacements.map { placement in
            var placement = placement
            if let frame = resolvePointFrame(
                baseFrame: placement.frame,
                shotID: placement.shotID,
                shotName: placement.shotName,
                frameOffset: placement.frameOffset,
                lookup: lookup,
                label: "object placement for \(placement.objectName)",
                issues: &issues
            ) {
                placement.frame = frame
            }
            return placement
        }

        resolved.expressions = plan.expressions.map { cue in
            var cue = cue
            if let frame = resolvePointFrame(
                baseFrame: cue.frame,
                shotID: cue.shotID,
                shotName: cue.shotName,
                frameOffset: cue.frameOffset,
                lookup: lookup,
                label: "expression for \(cue.characterName)",
                issues: &issues
            ) {
                cue.frame = frame
            }
            return cue
        }

        resolved.dialogueBeats = plan.dialogueBeats.map { beat in
            var beat = beat
            if let frame = resolvePointFrame(
                baseFrame: beat.startFrame,
                shotID: beat.shotID,
                shotName: beat.shotName,
                frameOffset: beat.frameOffset,
                lookup: lookup,
                label: "dialogue beat for \(beat.characterName)",
                issues: &issues
            ) {
                beat.startFrame = frame
            }
            return beat
        }

        resolved.shadowCues = plan.shadowCues.map { cue in
            var cue = cue
            if let frame = resolvePointFrame(
                baseFrame: cue.frame,
                shotID: cue.shotID,
                shotName: cue.shotName,
                frameOffset: cue.frameOffset,
                lookup: lookup,
                label: "shadow cue for \(cue.characterName)",
                issues: &issues
            ) {
                cue.frame = frame
            }
            return cue
        }

        resolved.objectStateCues = plan.objectStateCues.map { cue in
            var cue = cue
            if let frame = resolvePointFrame(
                baseFrame: cue.frame,
                shotID: cue.shotID,
                shotName: cue.shotName,
                frameOffset: cue.frameOffset,
                lookup: lookup,
                label: "object state cue for \(cue.objectName)",
                issues: &issues
            ) {
                cue.frame = frame
            }
            return cue
        }

        resolved.shotPresetApplications = plan.shotPresetApplications.map { application in
            var application = application
            if let frame = resolvePointFrame(
                baseFrame: application.frame,
                shotID: application.shotID,
                shotName: application.shotName,
                frameOffset: application.frameOffset,
                lookup: lookup,
                label: "shot preset \(application.presetName)",
                issues: &issues
            ) {
                application.frame = frame
            }
            return application
        }

        resolved.motions = plan.motions.map { motion in
            var motion = motion
            if let range = resolveRange(
                startFrame: motion.startFrame,
                endFrame: motion.endFrame,
                shotID: motion.shotID,
                shotName: motion.shotName,
                startOffset: motion.startFrameOffset,
                endOffset: motion.endFrameOffset,
                lookup: lookup,
                label: "motion for \(motion.characterName)",
                issues: &issues
            ) {
                motion.startFrame = range.start
                motion.endFrame = range.end
            }
            return motion
        }

        resolved.objectMotions = plan.objectMotions.map { motion in
            var motion = motion
            if let range = resolveRange(
                startFrame: motion.startFrame,
                endFrame: motion.endFrame,
                shotID: motion.shotID,
                shotName: motion.shotName,
                startOffset: motion.startFrameOffset,
                endOffset: motion.endFrameOffset,
                lookup: lookup,
                label: "object motion for \(motion.objectName)",
                issues: &issues
            ) {
                motion.startFrame = range.start
                motion.endFrame = range.end
            }
            return motion
        }

        resolved.cameraMoves = plan.cameraMoves.map { move in
            var move = move
            if let range = resolveRange(
                startFrame: move.startFrame,
                endFrame: move.endFrame,
                shotID: move.shotID,
                shotName: move.shotName,
                startOffset: move.startFrameOffset,
                endOffset: move.endFrameOffset,
                lookup: lookup,
                label: "camera move \(move.movement.displayName)",
                issues: &issues
            ) {
                move.startFrame = range.start
                move.endFrame = range.end ?? range.start
            }
            return move
        }

        return (resolved, issues)
    }

    private func resolvePointFrame(
        baseFrame: Int,
        shotID: String?,
        shotName: String?,
        frameOffset: Int?,
        lookup: ShotLookup,
        label: String,
        issues: inout [LLMAnimationValidationIssue]
    ) -> Int? {
        guard shotID?.trimmedNonEmpty != nil || shotName?.trimmedNonEmpty != nil else {
            return baseFrame
        }

        guard let shot = lookup.resolve(shotID: shotID, shotName: shotName, label: label, issues: &issues) else {
            return nil
        }
        return max(0, shot.startFrame + (frameOffset ?? 0))
    }

    private func resolveRange(
        startFrame: Int,
        endFrame: Int?,
        shotID: String?,
        shotName: String?,
        startOffset: Int?,
        endOffset: Int?,
        lookup: ShotLookup,
        label: String,
        issues: inout [LLMAnimationValidationIssue]
    ) -> (start: Int, end: Int?)? {
        guard shotID?.trimmedNonEmpty != nil || shotName?.trimmedNonEmpty != nil else {
            return (startFrame, endFrame)
        }

        guard let shot = lookup.resolve(shotID: shotID, shotName: shotName, label: label, issues: &issues) else {
            return nil
        }

        let resolvedStart = max(0, shot.startFrame + (startOffset ?? 0))
        let resolvedEnd = max(resolvedStart, shot.endFrame + (endOffset ?? 0))
        return (resolvedStart, resolvedEnd)
    }
}

@available(macOS 26.0, *)
private struct ShotLookup {
    let segments: [AnimateShotSegment]

    func resolve(
        shotID: String?,
        shotName: String?,
        label: String,
        issues: inout [LLMAnimationValidationIssue]
    ) -> AnimateShotSegment? {
        if let shotID = shotID?.trimmedNonEmpty {
            if let match = segments.first(where: { $0.id == shotID }) {
                return match
            }
            issues.append(.init(
                severity: .error,
                code: .unknownShotAnchor,
                message: "\(label) references unknown shot id '\(shotID)'."
            ))
            return nil
        }

        guard let shotName = shotName?.trimmedNonEmpty else { return nil }
        let matches = segments.filter {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(shotName) == .orderedSame
        }
        if matches.count == 1 {
            return matches[0]
        }
        if matches.count > 1 {
            issues.append(.init(
                severity: .error,
                code: .ambiguousShotAnchor,
                message: "\(label) references shot '\(shotName)', but multiple scene shots share that title."
            ))
        } else {
            issues.append(.init(
                severity: .error,
                code: .unknownShotAnchor,
                message: "\(label) references unknown shot '\(shotName)'."
            ))
        }
        return nil
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
