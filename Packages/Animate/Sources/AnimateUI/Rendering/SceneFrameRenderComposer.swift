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
        viewportSize: CGSize,
        placeholderOnly: Bool = false
    ) {
        let cameraState = placeholderOnly
            ? resolvedPlaceholderCameraState(
                store: store,
                scene: scene,
                frame: frame,
                viewportSize: viewportSize
            )
            : resolvedCameraState(
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

    func resolvedPlaceholderCameraState(
        store: AnimateStore,
        scene: AnimationScene,
        frame: Int,
        viewportSize: CGSize
    ) -> (offset: SIMD2<Float>, zoom: Float) {
        let fallbackShot = store.evaluatedEffectiveCameraShot(at: frame)
        let fallbackOffset = resolvedTemplateCameraOffset(
            store: store,
            scene: scene,
            frame: frame,
            viewportSize: viewportSize
        )
        let maxOffsetX = Float(viewportSize.width) * 0.18
        let maxOffsetY = Float(viewportSize.height) * 0.14
        return (
            offset: SIMD2<Float>(
                max(-maxOffsetX, min(fallbackOffset.x, maxOffsetX)),
                max(-maxOffsetY, min(fallbackOffset.y, maxOffsetY))
            ),
            zoom: min(max(0.72, Float(fallbackShot?.zoomLevel ?? 1.0)), 1.45)
        )
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
        placeholderOnly: Bool = false,
        textureProvider: (URL) -> MTLTexture?
    ) -> [AnimationRenderer.DrawItem] {
        var drawItems: [AnimationRenderer.DrawItem] = []

        if placeholderOnly {
            drawItems.append(contentsOf: placeholderStageBackdrop(viewportSize: viewportSize))
        }

        for object in scene.objectSetups {
            guard let renderState = resolvedObjectRenderState(
                for: object,
                scene: scene,
                viewportSize: viewportSize,
                frame: frame,
                store: store
            ) else {
                continue
            }

            let drawingState = resolvedObjectDrawingState(
                for: object,
                frame: frame,
                store: store
            )
            let texture = placeholderOnly
                ? nil
                : resolvedObjectTexture(
                    for: object,
                    drawingState: drawingState,
                    store: store,
                    textureProvider: textureProvider
                )

            if let drawItem = makeObjectDrawItem(
                texture: texture,
                renderState: renderState,
                viewportSize: viewportSize,
                color: texture == nil
                    ? (placeholderOnly
                        ? SIMD4<Float>(0.68, 0.46, 0.18, 1)
                        : SIMD4<Float>(0.72, 0.58, 0.36, 1))
                    : SIMD4<Float>(1, 1, 1, 1)
            ) {
                drawItems.append(drawItem)
            }
        }

        for (index, charID) in scene.characterIDs.enumerated() {
            guard let character = store.characters.first(where: { $0.id == charID }) else {
                continue
            }
            let renderState = resolvedRenderState(
                for: character,
                index: index,
                characterCount: scene.characterIDs.count,
                viewportSize: viewportSize,
                frame: frame,
                store: store
            ) ?? (placeholderOnly
                ? resolvedPlaceholderRenderState(
                    for: character,
                    index: index,
                    characterCount: scene.characterIDs.count,
                    viewportSize: viewportSize,
                    frame: frame,
                    store: store
                )
                : nil)
            guard let renderState else { continue }

            let selection = renderSelection(for: character, store: store, frame: frame)
            let resolvedDrawItems: [AnimationRenderer.DrawItem]

            if placeholderOnly {
                resolvedDrawItems = makePlaceholderCharacterDrawItems(
                    character: character,
                    index: index,
                    renderState: renderState,
                    viewportSize: viewportSize
                )
            } else {
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

    private func placeholderStageBackdrop(viewportSize: CGSize) -> [AnimationRenderer.DrawItem] {
        let width = Float(viewportSize.width)
        let height = Float(viewportSize.height)
        guard width > 1, height > 1 else { return [] }

        return [
            AnimationRenderer.DrawItem(
                sprite: SpriteInstance(
                    position: SIMD2<Float>(width * 0.5, height * 0.58),
                    size: SIMD2<Float>(width * 0.9, height * 0.44),
                    rotation: 0,
                    opacity: 0.7,
                    uvOrigin: .zero,
                    uvSize: SIMD2<Float>(1, 1),
                    zOrder: 0.2,
                    color: SIMD4<Float>(0.14, 0.17, 0.24, 1)
                ),
                texture: nil
            ),
            AnimationRenderer.DrawItem(
                sprite: SpriteInstance(
                    position: SIMD2<Float>(width * 0.5, height * 0.84),
                    size: SIMD2<Float>(width * 0.82, height * 0.18),
                    rotation: 0,
                    opacity: 0.94,
                    uvOrigin: .zero,
                    uvSize: SIMD2<Float>(1, 1),
                    zOrder: 0.25,
                    color: SIMD4<Float>(0.24, 0.27, 0.34, 1)
                ),
                texture: nil
            )
        ]
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

    private func resolvedPlaceholderRenderState(
        for character: AnimationCharacter,
        index: Int,
        characterCount: Int,
        viewportSize: CGSize,
        frame: Int,
        store: AnimateStore
    ) -> CharacterRenderState? {
        if let visibility = store.evaluatedVisibility(for: character.id, at: frame),
           !visibility.visible {
            return nil
        }

        let transform = resolvedCharacterTransform(
            for: character,
            index: index,
            characterCount: characterCount,
            viewportSize: viewportSize,
            frame: frame,
            store: store
        ) ?? applyingFacingCue(
            to: fallbackCharacterTransform(
                index: index,
                characterCount: characterCount,
                viewportSize: viewportSize
            ),
            facing: store.evaluatedFacingDirection(for: character.id, at: frame)
        )

        let visibilityOpacity = Float(store.evaluatedVisibility(for: character.id, at: frame)?.opacity ?? 1.0)
        let resolvedOpacity = max(0.35, Float(transform.opacity) * max(visibilityOpacity, 0.5))
        let resolvedZOrder = transform.zOrder == 0 ? index + 1 : transform.zOrder

        return CharacterRenderState(
            position: SIMD2<Float>(
                Float(transform.x) * Float(viewportSize.width),
                Float(transform.y) * Float(viewportSize.height)
            ),
            rotationRadians: Float(transform.rotation * .pi / 180),
            scale: SIMD2<Float>(Float(transform.scaleX), Float(transform.scaleY)),
            opacity: min(resolvedOpacity, 1),
            baseZOrder: Float(resolvedZOrder) * 100
        )
    }

    private func makePlaceholderCharacterDrawItems(
        character: AnimationCharacter,
        index: Int,
        renderState: CharacterRenderState,
        viewportSize: CGSize
    ) -> [AnimationRenderer.DrawItem] {
        let baseSize = scaledSize(
            fallbackSpriteSize(viewportSize: viewportSize),
            scale: SIMD2<Float>(abs(renderState.scale.x), abs(renderState.scale.y))
        )
        let baseColor = placeholderPaletteColor(index: index)
        let accentColor = SIMD4<Float>(
            min(baseColor.x + 0.18, 1),
            min(baseColor.y + 0.18, 1),
            min(baseColor.z + 0.18, 1),
            1
        )
        let shadowSize = SIMD2<Float>(
            max(baseSize.x * 0.86, 54),
            max(baseSize.y * 0.12, 18)
        )
        let bodySize = SIMD2<Float>(
            max(baseSize.x * 0.5, 56),
            max(baseSize.y * 0.64, 132)
        )
        let headSize = SIMD2<Float>(
            max(baseSize.x * 0.32, 42),
            max(baseSize.y * 0.2, 44)
        )
        let accentSize = SIMD2<Float>(
            max(bodySize.x * 0.22, 14),
            max(bodySize.y * 0.72, 56)
        )
        let horizontalDirection: Float = renderState.scale.x < 0 ? -1 : 1
        let shadowPosition = renderState.position + SIMD2<Float>(0, baseSize.y * 0.44)
        let bodyPosition = renderState.position + SIMD2<Float>(0, baseSize.y * 0.04)
        let headPosition = renderState.position + SIMD2<Float>(0, -baseSize.y * 0.32)
        let accentPosition = bodyPosition + SIMD2<Float>(bodySize.x * 0.2 * horizontalDirection, 0)
        let shadowOpacity = min(renderState.opacity * 0.5, 0.5)

        return [
            AnimationRenderer.DrawItem(
                sprite: SpriteInstance(
                    position: shadowPosition,
                    size: shadowSize,
                    rotation: 0,
                    opacity: shadowOpacity,
                    uvOrigin: .zero,
                    uvSize: SIMD2<Float>(1, 1),
                    zOrder: renderState.baseZOrder - 0.4,
                    color: SIMD4<Float>(0.03, 0.03, 0.05, 1)
                ),
                texture: nil
            ),
            AnimationRenderer.DrawItem(
                sprite: SpriteInstance(
                    position: bodyPosition,
                    size: bodySize,
                    rotation: renderState.rotationRadians,
                    opacity: renderState.opacity,
                    uvOrigin: .zero,
                    uvSize: SIMD2<Float>(1, 1),
                    zOrder: renderState.baseZOrder,
                    color: baseColor
                ),
                texture: nil
            ),
            AnimationRenderer.DrawItem(
                sprite: SpriteInstance(
                    position: accentPosition,
                    size: accentSize,
                    rotation: renderState.rotationRadians,
                    opacity: renderState.opacity,
                    uvOrigin: .zero,
                    uvSize: SIMD2<Float>(1, 1),
                    zOrder: renderState.baseZOrder + 0.05,
                    color: SIMD4<Float>(0.08, 0.1, 0.14, 1)
                ),
                texture: nil
            ),
            AnimationRenderer.DrawItem(
                sprite: SpriteInstance(
                    position: headPosition,
                    size: headSize,
                    rotation: renderState.rotationRadians,
                    opacity: renderState.opacity,
                    uvOrigin: .zero,
                    uvSize: SIMD2<Float>(1, 1),
                    zOrder: renderState.baseZOrder + 0.1,
                    color: accentColor
                ),
                texture: nil
            )
        ]
    }

    private func placeholderPaletteColor(index: Int) -> SIMD4<Float> {
        let palette: [SIMD4<Float>] = [
            SIMD4<Float>(0.43, 0.69, 0.98, 1),
            SIMD4<Float>(0.94, 0.54, 0.37, 1),
            SIMD4<Float>(0.61, 0.83, 0.58, 1),
            SIMD4<Float>(0.82, 0.58, 0.96, 1),
            SIMD4<Float>(0.98, 0.78, 0.38, 1),
            SIMD4<Float>(0.45, 0.84, 0.86, 1)
        ]
        return palette[index % palette.count]
    }

    private func resolvedObjectRenderState(
        for object: ObjectSetup,
        scene: AnimationScene,
        viewportSize: CGSize,
        frame: Int,
        store: AnimateStore
    ) -> SceneObjectRenderState? {
        guard frame >= object.enterFrame else { return nil }
        if let exitFrame = object.exitFrame, frame > exitFrame {
            return nil
        }

        let baseTransform = store.evaluatedObjectTransform(for: object.objectName, at: frame)
            ?? CharacterTransform(
                x: object.initialX,
                y: object.initialY,
                rotation: 0,
                scaleX: 1,
                scaleY: 1,
                opacity: 1,
                zOrder: object.zOrder
            )

        let visibility = store.evaluatedObjectVisibility(for: object.objectName, at: frame)
            ?? (opacity: object.opacity, visible: object.visible)
        guard visibility.visible else { return nil }

        let resolvedOpacity = min(
            max(Float(baseTransform.opacity) * Float(object.opacity) * Float(visibility.opacity), 0),
            1
        )
        guard resolvedOpacity > 0.001 else { return nil }

        let attachmentTarget = resolvedObjectAttachmentTarget(
            for: object,
            frame: frame,
            store: store
        )
        let resolvedTransform = resolvedObjectWorldTransform(
            for: object,
            baseTransform: baseTransform,
            attachmentTarget: attachmentTarget,
            scene: scene,
            viewportSize: viewportSize,
            frame: frame,
            store: store
        )

        return SceneObjectRenderState(
            position: SIMD2<Float>(
                Float(resolvedTransform.x) * Float(viewportSize.width),
                Float(resolvedTransform.y) * Float(viewportSize.height)
            ),
            rotationRadians: Float(resolvedTransform.rotation * .pi / 180),
            scale: SIMD2<Float>(Float(resolvedTransform.scaleX), Float(resolvedTransform.scaleY)),
            opacity: resolvedOpacity,
            baseZOrder: Float(resolvedTransform.zOrder) * 100
        )
    }

    private func resolvedObjectWorldTransform(
        for object: ObjectSetup,
        baseTransform: CharacterTransform,
        attachmentTarget: String?,
        scene: AnimationScene,
        viewportSize: CGSize,
        frame: Int,
        store: AnimateStore,
        visitedObjectNames: Set<String> = []
    ) -> CharacterTransform {
        guard let attachment = ObjectAttachmentReference.parse(attachmentTarget),
              let anchoredTransform = resolvedAttachedObjectTransform(
                for: object,
                baseTransform: baseTransform,
                attachment: attachment,
                scene: scene,
                viewportSize: viewportSize,
                frame: frame,
                store: store,
                visitedObjectNames: visitedObjectNames.union([object.objectName.lowercased()])
              )
        else {
            return baseTransform
        }

        return anchoredTransform
    }

    private func resolvedAttachedObjectTransform(
        for object: ObjectSetup,
        baseTransform: CharacterTransform,
        attachment: ObjectAttachmentReference,
        scene: AnimationScene,
        viewportSize: CGSize,
        frame: Int,
        store: AnimateStore,
        visitedObjectNames: Set<String>
    ) -> CharacterTransform? {
        switch attachment.kind {
        case .character:
            return resolvedCharacterAttachedObjectTransform(
                for: object,
                baseTransform: baseTransform,
                targetName: attachment.targetName,
                anchor: attachment.anchor,
                scene: scene,
                viewportSize: viewportSize,
                frame: frame,
                store: store
            )
        case .object:
            return resolvedObjectAttachedToObjectTransform(
                for: object,
                baseTransform: baseTransform,
                targetObjectName: attachment.targetName,
                anchor: attachment.anchor,
                scene: scene,
                viewportSize: viewportSize,
                frame: frame,
                store: store,
                visitedObjectNames: visitedObjectNames
            )
        case .world:
            return resolvedWorldAttachedObjectTransform(
                for: object,
                baseTransform: baseTransform,
                anchorName: attachment.targetName,
                attachmentAnchor: attachment.anchor
            )
        }
    }

    private func resolvedCharacterAttachedObjectTransform(
        for object: ObjectSetup,
        baseTransform: CharacterTransform,
        targetName: String,
        anchor: String?,
        scene: AnimationScene,
        viewportSize: CGSize,
        frame: Int,
        store: AnimateStore
    ) -> CharacterTransform? {
        let normalizedTarget = targetName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedTarget.isEmpty else { return nil }

        var anchoredCharacter: (index: Int, character: AnimationCharacter)?
        for (index, characterID) in scene.characterIDs.enumerated() {
            guard let character = store.characters.first(where: { $0.id == characterID }) else {
                continue
            }
            let matches = character.owpSlug.lowercased() == normalizedTarget ||
                character.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTarget ||
                character.assetFolderSlug.lowercased() == normalizedTarget ||
                characterID.uuidString.lowercased() == normalizedTarget
            if matches {
                anchoredCharacter = (index: index, character: character)
                break
            }
        }

        guard let anchoredCharacter else {
            return nil
        }

        guard let characterTransform = resolvedCharacterTransform(
            for: anchoredCharacter.character,
            index: anchoredCharacter.index,
            characterCount: scene.characterIDs.count,
            viewportSize: viewportSize,
            frame: frame,
            store: store
        ) else {
            return nil
        }

        let facing = store.evaluatedFacingDirection(for: anchoredCharacter.character.id, at: frame)
            ?? .camera
        let attachmentOffset = characterAttachmentOffset(anchor: anchor, facing: facing)
        let localOffsetX = baseTransform.x - object.initialX
        let localOffsetY = baseTransform.y - object.initialY

        return CharacterTransform(
            x: characterTransform.x + attachmentOffset.x + localOffsetX,
            y: characterTransform.y + attachmentOffset.y + localOffsetY,
            rotation: baseTransform.rotation,
            scaleX: baseTransform.scaleX,
            scaleY: baseTransform.scaleY,
            opacity: baseTransform.opacity,
            zOrder: max(baseTransform.zOrder, characterTransform.zOrder + 1)
        )
    }

    private func resolvedObjectAttachedToObjectTransform(
        for object: ObjectSetup,
        baseTransform: CharacterTransform,
        targetObjectName: String,
        anchor: String?,
        scene: AnimationScene,
        viewportSize: CGSize,
        frame: Int,
        store: AnimateStore,
        visitedObjectNames: Set<String>
    ) -> CharacterTransform? {
        let normalizedTarget = targetObjectName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedTarget.isEmpty,
              normalizedTarget != object.objectName.lowercased(),
              !visitedObjectNames.contains(normalizedTarget),
              let targetObject = scene.objectSetups.first(where: {
                  $0.objectName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedTarget
              }) else {
            return nil
        }

        let targetBaseTransform = store.evaluatedObjectTransform(for: targetObject.objectName, at: frame)
            ?? CharacterTransform(
                x: targetObject.initialX,
                y: targetObject.initialY,
                rotation: 0,
                scaleX: 1,
                scaleY: 1,
                opacity: 1,
                zOrder: targetObject.zOrder
            )
        let targetAttachment = resolvedObjectAttachmentTarget(for: targetObject, frame: frame, store: store)
        let targetWorldTransform = resolvedObjectWorldTransform(
            for: targetObject,
            baseTransform: targetBaseTransform,
            attachmentTarget: targetAttachment,
            scene: scene,
            viewportSize: viewportSize,
            frame: frame,
            store: store,
            visitedObjectNames: visitedObjectNames.union([normalizedTarget])
        )

        let attachmentOffset = objectAttachmentOffset(anchor: anchor)
        let localOffsetX = baseTransform.x - object.initialX
        let localOffsetY = baseTransform.y - object.initialY

        return CharacterTransform(
            x: targetWorldTransform.x + attachmentOffset.x + localOffsetX,
            y: targetWorldTransform.y + attachmentOffset.y + localOffsetY,
            rotation: baseTransform.rotation,
            scaleX: baseTransform.scaleX,
            scaleY: baseTransform.scaleY,
            opacity: baseTransform.opacity,
            zOrder: max(baseTransform.zOrder, targetWorldTransform.zOrder + 1)
        )
    }

    private func resolvedWorldAttachedObjectTransform(
        for object: ObjectSetup,
        baseTransform: CharacterTransform,
        anchorName: String,
        attachmentAnchor: String?
    ) -> CharacterTransform? {
        let worldPoint = worldAttachmentPoint(named: anchorName, variant: attachmentAnchor)
        let localOffsetX = baseTransform.x - object.initialX
        let localOffsetY = baseTransform.y - object.initialY
        return CharacterTransform(
            x: worldPoint.x + localOffsetX,
            y: worldPoint.y + localOffsetY,
            rotation: baseTransform.rotation,
            scaleX: baseTransform.scaleX,
            scaleY: baseTransform.scaleY,
            opacity: baseTransform.opacity,
            zOrder: baseTransform.zOrder
        )
    }

    private func resolvedObjectAttachmentTarget(
        for object: ObjectSetup,
        frame: Int,
        store: AnimateStore
    ) -> String? {
        if let cue = store.evaluatedObjectCue(for: object.objectName, role: .action, at: frame),
           cue.lowercased().hasPrefix("attach:") {
            let target = String(cue.dropFirst("attach:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !target.isEmpty {
                return target
            }
        }

        return object.attachmentTarget?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func characterAttachmentOffset(
        anchor: String?,
        facing: FacingDirection
    ) -> (x: Double, y: Double) {
        let normalizedAnchor = anchor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        var offset: (x: Double, y: Double)
        switch normalizedAnchor {
        case "center", nil:
            offset = (0.06, -0.025)
        case "hand_right", "right_hand":
            offset = (0.065, -0.02)
        case "hand_left", "left_hand":
            offset = (-0.065, -0.02)
        case "head", "head_top":
            offset = (0, -0.14)
        case "belt", "waist":
            offset = (0, 0.02)
        case "shoulder_right", "right_shoulder":
            offset = (0.045, -0.085)
        case "shoulder_left", "left_shoulder":
            offset = (-0.045, -0.085)
        default:
            offset = (0.06, -0.025)
        }

        switch facing {
        case .left:
            return (-offset.x, offset.y)
        case .right, .camera, .away:
            return offset
        }
    }

    private func objectAttachmentOffset(anchor: String?) -> (x: Double, y: Double) {
        switch anchor?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() {
        case "top":
            return (0, -0.06)
        case "bottom":
            return (0, 0.06)
        case "left":
            return (-0.06, 0)
        case "right":
            return (0.06, 0)
        case "top_left":
            return (-0.05, -0.05)
        case "top_right":
            return (0.05, -0.05)
        case "bottom_left":
            return (-0.05, 0.05)
        case "bottom_right":
            return (0.05, 0.05)
        default:
            return (0, 0)
        }
    }

    private func worldAttachmentPoint(named rawName: String, variant: String?) -> (x: Double, y: Double) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "center", "center_air":
            return (0.5, 0.42)
        case "center_floor":
            return (0.5, 0.72)
        case "left_floor", "stage_left":
            return (0.24, 0.72)
        case "right_floor", "stage_right":
            return (0.76, 0.72)
        case "top_center", "upper_center":
            return (0.5, 0.18)
        case "top_left":
            return (0.18, 0.18)
        case "top_right":
            return (0.82, 0.18)
        case "bottom_left":
            return (0.18, 0.82)
        case "bottom_right":
            return (0.82, 0.82)
        default:
            if let variant, !variant.isEmpty {
                return worldAttachmentPoint(named: variant, variant: nil)
            }
            return (0.5, 0.72)
        }
    }

    private func resolvedObjectDrawingState(
        for object: ObjectSetup,
        frame: Int,
        store: AnimateStore
    ) -> String {
        let cue = store.evaluatedObjectCue(for: object.objectName, role: .drawing, at: frame)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let cue, !cue.isEmpty {
            return cue
        }
        return object.initialState
    }

    private func resolvedObjectTexture(
        for object: ObjectSetup,
        drawingState: String,
        store: AnimateStore,
        textureProvider: (URL) -> MTLTexture?
    ) -> MTLTexture? {
        resolvedObjectAssetURL(for: object, drawingState: drawingState, store: store)
            .flatMap(textureProvider)
    }

    private func resolvedObjectAssetURL(
        for object: ObjectSetup,
        drawingState: String,
        store: AnimateStore
    ) -> URL? {
        let normalizedState = drawingState
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let candidatePaths = objectAssetCandidates(
            for: object,
            drawingState: normalizedState
        )

        for path in candidatePaths {
            if let resolved = store.resolvedCharacterAssetURL(for: path) {
                return resolved
            }
        }

        return nil
    }

    private func objectAssetCandidates(
        for object: ObjectSetup,
        drawingState: String
    ) -> [String] {
        var candidates: [String] = []

        if let explicit = object.stateImagePaths.first(where: {
            $0.key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == drawingState
        })?.value {
            candidates.append(explicit)
        }

        if !drawingState.isEmpty, drawingState != "default" {
            let variantCandidates = object.imagePaths.filter { path in
                URL(fileURLWithPath: path).lastPathComponent.lowercased().contains(drawingState)
            }
            candidates.append(contentsOf: variantCandidates)
        }

        if let approved = object.resolvedApprovedImagePath {
            candidates.append(approved)
        }

        let slug = object.objectName
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let extensions = ["png", "jpg", "jpeg", "webp"]

        if !slug.isEmpty {
            if !drawingState.isEmpty, drawingState != "default" {
                for fileExtension in extensions {
                    candidates.append("Animate/objects/\(slug)/\(drawingState).\(fileExtension)")
                }
            }

            for fileExtension in extensions {
                candidates.append("Animate/objects/\(slug)/default.\(fileExtension)")
                candidates.append("Animate/objects/\(slug).\(fileExtension)")
            }
        }

        return candidates
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

    private func makeObjectDrawItem(
        texture: MTLTexture?,
        renderState: SceneObjectRenderState,
        viewportSize: CGSize,
        color: SIMD4<Float>
    ) -> AnimationRenderer.DrawItem? {
        let baseSize = objectSpriteSize(texture: texture, viewportSize: viewportSize)
        let size = scaledSize(baseSize, scale: renderState.scale)
        guard abs(size.x) > 0, abs(size.y) > 0 else { return nil }

        return AnimationRenderer.DrawItem(
            sprite: SpriteInstance(
                position: renderState.position,
                size: size,
                rotation: renderState.rotationRadians,
                opacity: renderState.opacity,
                uvOrigin: .zero,
                uvSize: SIMD2<Float>(1, 1),
                zOrder: renderState.baseZOrder,
                color: color
            ),
            texture: texture
        )
    }

    private func objectSpriteSize(
        texture: MTLTexture?,
        viewportSize: CGSize
    ) -> SIMD2<Float> {
        let targetHeight = Float(min(max(viewportSize.height * 0.18, 64), 220))
        guard let texture else {
            return SIMD2<Float>(targetHeight * 0.9, targetHeight * 0.9)
        }

        let aspectRatio = Float(texture.width) / max(Float(texture.height), 1)
        if aspectRatio >= 1 {
            return SIMD2<Float>(targetHeight * aspectRatio, targetHeight)
        }
        return SIMD2<Float>(targetHeight, targetHeight / max(aspectRatio, 0.001))
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

@available(macOS 26.0, *)
private struct SceneObjectRenderState {
    var position: SIMD2<Float>
    var rotationRadians: Float
    var scale: SIMD2<Float>
    var opacity: Float
    var baseZOrder: Float
}
