import Foundation
import Metal
import simd

@available(macOS 26.0, *)
@MainActor
struct SceneFrameRenderComposer {
    private let packageResolver = CharacterPackageRenderResolver()
    private let rigResolver = CharacterRigRenderResolver()

    private struct CameraSubject {
        let characterID: UUID
        let position: SIMD2<Float>
        let facing: FacingDirection?
        let expression: String?
        let action: String?
        let pose: CharacterPackagePose?
        let movementMagnitude: Double
        let movementDeltaX: Double
    }

    func applyCamera(
        renderer: AnimationRenderer,
        store: AnimateStore,
        scene: AnimationScene,
        frame: Int,
        viewportSize: CGSize
    ) {
        let cameraState = resolvedCameraState(
            store: store,
            scene: scene,
            frame: frame,
            viewportSize: viewportSize
        )
        renderer.cameraOffset = cameraState.offset
        renderer.cameraZoom = cameraState.zoom
    }

    func resolvedCameraState(
        store: AnimateStore,
        scene: AnimationScene,
        frame: Int,
        viewportSize: CGSize
    ) -> (offset: SIMD2<Float>, zoom: Float) {
        if let cameraTransform = store.evaluatedCameraTransform(at: frame) {
            return (
                offset: SIMD2<Float>(
                    Float(cameraTransform.x) * Float(viewportSize.width),
                    Float(cameraTransform.y) * Float(viewportSize.height)
                ),
                zoom: max(
                    0.1,
                    Float((abs(cameraTransform.scaleX) + abs(cameraTransform.scaleY)) / 2.0)
                )
            )
        }

        let fallbackShot = store.evaluatedEffectiveCameraShot(at: frame)
        let fallbackZoom = max(0.1, Float(fallbackShot?.zoomLevel ?? 1.0))
        let fallbackOffset = resolvedTemplateCameraOffset(
            store: store,
            scene: scene,
            frame: frame,
            viewportSize: viewportSize
        )
        return (offset: fallbackOffset, zoom: fallbackZoom)
    }

    func backgroundTexture(
        store: AnimateStore,
        scene: AnimationScene,
        textureProvider: (URL) -> MTLTexture?
    ) -> MTLTexture? {
        guard let backgroundID = scene.backgroundID,
              let background = store.backgrounds.first(where: { $0.id == backgroundID }),
              let sourceURL = background.sourceURL,
              FileManager.default.fileExists(atPath: sourceURL.path)
        else {
            return nil
        }

        return textureProvider(sourceURL)
    }

    func composeDrawItems(
        store: AnimateStore,
        scene: AnimationScene,
        viewportSize: CGSize,
        frame: Int,
        textureProvider: (URL) -> MTLTexture?
    ) -> [AnimationRenderer.DrawItem] {
        var drawItems: [AnimationRenderer.DrawItem] = []

        for (index, charID) in scene.characterIDs.enumerated() {
            guard let character = store.characters.first(where: { $0.id == charID }),
                  let renderState = resolvedRenderState(
                    for: character,
                    index: index,
                    characterCount: scene.characterIDs.count,
                    viewportSize: viewportSize,
                    frame: frame,
                    store: store
                  )
            else {
                continue
            }

            let selection = renderSelection(for: character, store: store, frame: frame)
            let resolvedDrawItems: [AnimationRenderer.DrawItem]

            switch character.resolvedRenderMode {
            case .packagePreview:
                if let renderPlan = packageResolver.resolveRenderPlan(
                    for: character,
                    animateURL: store.animateURL,
                    selection: selection
                ) {
                    resolvedDrawItems = makeDrawItems(
                        for: renderPlan,
                        renderState: renderState,
                        viewportSize: viewportSize,
                        textureProvider: textureProvider
                    )
                } else {
                    resolvedDrawItems = []
                }
            case .rigDrawingSets:
                if let renderPlan = rigResolver.resolveRenderPlan(
                    for: character,
                    animateURL: store.animateURL,
                    selection: selection
                ) {
                    resolvedDrawItems = makeDrawItems(
                        for: renderPlan,
                        renderState: renderState,
                        viewportSize: viewportSize,
                        textureProvider: textureProvider
                    )
                } else {
                    resolvedDrawItems = []
                }
            }

            if !resolvedDrawItems.isEmpty {
                drawItems.append(contentsOf: shadowDrawItems(
                    from: resolvedDrawItems,
                    characterID: character.id,
                    store: store,
                    frame: frame
                ))
                drawItems.append(contentsOf: resolvedDrawItems)
            } else {
                drawItems.append(
                    .init(
                        sprite: SpriteInstance(
                            position: renderState.position,
                            size: scaledSize(
                                fallbackSpriteSize(viewportSize: viewportSize),
                                scale: renderState.scale
                            ),
                            rotation: renderState.rotationRadians,
                            opacity: renderState.opacity,
                            uvOrigin: .zero,
                            uvSize: SIMD2<Float>(1, 1),
                            zOrder: renderState.baseZOrder
                        ),
                        texture: nil
                    )
                )
            }
        }

        return drawItems.sorted { $0.sprite.zOrder < $1.sprite.zOrder }
    }

    private func shadowDrawItems(
        from drawItems: [AnimationRenderer.DrawItem],
        characterID: UUID,
        store: AnimateStore,
        frame: Int
    ) -> [AnimationRenderer.DrawItem] {
        guard let style = store.evaluatedShadowStyle(for: characterID, at: frame),
              style.isVisible
        else {
            return []
        }

        let explicitOpacity = min(
            max(Float(store.evaluatedShadowOpacity(for: characterID, at: frame) ?? 1.0), 0),
            1
        )
        let shadowColor = SIMD4<Float>(0.02, 0.02, 0.03, 1)

        return drawItems.map { item in
            var shadowSprite = item.sprite
            shadowSprite.position += style.offset
            shadowSprite.size = SIMD2<Float>(
                shadowSprite.size.x * style.scale.x,
                shadowSprite.size.y * style.scale.y
            )
            shadowSprite.opacity = shadowSprite.opacity * style.baseOpacity * explicitOpacity
            shadowSprite.zOrder -= 1
            shadowSprite.color = shadowColor
            return AnimationRenderer.DrawItem(sprite: shadowSprite, texture: item.texture)
        }
    }

    private func renderSelection(
        for character: AnimationCharacter,
        store: AnimateStore,
        frame: Int
    ) -> CharacterRenderSelectionContext {
        CharacterRenderSelectionContext(
            preferredAngle: store.evaluatedViewAngle(for: character.id, at: frame) ?? character.preferredViewAngle,
            preferredPose: store.evaluatedPose(for: character.id, at: frame),
            expressionCue: store.evaluatedExpression(for: character.id, at: frame),
            actionCue: store.evaluatedAction(for: character.id, at: frame),
            mouthCue: store.evaluatedMouthCue(for: character.id, at: frame)
        )
    }

    private func resolvedRenderState(
        for character: AnimationCharacter,
        index: Int,
        characterCount: Int,
        viewportSize: CGSize,
        frame: Int,
        store: AnimateStore
    ) -> CharacterRenderState? {
        guard let transform = resolvedCharacterTransform(
            for: character,
            index: index,
            characterCount: characterCount,
            viewportSize: viewportSize,
            frame: frame,
            store: store
        ) else {
            return nil
        }

        if let visibility = store.evaluatedVisibility(for: character.id, at: frame),
           !visibility.visible {
            return nil
        }

        let visibilityOpacity = Float(store.evaluatedVisibility(for: character.id, at: frame)?.opacity ?? 1.0)
        let resolvedOpacity = max(0, Float(transform.opacity) * visibilityOpacity)
        guard resolvedOpacity > 0.001 else { return nil }

        let resolvedZOrder = transform.zOrder == 0 ? index + 1 : transform.zOrder

        return CharacterRenderState(
            position: SIMD2<Float>(
                Float(transform.x) * Float(viewportSize.width),
                Float(transform.y) * Float(viewportSize.height)
            ),
            rotationRadians: Float(transform.rotation * .pi / 180),
            scale: SIMD2<Float>(Float(transform.scaleX), Float(transform.scaleY)),
            opacity: resolvedOpacity,
            baseZOrder: Float(resolvedZOrder) * 100
        )
    }

    private func resolvedCharacterTransform(
        for character: AnimationCharacter,
        index: Int,
        characterCount: Int,
        viewportSize: CGSize,
        frame: Int,
        store: AnimateStore
    ) -> CharacterTransform? {
        let fallbackTransform = fallbackCharacterTransform(
            index: index,
            characterCount: characterCount,
            viewportSize: viewportSize
        )

        let baseTransform: CharacterTransform
        if store.timelineTrack(for: character.id, role: .transform) != nil {
            guard let evaluated = store.evaluatedTransform(for: character.id, at: frame) else {
                return nil
            }
            baseTransform = evaluated
        } else {
            baseTransform = fallbackTransform
        }

        return applyingFacingCue(
            to: baseTransform,
            facing: store.evaluatedFacingDirection(for: character.id, at: frame)
        )
    }

    private func fallbackCharacterTransform(
        index: Int,
        characterCount: Int,
        viewportSize: CGSize
    ) -> CharacterTransform {
        let xSpacing = Float(viewportSize.width) / Float(characterCount + 1)
        return CharacterTransform(
            x: Double(xSpacing * Float(index + 1) / Float(viewportSize.width)),
            y: 0.56,
            rotation: 0,
            scaleX: 1,
            scaleY: 1,
            opacity: 1,
            zOrder: index + 1
        )
    }

    private func applyingFacingCue(
        to transform: CharacterTransform,
        facing: FacingDirection?
    ) -> CharacterTransform {
        guard let facing else { return transform }

        var resolved = transform
        switch facing {
        case .left:
            resolved.scaleX = -abs(resolved.scaleX == 0 ? 1 : resolved.scaleX)
        case .right, .camera, .away:
            resolved.scaleX = abs(resolved.scaleX == 0 ? 1 : resolved.scaleX)
        }
        return resolved
    }

    private func resolvedTemplateCameraOffset(
        store: AnimateStore,
        scene: AnimationScene,
        frame: Int,
        viewportSize: CGSize
    ) -> SIMD2<Float> {
        if let explicitFocusOffset = resolvedExplicitFocusCameraOffset(
            store: store,
            scene: scene,
            frame: frame,
            viewportSize: viewportSize
        ) {
            return explicitFocusOffset
        }

        return resolvedIntentDrivenCameraOffset(
            store: store,
            scene: scene,
            frame: frame,
            viewportSize: viewportSize
        )
    }

    private func resolvedExplicitFocusCameraOffset(
        store: AnimateStore,
        scene: AnimationScene,
        frame: Int,
        viewportSize: CGSize
    ) -> SIMD2<Float>? {
        guard let focusCharacterID = store.evaluatedCameraFocusCharacterID(at: frame),
              let focusIndex = scene.characterIDs.firstIndex(of: focusCharacterID),
              let character = store.characters.first(where: { $0.id == focusCharacterID }),
              let transform = resolvedCharacterTransform(
                for: character,
                index: focusIndex,
                characterCount: scene.characterIDs.count,
                viewportSize: viewportSize,
                frame: frame,
                store: store
              )
        else {
            return nil
        }

        let focusPosition = SIMD2<Float>(
            Float(transform.x) * Float(viewportSize.width),
            Float(transform.y) * Float(viewportSize.height)
        )
        return centeredCameraOffset(
            focusedOn: focusPosition,
            viewportSize: viewportSize,
            bias: .zero
        )
    }

    private func resolvedIntentDrivenCameraOffset(
        store: AnimateStore,
        scene: AnimationScene,
        frame: Int,
        viewportSize: CGSize
    ) -> SIMD2<Float> {
        guard let intent = store.evaluatedCameraShotIntent(at: frame) else {
            return .zero
        }

        let subjects = visibleCameraSubjects(
            store: store,
            scene: scene,
            frame: frame,
            viewportSize: viewportSize
        )
        guard !subjects.isEmpty else { return .zero }

        switch intent {
        case .establishing, .transition:
            return .zero
        case .dialogue, .handoff, .confrontation:
            let rankedSubjects = rankedCameraSubjects(subjects, for: intent)
            guard let first = rankedSubjects.first else { return .zero }
            if rankedSubjects.count > 1 {
                let second = rankedSubjects[1]
                let midpoint = (first.position + second.position) / 2
                return centeredCameraOffset(
                    focusedOn: midpoint,
                    viewportSize: viewportSize,
                    bias: .zero
                )
            }
            return centeredCameraOffset(
                focusedOn: first.position,
                viewportSize: viewportSize,
                bias: .zero
            )
        case .movement, .reaction, .reveal, .insert, .emotional:
            guard let subject = rankedCameraSubjects(subjects, for: intent).first else {
                return .zero
            }
            return centeredCameraOffset(
                focusedOn: subject.position,
                viewportSize: viewportSize,
                bias: intentCameraBias(
                    for: subject,
                    intent: intent,
                    viewportSize: viewportSize,
                    suggestedMovement: store.recommendedCameraMovementFromIntent(at: frame)
                )
            )
        }
    }

    private func visibleCameraSubjects(
        store: AnimateStore,
        scene: AnimationScene,
        frame: Int,
        viewportSize: CGSize
    ) -> [CameraSubject] {
        scene.characterIDs.enumerated().compactMap { index, characterID in
            guard let character = store.characters.first(where: { $0.id == characterID }),
                  let transform = resolvedCharacterTransform(
                    for: character,
                    index: index,
                    characterCount: scene.characterIDs.count,
                    viewportSize: viewportSize,
                    frame: frame,
                    store: store
                  )
            else {
                return nil
            }

            if let visibility = store.evaluatedVisibility(for: characterID, at: frame),
               !visibility.visible {
                return nil
            }

            let currentX = transform.x
            let currentY = transform.y
            let previousTransform = store.evaluatedTransform(for: characterID, at: max(frame - 1, 0))
            let nextTransform = store.evaluatedTransform(for: characterID, at: frame + 1)
            let previousX = previousTransform?.x ?? currentX
            let previousY = previousTransform?.y ?? currentY
            let nextX = nextTransform?.x ?? currentX
            let nextY = nextTransform?.y ?? currentY
            let deltaX = nextX - previousX
            let deltaY = nextY - previousY

            return CameraSubject(
                characterID: characterID,
                position: SIMD2<Float>(
                    Float(currentX) * Float(viewportSize.width),
                    Float(currentY) * Float(viewportSize.height)
                ),
                facing: store.evaluatedFacingDirection(for: characterID, at: frame),
                expression: store.evaluatedExpression(for: characterID, at: frame),
                action: store.evaluatedAction(for: characterID, at: frame),
                pose: store.evaluatedPose(for: characterID, at: frame),
                movementMagnitude: sqrt(deltaX * deltaX + deltaY * deltaY),
                movementDeltaX: deltaX
            )
        }
    }

    private func rankedCameraSubjects(
        _ subjects: [CameraSubject],
        for intent: ShotIntent
    ) -> [CameraSubject] {
        subjects.sorted { lhs, rhs in
            let lhsScore = cameraSubjectScore(lhs, for: intent)
            let rhsScore = cameraSubjectScore(rhs, for: intent)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return lhs.characterID.uuidString < rhs.characterID.uuidString
        }
    }

    private func cameraSubjectScore(
        _ subject: CameraSubject,
        for intent: ShotIntent
    ) -> Double {
        var score = 0.0

        if let expression = subject.expression,
           !expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 3
        }

        if let action = subject.action,
           !action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 2
            let normalizedAction = action.lowercased()
            if normalizedAction.contains("walk") || normalizedAction.contains("run") || normalizedAction.contains("move") {
                score += 2
            }
        }

        if let pose = subject.pose {
            score += 1
            if pose == .walking {
                score += 2
            }
        }

        switch intent {
        case .movement:
            score += subject.movementMagnitude * 100
        case .reaction, .reveal, .insert, .emotional:
            if subject.facing == .camera {
                score += 1
            }
        case .dialogue, .handoff, .confrontation:
            score += min(subject.movementMagnitude * 30, 1.5)
        case .establishing, .transition:
            break
        }

        return score
    }

    private func intentCameraBias(
        for subject: CameraSubject,
        intent: ShotIntent,
        viewportSize: CGSize,
        suggestedMovement: CameraMovement?
    ) -> SIMD2<Float> {
        guard suggestedMovement == .track, intent == .movement || intent == .handoff else {
            return .zero
        }

        let horizontalLead = Float(viewportSize.width) * 0.08
        if subject.movementDeltaX > 0.0005 {
            return SIMD2<Float>(horizontalLead, 0)
        }
        if subject.movementDeltaX < -0.0005 {
            return SIMD2<Float>(-horizontalLead, 0)
        }

        switch subject.facing {
        case .right:
            return SIMD2<Float>(horizontalLead, 0)
        case .left:
            return SIMD2<Float>(-horizontalLead, 0)
        case .camera, .away, .none:
            return .zero
        }
    }

    private func centeredCameraOffset(
        focusedOn position: SIMD2<Float>,
        viewportSize: CGSize,
        bias: SIMD2<Float>
    ) -> SIMD2<Float> {
        let viewportCenter = SIMD2<Float>(
            Float(viewportSize.width) / 2,
            Float(viewportSize.height) / 2
        )
        return position - viewportCenter + bias
    }

    private func fallbackSpriteSize(viewportSize: CGSize) -> SIMD2<Float> {
        let targetHeight = Float(min(max(viewportSize.height * 0.42, 220), 420))
        return SIMD2<Float>(targetHeight * 0.65, targetHeight)
    }

    private func packageCanvasSize(
        for renderPlan: CharacterPackageResolvedRenderPlan,
        viewportSize: CGSize
    ) -> SIMD2<Float> {
        resolvedCanvasSize(
            packageCanvasSizeHint: renderPlan.package.manifest.defaults.defaultCanvasSize,
            viewportSize: viewportSize
        )
    }

    private func rigCanvasSize(
        for renderPlan: CharacterRigResolvedRenderPlan,
        viewportSize: CGSize
    ) -> SIMD2<Float> {
        resolvedCanvasSize(
            packageCanvasSizeHint: renderPlan.packageCanvasSizeHint,
            viewportSize: viewportSize
        )
    }

    private func resolvedCanvasSize(
        packageCanvasSizeHint: CharacterPackageCanvasSize?,
        viewportSize: CGSize
    ) -> SIMD2<Float> {
        let targetHeight = Float(min(max(viewportSize.height * 0.42, 220), 420))

        if let packageCanvasSizeHint,
           packageCanvasSizeHint.width > 0,
           packageCanvasSizeHint.height > 0 {
            let aspectRatio = Float(packageCanvasSizeHint.width) / Float(packageCanvasSizeHint.height)
            return SIMD2<Float>(max(120, targetHeight * aspectRatio), targetHeight)
        }

        let fallbackWidth = max(Float(viewportSize.width) * 0.18, targetHeight * 0.78)
        return SIMD2<Float>(fallbackWidth, targetHeight)
    }

    private func makeDrawItems(
        for renderPlan: CharacterPackageResolvedRenderPlan,
        renderState: CharacterRenderState,
        viewportSize: CGSize,
        textureProvider: (URL) -> MTLTexture?
    ) -> [AnimationRenderer.DrawItem] {
        let fullCanvasSize = packageCanvasSize(for: renderPlan, viewportSize: viewportSize)

        switch renderPlan.mode {
        case .wholeCharacter:
            guard let layer = renderPlan.layers.first else { return [] }
            guard let drawItem = makeDrawItem(
                for: layer,
                renderState: renderState,
                fullCanvasSize: fullCanvasSize,
                baseZOrder: renderState.baseZOrder,
                textureProvider: textureProvider
            ) else {
                return []
            }
            return [drawItem]
        case .layeredParts:
            return renderPlan.layers.compactMap { layer in
                makeDrawItem(
                    for: layer,
                    renderState: renderState,
                    fullCanvasSize: fullCanvasSize,
                    baseZOrder: renderState.baseZOrder + layer.zOrder,
                    textureProvider: textureProvider
                )
            }
        }
    }

    private func makeDrawItems(
        for renderPlan: CharacterRigResolvedRenderPlan,
        renderState: CharacterRenderState,
        viewportSize: CGSize,
        textureProvider: (URL) -> MTLTexture?
    ) -> [AnimationRenderer.DrawItem] {
        let fullCanvasSize = rigCanvasSize(for: renderPlan, viewportSize: viewportSize)

        return renderPlan.layers.compactMap { layer in
            makeDrawItem(
                for: layer,
                renderState: renderState,
                fullCanvasSize: fullCanvasSize,
                baseZOrder: renderState.baseZOrder + layer.zOrder,
                textureProvider: textureProvider
            )
        }
    }

    private func makeDrawItem(
        for layer: CharacterPackageResolvedLayer,
        renderState: CharacterRenderState,
        fullCanvasSize: SIMD2<Float>,
        baseZOrder: Float,
        textureProvider: (URL) -> MTLTexture?
    ) -> AnimationRenderer.DrawItem? {
        let texture = textureProvider(layer.assetURL)
        let baseSize = layer.usesFullCanvasPlacement
            ? fullCanvasSize
            : layeredSpriteSize(
                normalizedSizeHint: layer.normalizedSizeHint,
                texture: texture,
                baseWidth: fullCanvasSize.x,
                targetHeight: fullCanvasSize.y
            )
        let size = scaledSize(baseSize, scale: renderState.scale)
        guard abs(size.x) > 0, abs(size.y) > 0 else { return nil }

        let position = layer.usesFullCanvasPlacement
            ? renderState.position
            : transformedLayerPosition(
                basePosition: renderState.position,
                normalizedCenter: layer.normalizedCenter,
                fullCanvasSize: fullCanvasSize,
                scale: renderState.scale,
                rotationRadians: renderState.rotationRadians
            )

        return AnimationRenderer.DrawItem(
            sprite: SpriteInstance(
                position: position,
                size: size,
                rotation: renderState.rotationRadians,
                opacity: renderState.opacity,
                uvOrigin: .zero,
                uvSize: SIMD2<Float>(1, 1),
                zOrder: baseZOrder
            ),
            texture: texture
        )
    }

    private func makeDrawItem(
        for layer: CharacterRigResolvedLayer,
        renderState: CharacterRenderState,
        fullCanvasSize: SIMD2<Float>,
        baseZOrder: Float,
        textureProvider: (URL) -> MTLTexture?
    ) -> AnimationRenderer.DrawItem? {
        let texture = textureProvider(layer.assetURL)
        let baseSize = layer.usesFullCanvasPlacement
            ? fullCanvasSize
            : layeredSpriteSize(
                normalizedSizeHint: layer.normalizedSizeHint,
                texture: texture,
                baseWidth: fullCanvasSize.x,
                targetHeight: fullCanvasSize.y
            )
        let size = scaledSize(baseSize, scale: renderState.scale)
        guard abs(size.x) > 0, abs(size.y) > 0 else { return nil }

        let position = layer.usesFullCanvasPlacement
            ? renderState.position
            : transformedLayerPosition(
                basePosition: renderState.position,
                normalizedCenter: layer.normalizedCenter,
                fullCanvasSize: fullCanvasSize,
                scale: renderState.scale,
                rotationRadians: renderState.rotationRadians
            )

        return AnimationRenderer.DrawItem(
            sprite: SpriteInstance(
                position: position,
                size: size,
                rotation: renderState.rotationRadians,
                opacity: renderState.opacity,
                uvOrigin: .zero,
                uvSize: SIMD2<Float>(1, 1),
                zOrder: baseZOrder
            ),
            texture: texture
        )
    }

    private func layeredSpriteSize(
        normalizedSizeHint: SIMD2<Float>,
        texture: MTLTexture?,
        baseWidth: Float,
        targetHeight: Float
    ) -> SIMD2<Float> {
        let hintedWidth = max(1, baseWidth * normalizedSizeHint.x)
        let hintedHeight = max(1, targetHeight * normalizedSizeHint.y)

        guard let texture else {
            return SIMD2<Float>(hintedWidth, hintedHeight)
        }

        let textureAspect = Float(texture.width) / max(Float(texture.height), 1)
        let hintedAspect = hintedWidth / max(hintedHeight, 1)

        if textureAspect > hintedAspect {
            return SIMD2<Float>(hintedWidth, hintedWidth / max(textureAspect, 0.001))
        }

        return SIMD2<Float>(hintedHeight * textureAspect, hintedHeight)
    }

    private func scaledSize(
        _ size: SIMD2<Float>,
        scale: SIMD2<Float>
    ) -> SIMD2<Float> {
        SIMD2<Float>(size.x * scale.x, size.y * scale.y)
    }

    private func transformedLayerPosition(
        basePosition: SIMD2<Float>,
        normalizedCenter: SIMD2<Float>,
        fullCanvasSize: SIMD2<Float>,
        scale: SIMD2<Float>,
        rotationRadians: Float
    ) -> SIMD2<Float> {
        let rawOffset = SIMD2<Float>(
            (normalizedCenter.x - 0.5) * fullCanvasSize.x,
            (0.5 - normalizedCenter.y) * fullCanvasSize.y
        )
        let scaledOffset = SIMD2<Float>(
            rawOffset.x * scale.x,
            rawOffset.y * scale.y
        )
        return basePosition + rotated(scaledOffset, by: rotationRadians)
    }

    private func rotated(
        _ vector: SIMD2<Float>,
        by radians: Float
    ) -> SIMD2<Float> {
        let cosValue = cos(radians)
        let sinValue = sin(radians)
        return SIMD2<Float>(
            vector.x * cosValue - vector.y * sinValue,
            vector.x * sinValue + vector.y * cosValue
        )
    }
}

@available(macOS 26.0, *)
private struct CharacterRenderState {
    var position: SIMD2<Float>
    var rotationRadians: Float
    var scale: SIMD2<Float>
    var opacity: Float
    var baseZOrder: Float
}
