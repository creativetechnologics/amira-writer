import Foundation

struct LLMAnimationPlanCompiler: Sendable {
    private let allowedPositionRange = (-0.5)...1.5

    func parse(json: String) throws -> LLMAnimationPlan {
        let data = Data(json.utf8)
        return try JSONDecoder().decode(LLMAnimationPlan.self, from: data)
    }

    func validate(_ plan: LLMAnimationPlan) -> LLMAnimationValidationReport {
        var issues: [LLMAnimationValidationIssue] = []

        if plan.schemaVersion > LLMAnimationPlan.currentSchemaVersion {
            issues.append(.init(
                severity: .error,
                code: .unsupportedSchemaVersion,
                message: "Animation plan schema version \(plan.schemaVersion) is newer than supported version \(LLMAnimationPlan.currentSchemaVersion)."
            ))
        }

        if plan.sceneName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                severity: .error,
                code: .emptySceneName,
                message: "Animation plans need a non-empty scene name."
            ))
        }

        if let sceneAudioPath = plan.sceneAudioPath,
           sceneAudioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                severity: .error,
                code: .emptyAudioPath,
                message: "Scene audio paths need a non-empty value."
            ))
        }

        for placement in plan.characterPlacements {
            validateCharacterName(placement.characterName, issues: &issues)
            validateFrame(placement.frame, label: "placement frame", issues: &issues)
            validatePosition(placement.position, label: "\(placement.characterName) placement", issues: &issues)
        }

        for motion in plan.motions {
            validateCharacterName(motion.characterName, issues: &issues)
            validateFrame(motion.startFrame, label: "motion start frame", issues: &issues)
            if let endFrame = motion.endFrame, endFrame < motion.startFrame {
                issues.append(.init(
                    severity: .error,
                    code: .invalidFrameRange,
                    message: "Motion for \(motion.characterName) ends before it starts."
                ))
            }
            if let from = motion.from {
                validatePosition(from, label: "\(motion.characterName) motion start", issues: &issues)
            }
            validatePosition(motion.to, label: "\(motion.characterName) motion destination", issues: &issues)
            if let pace = motion.paceUnitsPerSecond, pace <= 0 {
                issues.append(.init(
                    severity: .error,
                    code: .invalidPace,
                    message: "Motion pace for \(motion.characterName) must be greater than zero."
                ))
            }
        }

        for expression in plan.expressions {
            validateCharacterName(expression.characterName, issues: &issues)
            validateFrame(expression.frame, label: "expression frame", issues: &issues)
        }

        for dialogueBeat in plan.dialogueBeats {
            validateCharacterName(dialogueBeat.characterName, issues: &issues)
            validateFrame(dialogueBeat.startFrame, label: "dialogue frame", issues: &issues)
            if dialogueBeat.audioPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(.init(
                    severity: .error,
                    code: .emptyAudioPath,
                    message: "Dialogue beats need a non-empty audio path."
                ))
            }
        }

        for shadowCue in plan.shadowCues {
            validateCharacterName(shadowCue.characterName, issues: &issues)
            validateFrame(shadowCue.frame, label: "shadow frame", issues: &issues)
            if let opacity = shadowCue.opacity, !(0...1).contains(opacity) {
                issues.append(.init(
                    severity: .error,
                    code: .invalidOpacity,
                    message: "Shadow opacity for \(shadowCue.characterName) must stay between 0 and 1."
                ))
            }
        }

        for cameraMove in plan.cameraMoves {
            validateFrame(cameraMove.startFrame, label: "camera start frame", issues: &issues)
            if cameraMove.endFrame < cameraMove.startFrame {
                issues.append(.init(
                    severity: .error,
                    code: .invalidFrameRange,
                    message: "Camera move \(cameraMove.movement.rawValue) ends before it starts."
                ))
            }
        }

        for presetApplication in plan.shotPresetApplications {
            validateShotPresetName(presetApplication.presetName, issues: &issues)
            validateFrame(presetApplication.frame, label: "shot preset frame", issues: &issues)
            if let focusCharacterName = presetApplication.focusCharacterName {
                validateCharacterName(focusCharacterName, issues: &issues)
            }
            for override in presetApplication.characterOverrides {
                validateCharacterName(override.characterName, issues: &issues)
            }
        }

        return LLMAnimationValidationReport(issues: issues)
    }

    func compile(
        _ plan: LLMAnimationPlan,
        fps: Int
    ) -> CompiledScene {
        var compiled = CompiledScene(
            name: plan.sceneName,
            backgroundName: plan.backgroundName,
            lighting: plan.lighting
        )
        var latestTransforms: [String: CharacterTransform] = [:]
        var maxFrame = 0

        for placement in plan.characterPlacements.sorted(by: { $0.frame < $1.frame }) {
            let facing = placement.facing ?? .camera
            let transform = makeTransform(
                position: placement.position,
                facing: facing,
                zOrder: placement.zOrder ?? 0
            )

            if !compiled.characterSetups.contains(where: { $0.characterName.caseInsensitiveCompare(placement.characterName) == .orderedSame }) {
                compiled.characterSetups.append(CharacterSetup(
                    characterName: placement.characterName,
                    initialPosition: placement.position.x,
                    initialFacing: facing,
                    initialEmotion: placement.emotion ?? "neutral",
                    enterFrame: placement.frame
                ))
            }

            compiled.tracks["\(placement.characterName):transform", default: []].append(
                TimelineKeyframe(frame: placement.frame, kind: .transform, easing: .linear, value: .transform(transform))
            )

            if let emotion = placement.emotion {
                compiled.tracks["\(placement.characterName):expression", default: []].append(
                    AnimationEngine.generateExpressionChange(expression: emotion, at: placement.frame)
                )
            }

            if let viewAngle = placement.viewAngle ?? inferredViewAngle(from: facing) {
                compiled.tracks["\(placement.characterName):view", default: []].append(
                    AnimationEngine.generateExpressionChange(expression: viewAngle.rawValue, at: placement.frame)
                )
            }

            compiled.tracks["\(placement.characterName):facing", default: []].append(
                AnimationEngine.generateExpressionChange(expression: facing.rawValue, at: placement.frame)
            )

            if let pose = placement.pose {
                compiled.tracks["\(placement.characterName):pose", default: []].append(
                    AnimationEngine.generateExpressionChange(expression: pose.rawValue, at: placement.frame)
                )
            }

            latestTransforms[placement.characterName.lowercased()] = transform
            maxFrame = max(maxFrame, placement.frame)
        }

        for motion in plan.motions.sorted(by: { $0.startFrame < $1.startFrame }) {
            let key = motion.characterName.lowercased()
            let startTransform = motion.from.map {
                makeTransform(
                    position: $0,
                    facing: motion.facing ?? facing(from: latestTransforms[key]),
                    zOrder: motion.zOrder ?? latestTransforms[key]?.zOrder ?? 0
                )
            } ?? latestTransforms[key] ?? makeTransform(
                position: .init(x: 0.5, y: 0.56),
                facing: motion.facing ?? .camera,
                zOrder: motion.zOrder ?? 0
            )

            let resolvedEndFrame = resolvedEndFrame(
                for: motion,
                fps: fps,
                startTransform: startTransform
            )

            let endTransform = makeTransform(
                position: motion.to,
                facing: motion.facing ?? facing(from: startTransform),
                zOrder: motion.zOrder ?? startTransform.zOrder
            )
            let resolvedFacing = motion.facing ?? inferredFacing(from: startTransform, to: motion.to)

            compiled.tracks["\(motion.characterName):transform", default: []].append(contentsOf:
                AnimationEngine.generateMovement(
                    from: startTransform,
                    to: endTransform,
                    startFrame: motion.startFrame,
                    endFrame: resolvedEndFrame,
                    easing: motion.easing.runtimeCurve
                )
            )

            if let resolvedFacing {
                compiled.tracks["\(motion.characterName):facing", default: []].append(
                    AnimationEngine.generateExpressionChange(expression: resolvedFacing.rawValue, at: motion.startFrame)
                )
            }

            let resolvedViewAngle = motion.viewAngle ?? resolvedFacing.flatMap(inferredViewAngle(from:))
            if let resolvedViewAngle {
                compiled.tracks["\(motion.characterName):view", default: []].append(
                    AnimationEngine.generateExpressionChange(expression: resolvedViewAngle.rawValue, at: motion.startFrame)
                )
            }

            if let resolvedPose = motion.pose ?? pose(from: motion.movementStyle) {
                compiled.tracks["\(motion.characterName):pose", default: []].append(
                    AnimationEngine.generateExpressionChange(expression: resolvedPose.rawValue, at: motion.startFrame)
                )
            }

            if let movementStyle = motion.movementStyle {
                compiled.tracks["\(motion.characterName):action", default: []].append(
                    TimelineKeyframe(
                        frame: motion.startFrame,
                        kind: .expression,
                        easing: .stepped,
                        value: .expression(name: movementStyle)
                    )
                )
            }

            latestTransforms[key] = endTransform
            maxFrame = max(maxFrame, resolvedEndFrame)
        }

        for expression in plan.expressions.sorted(by: { $0.frame < $1.frame }) {
            compiled.tracks["\(expression.characterName):expression", default: []].append(
                AnimationEngine.generateExpressionChange(expression: expression.expression, at: expression.frame)
            )
            maxFrame = max(maxFrame, expression.frame)
        }

        for dialogueBeat in plan.dialogueBeats.sorted(by: { $0.startFrame < $1.startFrame }) {
            compiled.tracks["\(dialogueBeat.characterName):action", default: []].append(
                AnimationEngine.generateExpressionChange(
                    expression: dialogueBeat.action ?? "speak",
                    at: dialogueBeat.startFrame
                )
            )

            if let expression = dialogueBeat.expression,
               !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                compiled.tracks["\(dialogueBeat.characterName):expression", default: []].append(
                    AnimationEngine.generateExpressionChange(
                        expression: expression,
                        at: dialogueBeat.startFrame
                    )
                )
            }

            maxFrame = max(maxFrame, dialogueBeat.startFrame)
        }

        for shadowCue in plan.shadowCues.sorted(by: { $0.frame < $1.frame }) {
            compiled.tracks["\(shadowCue.characterName):shadow-style", default: []].append(
                AnimationEngine.generateExpressionChange(
                    expression: shadowCue.style.rawValue,
                    at: shadowCue.frame
                )
            )

            if let opacity = shadowCue.opacity {
                compiled.tracks["\(shadowCue.characterName):shadow-opacity", default: []].append(
                    AnimationEngine.generateExpressionChange(
                        expression: String(opacity),
                        at: shadowCue.frame
                    )
                )
            }

            maxFrame = max(maxFrame, shadowCue.frame)
        }

        for cameraMove in plan.cameraMoves.sorted(by: { $0.startFrame < $1.startFrame }) {
            let startZoom = cameraMove.fromShot?.zoomLevel ?? 1.0
            let endZoom = cameraMove.toShot?.zoomLevel ?? startZoom
            let panOffset = panOffset(for: cameraMove.movement)

            if let fromShot = cameraMove.fromShot {
                compiled.tracks["camera:shot", default: []].append(
                    AnimationEngine.generateExpressionChange(expression: fromShot.rawValue, at: cameraMove.startFrame)
                )
            }

            if let toShot = cameraMove.toShot,
               toShot != cameraMove.fromShot {
                compiled.tracks["camera:shot", default: []].append(
                    AnimationEngine.generateExpressionChange(expression: toShot.rawValue, at: cameraMove.endFrame)
                )
            }

            let start = CharacterTransform(
                x: 0,
                y: 0,
                rotation: 0,
                scaleX: startZoom,
                scaleY: startZoom,
                opacity: 1,
                zOrder: 0
            )
            let end = CharacterTransform(
                x: panOffset.x,
                y: panOffset.y,
                rotation: 0,
                scaleX: endZoom,
                scaleY: endZoom,
                opacity: 1,
                zOrder: 0
            )

            compiled.cameraKeyframes.append(contentsOf:
                AnimationEngine.generateMovement(
                    from: start,
                    to: end,
                    startFrame: cameraMove.startFrame,
                    endFrame: cameraMove.endFrame,
                    easing: cameraMove.easing.runtimeCurve
                )
            )
            maxFrame = max(maxFrame, cameraMove.endFrame)
        }

        compiled.totalFrames = maxFrame
        return compiled
    }

    private func validateCharacterName(
        _ characterName: String,
        issues: inout [LLMAnimationValidationIssue]
    ) {
        if characterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                severity: .error,
                code: .emptyCharacterName,
                message: "Animation plan commands need a non-empty character name."
            ))
        }
    }

    private func validateShotPresetName(
        _ presetName: String,
        issues: inout [LLMAnimationValidationIssue]
    ) {
        if presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                severity: .error,
                code: .emptyShotPresetName,
                message: "Shot preset applications need a non-empty preset name."
            ))
        }
    }

    private func validateFrame(
        _ frame: Int,
        label: String,
        issues: inout [LLMAnimationValidationIssue]
    ) {
        if frame < 0 {
            issues.append(.init(
                severity: .error,
                code: .invalidFrameRange,
                message: "\(label.capitalized) must be zero or greater."
            ))
        }
    }

    private func validatePosition(
        _ position: LLMAnimationPoint,
        label: String,
        issues: inout [LLMAnimationValidationIssue]
    ) {
        if !allowedPositionRange.contains(position.x) || !allowedPositionRange.contains(position.y) {
            issues.append(.init(
                severity: .error,
                code: .invalidPosition,
                message: "\(label) must stay within a reasonable padded normalized range of -0.5...1.5."
            ))
        }
    }

    private func makeTransform(
        position: LLMAnimationPoint,
        facing: FacingDirection,
        zOrder: Int
    ) -> CharacterTransform {
        CharacterTransform(
            x: position.x,
            y: position.y,
            rotation: 0,
            scaleX: facing == .left ? -1 : 1,
            scaleY: 1,
            opacity: 1,
            zOrder: zOrder
        )
    }

    private func facing(from transform: CharacterTransform?) -> FacingDirection {
        guard let transform else { return .camera }
        return transform.scaleX < 0 ? .left : .camera
    }

    private func resolvedEndFrame(
        for motion: LLMCharacterMotion,
        fps: Int,
        startTransform: CharacterTransform
    ) -> Int {
        if let endFrame = motion.endFrame {
            return endFrame
        }

        if let pace = motion.paceUnitsPerSecond, pace > 0 {
            let dx = motion.to.x - startTransform.x
            let dy = motion.to.y - startTransform.y
            let distance = sqrt(dx * dx + dy * dy)
            let durationSeconds = distance / pace
            return motion.startFrame + max(1, Int(round(durationSeconds * Double(fps))))
        }

        return motion.startFrame + fps
    }

    private func panOffset(for movement: CameraMovement) -> (x: Double, y: Double) {
        switch movement {
        case .panLeft:
            return (-0.2, 0)
        case .panRight:
            return (0.2, 0)
        case .panUp:
            return (0, -0.12)
        case .panDown:
            return (0, 0.12)
        default:
            return (0, 0)
        }
    }

    private func inferredViewAngle(from facing: FacingDirection) -> AngleView? {
        switch facing {
        case .camera:
            return .front
        case .left, .right:
            return .side
        case .away:
            return .back
        }
    }

    private func inferredFacing(
        from transform: CharacterTransform,
        to destination: LLMAnimationPoint
    ) -> FacingDirection? {
        let deltaX = destination.x - transform.x
        if deltaX > 0.01 {
            return .right
        }
        if deltaX < -0.01 {
            return .left
        }
        return nil
    }

    private func pose(from movementStyle: String?) -> CharacterPackagePose? {
        guard let normalizedStyle = CharacterRenderSelectionContext.normalize(movementStyle) else {
            return nil
        }

        switch normalizedStyle {
        case "neutral":
            return .neutral
        case "frontal", "front":
            return .frontal
        case "threequarter", "three-quarter", "three_quarter":
            return .threeQuarter
        case "profile", "side":
            return .profile
        case "seated", "sit", "sitting":
            return .seated
        case "walking", "walk", "stride":
            return .walking
        case "pointing", "point":
            return .pointing
        case "action", "run", "gesture":
            return .action
        default:
            return nil
        }
    }
}
