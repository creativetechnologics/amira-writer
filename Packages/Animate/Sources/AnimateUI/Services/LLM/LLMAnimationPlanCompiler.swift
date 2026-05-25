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

        for placement in plan.objectPlacements {
            validateObjectName(placement.objectName, issues: &issues)
            validateFrame(placement.frame, label: "object placement frame", issues: &issues)
            validatePosition(placement.position, label: "\(placement.objectName) placement", issues: &issues)
            validateAttachmentTarget(placement.attachmentTarget, label: "\(placement.objectName) placement attachment", issues: &issues)
            if let opacity = placement.opacity, !(0...1).contains(opacity) {
                issues.append(.init(
                    severity: .error,
                    code: .invalidOpacity,
                    message: "Object opacity for \(placement.objectName) must stay between 0 and 1."
                ))
            }
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

        for motion in plan.objectMotions {
            validateObjectName(motion.objectName, issues: &issues)
            validateFrame(motion.startFrame, label: "object motion start frame", issues: &issues)
            if let endFrame = motion.endFrame, endFrame < motion.startFrame {
                issues.append(.init(
                    severity: .error,
                    code: .invalidFrameRange,
                    message: "Object motion for \(motion.objectName) ends before it starts."
                ))
            }
            if let from = motion.from {
                validatePosition(from, label: "\(motion.objectName) motion start", issues: &issues)
            }
            validatePosition(motion.to, label: "\(motion.objectName) motion destination", issues: &issues)
            validateAttachmentTarget(motion.attachmentTarget, label: "\(motion.objectName) motion attachment", issues: &issues)
            if let pace = motion.paceUnitsPerSecond, pace <= 0 {
                issues.append(.init(
                    severity: .error,
                    code: .invalidPace,
                    message: "Object motion pace for \(motion.objectName) must be greater than zero."
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

        for stateCue in plan.objectStateCues {
            validateObjectName(stateCue.objectName, issues: &issues)
            validateFrame(stateCue.frame, label: "object state frame", issues: &issues)
            validateAttachmentTarget(stateCue.attachmentTarget, label: "\(stateCue.objectName) state attachment", issues: &issues)
            if let opacity = stateCue.opacity, !(0...1).contains(opacity) {
                issues.append(.init(
                    severity: .error,
                    code: .invalidOpacity,
                    message: "Object opacity for \(stateCue.objectName) must stay between 0 and 1."
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
        var latestObjectTransforms: [String: CharacterTransform] = [:]
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

        for placement in plan.objectPlacements.sorted(by: { $0.frame < $1.frame }) {
            let transform = makeObjectTransform(
                position: placement.position,
                zOrder: placement.zOrder ?? 0
            )

            if !compiled.objectSetups.contains(where: { $0.objectName.caseInsensitiveCompare(placement.objectName) == .orderedSame }) {
                compiled.objectSetups.append(ObjectSetup(
                    objectName: placement.objectName,
                    initialX: placement.position.x,
                    initialY: placement.position.y,
                    initialState: placement.state ?? "default",
                    enterFrame: placement.frame,
                    zOrder: placement.zOrder ?? 0,
                    opacity: placement.opacity ?? 1,
                    visible: placement.visible ?? true,
                    attachmentTarget: placement.attachmentTarget
                ))
            }

            compiled.tracks[objectTrackName(placement.objectName, suffix: "transform"), default: []].append(
                TimelineKeyframe(frame: placement.frame, kind: .transform, easing: .linear, value: .transform(transform))
            )

            appendObjectDrawingState(placement.state, objectName: placement.objectName, frame: placement.frame, compiled: &compiled)
            appendObjectVisibility(opacity: placement.opacity, visible: placement.visible, objectName: placement.objectName, frame: placement.frame, compiled: &compiled)
            appendObjectAttachment(placement.attachmentTarget, objectName: placement.objectName, frame: placement.frame, compiled: &compiled)

            latestObjectTransforms[placement.objectName.lowercased()] = transform
            maxFrame = max(maxFrame, placement.frame)
        }

        for motion in plan.objectMotions.sorted(by: { $0.startFrame < $1.startFrame }) {
            let key = motion.objectName.lowercased()
            let startTransform = motion.from.map {
                makeObjectTransform(
                    position: $0,
                    zOrder: motion.zOrder ?? latestObjectTransforms[key]?.zOrder ?? 0
                )
            } ?? latestObjectTransforms[key] ?? makeObjectTransform(
                position: .init(x: 0.5, y: 0.62),
                zOrder: motion.zOrder ?? 0
            )

            let resolvedEndFrame = resolvedEndFrame(
                for: motion,
                fps: fps,
                startTransform: startTransform
            )

            let endTransform = makeObjectTransform(
                position: motion.to,
                zOrder: motion.zOrder ?? startTransform.zOrder
            )

            compiled.tracks[objectTrackName(motion.objectName, suffix: "transform"), default: []].append(contentsOf:
                AnimationEngine.generateMovement(
                    from: startTransform,
                    to: endTransform,
                    startFrame: motion.startFrame,
                    endFrame: resolvedEndFrame,
                    easing: motion.easing.runtimeCurve
                )
            )

            appendObjectDrawingState(motion.state, objectName: motion.objectName, frame: motion.startFrame, compiled: &compiled)
            appendObjectAttachment(motion.attachmentTarget, objectName: motion.objectName, frame: motion.startFrame, compiled: &compiled)

            latestObjectTransforms[key] = endTransform
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

        for stateCue in plan.objectStateCues.sorted(by: { $0.frame < $1.frame }) {
            appendObjectDrawingState(stateCue.state, objectName: stateCue.objectName, frame: stateCue.frame, compiled: &compiled)
            appendObjectVisibility(opacity: stateCue.opacity, visible: stateCue.visible, objectName: stateCue.objectName, frame: stateCue.frame, compiled: &compiled)
            appendObjectAttachment(stateCue.attachmentTarget, objectName: stateCue.objectName, frame: stateCue.frame, compiled: &compiled)
            maxFrame = max(maxFrame, stateCue.frame)
        }

        for presetApplication in plan.shotPresetApplications {
            maxFrame = max(maxFrame, presetApplication.frame)
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

    /// Returns a copy of `plan` with audio paths that are placeholder strings or that do not
    /// resolve to real files on disk replaced with `nil` / empty strings to prevent downstream
    /// audio-loading failures.
    ///
    /// - Parameters:
    ///   - plan: The plan to sanitize.
    ///   - projectRoot: The directory used to resolve relative paths. Pass `nil` to skip
    ///     file-existence checks and only strip known placeholder strings.
    /// - Returns: A sanitized copy of the plan.
    func sanitizingAudioPaths(
        _ plan: LLMAnimationPlan,
        projectRoot: URL?
    ) -> LLMAnimationPlan {
        var sanitized = plan

        // Sanitize top-level sceneAudioPath.
        sanitized.sceneAudioPath = sanitizedAudioPath(plan.sceneAudioPath, projectRoot: projectRoot)

        // Sanitize dialogueBeat audioPath values.  Because LLMDialogueBeat.audioPath is
        // a non-optional String we cannot set individual beats to nil; instead we filter
        // out beats whose audio path is a placeholder or is not present on disk.  The
        // beat's transcript and expression data would be lost, so we only remove the beat
        // when the path is clearly a non-resolvable placeholder — real-but-missing paths
        // are left in place so that validation can surface a proper error message.
        sanitized.dialogueBeats = plan.dialogueBeats.map { beat in
            guard isPlaceholderAudioPath(beat.audioPath) else { return beat }
            // Replace placeholder with empty string; downstream audio loading will skip it
            // cleanly while transcript / expression data is preserved.
            return LLMDialogueBeat(
                characterName: beat.characterName,
                startFrame: beat.startFrame,
                shotID: beat.shotID,
                shotName: beat.shotName,
                frameOffset: beat.frameOffset,
                audioPath: "",
                transcript: beat.transcript,
                expression: beat.expression,
                action: beat.action
            )
        }

        return sanitized
    }

    /// Returns `nil` if `path` is a known placeholder string or if it does not resolve to
    /// an existing file on disk; otherwise returns the original value.
    private func sanitizedAudioPath(_ path: String?, projectRoot: URL?) -> String? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }

        if isPlaceholderAudioPath(path) {
            return nil
        }

        guard let root = projectRoot else {
            // No project root — cannot check file existence; keep the path as-is.
            return path
        }

        let resolvedURL: URL
        if path.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: path)
        } else {
            resolvedURL = root.appendingPathComponent(path)
        }

        return FileManager.default.fileExists(atPath: resolvedURL.path) ? path : nil
    }

    /// Returns `true` for well-known placeholder strings the LLM uses when no real audio
    /// file has been assigned yet.
    private func isPlaceholderAudioPath(_ path: String) -> Bool {
        let lower = path.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower.isEmpty { return true }
        if lower == "placeholder" { return true }
        if lower == "null" { return true }
        // Common LLM-generated fake path patterns, e.g. "audio/dialogue/scene1_luke.mp3"
        // that don't point to a real file hierarchy the app manages.
        let fakePrefixes = ["audio/dialogue/", "audio/scene/", "audio/placeholder"]
        return fakePrefixes.contains { lower.hasPrefix($0) }
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

    private func validateObjectName(
        _ objectName: String,
        issues: inout [LLMAnimationValidationIssue]
    ) {
        if objectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            issues.append(.init(
                severity: .error,
                code: .emptyObjectName,
                message: "Animation plan object commands need a non-empty object name."
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

    private func validateAttachmentTarget(
        _ attachmentTarget: String?,
        label: String,
        issues: inout [LLMAnimationValidationIssue]
    ) {
        guard let attachmentTarget = trimmed(attachmentTarget) else { return }
        if ObjectAttachmentReference.isClearDirective(attachmentTarget) {
            return
        }
        guard ObjectAttachmentReference.parse(attachmentTarget) != nil else {
            issues.append(.init(
                severity: .error,
                code: .invalidAttachmentTarget,
                message: "\(label.capitalized) uses an unsupported attachment target format."
            ))
            return
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

    private func makeObjectTransform(
        position: LLMAnimationPoint,
        zOrder: Int
    ) -> CharacterTransform {
        CharacterTransform(
            x: position.x,
            y: position.y,
            rotation: 0,
            scaleX: 1,
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

    private func resolvedEndFrame(
        for motion: LLMObjectMotion,
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

    private func objectTrackName(_ objectName: String, suffix: String) -> String {
        "object:\(objectName):\(suffix)"
    }

    private func appendObjectDrawingState(
        _ state: String?,
        objectName: String,
        frame: Int,
        compiled: inout CompiledScene
    ) {
        guard let state = trimmed(state) else { return }
        compiled.tracks[objectTrackName(objectName, suffix: "drawing"), default: []].append(
            TimelineKeyframe(
                frame: frame,
                kind: .drawing,
                easing: .stepped,
                value: .expression(name: state)
            )
        )
    }

    private func appendObjectVisibility(
        opacity: Double?,
        visible: Bool?,
        objectName: String,
        frame: Int,
        compiled: inout CompiledScene
    ) {
        guard opacity != nil || visible != nil else { return }
        let resolvedOpacity = max(0, min(1, opacity ?? ((visible ?? true) ? 1 : 0)))
        let resolvedVisible = visible ?? (resolvedOpacity > 0.001)
        compiled.tracks[objectTrackName(objectName, suffix: "visibility"), default: []].append(
            TimelineKeyframe(
                frame: frame,
                kind: .visibility,
                easing: .stepped,
                value: .visibility(opacity: resolvedOpacity, visible: resolvedVisible)
            )
        )
    }

    private func appendObjectAttachment(
        _ attachmentTarget: String?,
        objectName: String,
        frame: Int,
        compiled: inout CompiledScene
    ) {
        guard let attachmentTarget = trimmed(attachmentTarget) else { return }
        let encodedAttachment = ObjectAttachmentReference.isClearDirective(attachmentTarget)
            ? "none"
            : attachmentTarget
        compiled.tracks[objectTrackName(objectName, suffix: "action"), default: []].append(
            TimelineKeyframe(
                frame: frame,
                kind: .expression,
                easing: .stepped,
                value: .expression(name: "attach:\(encodedAttachment)")
            )
        )
    }

    private func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
