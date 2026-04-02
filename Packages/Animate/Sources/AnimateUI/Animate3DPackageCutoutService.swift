import Foundation
import simd

@available(macOS 26.0, *)
@MainActor
struct Animate3DPackageCutoutService {
    private let library = CharacterPackageLibrary()
    private let assembler = CharacterPackageRigAssembler()
    private let rigResolver = CharacterRigRenderResolver()

    private let canvasWorldWidth = 1.85
    private let canvasWorldHeight = 2.45
    private let rootReferenceCenter = SIMD2<Double>(0.5, 0.52)
    private let rootBasePosition = SIMD3<Double>(0, 1.18, 0.26)

    func cutoutPlans(
        for scenario: Animate3DPreviewScenario,
        snapshot: Animate3DFrameSnapshot,
        store: AnimateStore
    ) -> [Animate3DCharacterPackageCutoutPlan] {
        guard scenario.sourceKind == .selectedTimeline else { return [] }
        guard let animateURL = store.animateURL else { return [] }

        return snapshot.characters.compactMap { snapshotCharacter in
            guard let character = linkedCharacter(for: snapshotCharacter, store: store) else { return nil }

            let packages = library.installedPackages(
                for: character.assetFolderSlug,
                in: animateURL,
                preferredActivePackageID: store.activePackageID(for: character.owpSlug)
            )
            guard let package = packages.first else { return nil }

            let selection = CharacterRenderSelectionContext(
                preferredAngle: snapshotCharacter.preferredAngle ?? character.preferredViewAngle,
                preferredPose: snapshotCharacter.preferredPose,
                expressionCue: snapshotCharacter.expression,
                actionCue: snapshotCharacter.action,
                mouthCue: snapshotCharacter.mouthCue
            )
            if let rigPlan = rigCutoutPlan(
                for: character,
                package: package,
                selection: selection,
                animateURL: animateURL
            ) {
                return rigPlan
            }

            guard let renderPlan = assembler.assemble(
                character: character,
                package: package,
                selection: selection
            ) else {
                return nil
            }

            let layers = renderPlan.layers.enumerated().map { index, layer in
                cutoutLayer(
                    from: layer,
                    mode: renderPlan.mode == .layeredParts ? .layeredParts : .wholeCharacter,
                    index: index
                )
            }

            return Animate3DCharacterPackageCutoutPlan(
                id: character.id.uuidString,
                characterID: character.id.uuidString,
                characterName: character.name,
                packageName: package.manifest.displayName,
                mode: renderPlan.mode == .layeredParts ? .layeredParts : .wholeCharacter,
                layers: layers
            )
        }
    }

    private func rigCutoutPlan(
        for character: AnimationCharacter,
        package: InstalledCharacterPackage,
        selection: CharacterRenderSelectionContext,
        animateURL: URL
    ) -> Animate3DCharacterPackageCutoutPlan? {
        guard let rigRenderPlan = rigResolver.resolveRenderPlan(
            for: character,
            animateURL: animateURL,
            selection: selection
        ) else {
            return nil
        }

        let rigLayers = rigRenderPlan.layers.filter { layer in
            layer.variant.isPackageDerived &&
            packageMatches(layer.variant, package: package)
        }

        guard rigLayers.count >= 2 else { return nil }

        let layers = rigLayers.enumerated().map { index, layer in
            cutoutLayer(from: layer, mode: .rigLayers, index: index)
        }

        return Animate3DCharacterPackageCutoutPlan(
            id: character.id.uuidString,
            characterID: character.id.uuidString,
            characterName: character.name,
            packageName: package.manifest.displayName,
            mode: .rigLayers,
            layers: layers
        )
    }

    private func linkedCharacter(
        for snapshotCharacter: Animate3DCharacterSnapshot,
        store: AnimateStore
    ) -> AnimationCharacter? {
        if let characterUUID = snapshotCharacter.characterUUID,
           let character = store.characters.first(where: { $0.id == characterUUID }) {
            return character
        }

        if let snapshotUUID = UUID(uuidString: snapshotCharacter.id),
           let character = store.characters.first(where: { $0.id == snapshotUUID }) {
            return character
        }

        if let assetFolderSlug = snapshotCharacter.assetFolderSlug,
           let character = store.characters.first(where: { $0.assetFolderSlug == assetFolderSlug }) {
            return character
        }

        return store.characters.first(where: { $0.name == snapshotCharacter.name })
    }

    private func cutoutLayer(
        from layer: CharacterPackageResolvedLayer,
        mode: Animate3DCharacterPackageCutoutPlan.Mode,
        index: Int
    ) -> Animate3DPackageCutoutLayer {
        let anchor = anchor(for: layer.asset.partType, mode: mode)
        let planeSize = SIMD2<Double>(
            max(0.12, Double(layer.normalizedSizeHint.x) * canvasWorldWidth),
            max(0.12, Double(layer.normalizedSizeHint.y) * canvasWorldHeight)
        )
        let localPosition = localPosition(
            for: layer,
            anchor: anchor,
            index: index,
            mode: mode
        )

        return Animate3DPackageCutoutLayer(
            id: layer.asset.id.uuidString,
            anchor: anchor,
            assetURL: layer.assetURL,
            planeSize: planeSize,
            localPosition: localPosition,
            opacity: 1
        )
    }

    private func cutoutLayer(
        from layer: CharacterRigResolvedLayer,
        mode: Animate3DCharacterPackageCutoutPlan.Mode,
        index: Int
    ) -> Animate3DPackageCutoutLayer {
        let anchor = anchor(for: layer.variant.sourcePartType ?? layer.part.partType, mode: mode)
        let planeSize = SIMD2<Double>(
            max(0.12, Double(layer.normalizedSizeHint.x) * canvasWorldWidth),
            max(0.12, Double(layer.normalizedSizeHint.y) * canvasWorldHeight)
        )
        let localPosition = localPosition(
            center: layer.normalizedCenter,
            anchor: anchor,
            index: index,
            mode: mode
        )

        return Animate3DPackageCutoutLayer(
            id: layer.id.uuidString,
            anchor: anchor,
            assetURL: layer.assetURL,
            planeSize: planeSize,
            localPosition: localPosition,
            opacity: 1
        )
    }

    private func localPosition(
        for layer: CharacterPackageResolvedLayer,
        anchor: Animate3DPackageCutoutAnchor,
        index: Int,
        mode: Animate3DCharacterPackageCutoutPlan.Mode
    ) -> SIMD3<Double> {
        localPosition(
            center: layer.normalizedCenter,
            anchor: anchor,
            index: index,
            mode: mode
        )
    }

    private func localPosition(
        center: SIMD2<Float>,
        anchor: Animate3DPackageCutoutAnchor,
        index: Int,
        mode: Animate3DCharacterPackageCutoutPlan.Mode
    ) -> SIMD3<Double> {
        let center = SIMD2<Double>(
            Double(center.x),
            Double(center.y)
        )
        let zOffset = 0.04 + (Double(index) * 0.004)

        if mode == .wholeCharacter || anchor == .root {
            let delta = center - rootReferenceCenter
            return SIMD3<Double>(
                rootBasePosition.x + (delta.x * canvasWorldWidth),
                rootBasePosition.y + (-delta.y * canvasWorldHeight),
                rootBasePosition.z + zOffset
            )
        }

        let referenceCenter = referenceCenter(for: anchor)
        let delta = center - referenceCenter
        return SIMD3<Double>(
            delta.x * canvasWorldWidth,
            -delta.y * canvasWorldHeight,
            zOffset
        )
    }

    private func anchor(
        for partType: PartType?,
        mode: Animate3DCharacterPackageCutoutPlan.Mode
    ) -> Animate3DPackageCutoutAnchor {
        guard mode != .wholeCharacter else { return .root }

        switch partType {
        case .head, .face, .neck, .eyeLeft, .eyeRight, .eyebrowLeft, .eyebrowRight, .mouth, .nose, .hairFront, .hairBack:
            return .head
        case .torso, .chest, .hips, .shoulderLeft, .shoulderRight:
            return .torso
        case .upperArmLeft, .lowerArmLeft, .handLeft:
            return .leftArm
        case .upperArmRight, .lowerArmRight, .handRight:
            return .rightArm
        case .upperLegLeft, .lowerLegLeft, .footLeft:
            return .leftLeg
        case .upperLegRight, .lowerLegRight, .footRight:
            return .rightLeg
        case .accessory, .root, .none:
            return .root
        }
    }

    private func referenceCenter(
        for anchor: Animate3DPackageCutoutAnchor
    ) -> SIMD2<Double> {
        switch anchor {
        case .root:
            return rootReferenceCenter
        case .head:
            return SIMD2<Double>(0.5, 0.22)
        case .torso:
            return SIMD2<Double>(0.5, 0.48)
        case .leftArm:
            return SIMD2<Double>(0.32, 0.44)
        case .rightArm:
            return SIMD2<Double>(0.68, 0.44)
        case .leftLeg:
            return SIMD2<Double>(0.44, 0.82)
        case .rightLeg:
            return SIMD2<Double>(0.56, 0.82)
        }
    }

    private func packageMatches(
        _ variant: DrawingVariant,
        package: InstalledCharacterPackage
    ) -> Bool {
        if let sourcePackageID = variant.sourcePackageID,
           sourcePackageID == package.id {
            return true
        }

        if normalizePackageKey(variant.sourcePackageSlug) == normalizePackageKey(package.manifest.slug) {
            return true
        }

        if normalizePackageKey(variant.sourcePackageDisplayName) == normalizePackageKey(package.manifest.displayName) {
            return true
        }

        if let sourceURL = variant.sourceURL {
            return sourceURL.standardizedFileURL.path.hasPrefix(
                package.packageDirectoryURL.standardizedFileURL.path
            )
        }

        return false
    }

    private func normalizePackageKey(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}
