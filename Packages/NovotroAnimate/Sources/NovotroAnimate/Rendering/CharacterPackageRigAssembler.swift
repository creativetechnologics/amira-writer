import Foundation
import simd

@available(macOS 26.0, *)
struct CharacterPackageResolvedRenderPlan: Sendable {
    enum Mode: String, Sendable {
        case layeredParts
        case wholeCharacter
    }

    var package: InstalledCharacterPackage
    var mode: Mode
    var layers: [CharacterPackageResolvedLayer]
}

@available(macOS 26.0, *)
struct CharacterPackageResolvedLayer: Identifiable, Sendable {
    var asset: CharacterPackageAsset
    var assetURL: URL
    var zOrder: Float
    var normalizedCenter: SIMD2<Float>
    var normalizedSizeHint: SIMD2<Float>
    var usesFullCanvasPlacement: Bool

    var id: UUID { asset.id }
}

@available(macOS 26.0, *)
struct CharacterPackageRigAssembler: Sendable {
    func assemble(
        character: AnimationCharacter,
        package: InstalledCharacterPackage,
        selection: CharacterRenderSelectionContext? = nil
    ) -> CharacterPackageResolvedRenderPlan? {
        let layered = layeredParts(for: character, package: package, selection: selection)
        if layered.count >= 2 {
            return CharacterPackageResolvedRenderPlan(
                package: package,
                mode: .layeredParts,
                layers: layered
            )
        }

        guard let fallbackLayer = fallbackWholeCharacterLayer(for: package, selection: selection) else {
            return nil
        }

        return CharacterPackageResolvedRenderPlan(
            package: package,
            mode: .wholeCharacter,
            layers: [fallbackLayer]
        )
    }

    private func layeredParts(
        for character: AnimationCharacter,
        package: InstalledCharacterPackage,
        selection: CharacterRenderSelectionContext?
    ) -> [CharacterPackageResolvedLayer] {
        let preferredAngle = selection?.preferredAngle ?? package.manifest.defaults.preferredAngle ?? .front
        let preferredPose = selection?.preferredPose ?? package.manifest.defaults.preferredPose

        let assetsByPart = Dictionary(grouping: package.manifest.assets.compactMap { asset -> CharacterPackageAsset? in
            guard asset.partType != nil else { return nil }
            let assetURL = package.packageDirectoryURL.appendingPathComponent(asset.normalizedRelativePath)
            guard FileManager.default.fileExists(atPath: assetURL.path) else { return nil }
            guard isRenderableImage(path: asset.normalizedRelativePath) else { return nil }
            return asset
        }, by: \.partType)

        var layers: [CharacterPackageResolvedLayer] = []

        for partType in assetsByPart.keys.compactMap({ $0 }) {
            guard let bestAsset = assetsByPart[partType]?.max(by: { lhs, rhs in
                score(lhs, preferredAngle: preferredAngle, preferredPose: preferredPose, selection: selection) <
                score(rhs, preferredAngle: preferredAngle, preferredPose: preferredPose, selection: selection)
            }) else {
                continue
            }

            guard let placement = resolvedPlacement(
                for: bestAsset,
                defaultLayout: layout(for: partType)
            ) else {
                continue
            }
            let assetURL = package.packageDirectoryURL.appendingPathComponent(bestAsset.normalizedRelativePath)
            guard FileManager.default.fileExists(atPath: assetURL.path) else { continue }

            layers.append(CharacterPackageResolvedLayer(
                asset: bestAsset,
                assetURL: assetURL,
                zOrder: layerOrder(for: partType, asset: bestAsset, character: character),
                normalizedCenter: placement.center,
                normalizedSizeHint: placement.size,
                usesFullCanvasPlacement: placement.usesFullCanvasPlacement
            ))
        }

        return layers.sorted { $0.zOrder < $1.zOrder }
    }

    private func fallbackWholeCharacterLayer(
        for package: InstalledCharacterPackage,
        selection: CharacterRenderSelectionContext?
    ) -> CharacterPackageResolvedLayer? {
        let preferredAngle = selection?.preferredAngle ?? package.manifest.defaults.preferredAngle ?? .front
        let preferredPose = selection?.preferredPose ?? package.manifest.defaults.preferredPose

        let candidate = package.manifest.assets
            .filter { asset in
                asset.partType == nil &&
                asset.role != .backgroundPlate &&
                isRenderableImage(path: asset.normalizedRelativePath)
            }
            .max { lhs, rhs in
                score(lhs, preferredAngle: preferredAngle, preferredPose: preferredPose, selection: selection) <
                score(rhs, preferredAngle: preferredAngle, preferredPose: preferredPose, selection: selection)
            }

        guard let asset = candidate ?? package.manifest.assets.first(where: {
            $0.role != .backgroundPlate && isRenderableImage(path: $0.normalizedRelativePath)
        }) else {
            return nil
        }

        let assetURL = package.packageDirectoryURL.appendingPathComponent(asset.normalizedRelativePath)
        guard FileManager.default.fileExists(atPath: assetURL.path) else { return nil }
        let placement = resolvedPlacement(
            for: asset,
            defaultLayout: (SIMD2<Float>(0.5, 0.5), SIMD2<Float>(0.72, 1.0))
        )

        return CharacterPackageResolvedLayer(
            asset: asset,
            assetURL: assetURL,
            zOrder: Float(asset.placement?.zOrderOverride ?? 0),
            normalizedCenter: placement?.center ?? SIMD2<Float>(0.5, 0.5),
            normalizedSizeHint: placement?.size ?? SIMD2<Float>(0.72, 1.0),
            usesFullCanvasPlacement: placement?.usesFullCanvasPlacement ?? usesFullCanvasPlacement(asset)
        )
    }

    private func score(
        _ asset: CharacterPackageAsset,
        preferredAngle: AngleView,
        preferredPose: CharacterPackagePose?,
        selection: CharacterRenderSelectionContext?
    ) -> Int {
        var score = 0

        if asset.angle == preferredAngle { score += 60 }
        if asset.angle == nil { score += 10 }
        if asset.pose == preferredPose { score += 30 }

        switch asset.role {
        case .basePose:
            score += 50
        case .turnaround:
            score += 40
        case .heroPose:
            score += 30
        case .reference:
            score += 10
        case .expression, .viseme, .handPose, .costumeOverlay, .propOverlay, .backgroundPlate:
            score += 5
        }

        let tags = asset.tags.joined(separator: " ").lowercased()
        if tags.contains("default") { score += 15 }
        if tags.contains("render") { score += 10 }
        if tags.contains("hero") { score += 5 }
        if tags.contains("reference") { score -= 5 }

        score += semanticScore(
            tags: asset.tags,
            assetName: asset.name,
            notes: asset.notes,
            role: asset.role,
            pose: asset.pose,
            selection: selection
        )

        return score
    }

    private func semanticScore(
        tags: [String],
        assetName: String,
        notes: String?,
        role: CharacterPackageAssetRole,
        pose: CharacterPackagePose?,
        selection: CharacterRenderSelectionContext?
    ) -> Int {
        guard let selection else { return 0 }

        var score = 0
        let searchable = searchableText(
            tags: tags,
            assetName: assetName,
            notes: notes,
            pose: pose
        )

        if let expressionCue = selection.normalizedExpressionCue {
            if searchable.contains(expressionCue) {
                score += 110
            } else if role == .expression {
                score -= 20
            }
        }

        if let actionCue = selection.normalizedActionCue {
            if searchable.contains(actionCue) {
                score += 85
            } else if role == .handPose || pose == .action {
                score -= 10
            }
        }

        if let mouthCue = selection.normalizedMouthCue {
            if searchable.contains(mouthCue) {
                score += 140
            } else if role == .viseme {
                score -= 25
            }
        }

        if let preferredPose = selection.preferredPose {
            if pose == preferredPose {
                score += 95
            } else if pose == nil {
                score += 8
            }
        }

        return score
    }

    private func searchableText(
        tags: [String],
        assetName: String,
        notes: String?,
        pose: CharacterPackagePose?
    ) -> String {
        (
            tags +
            [assetName, notes, pose?.rawValue]
                .compactMap { $0 }
        )
        .joined(separator: " ")
        .lowercased()
    }

    private func layerOrder(
        for partType: PartType,
        asset: CharacterPackageAsset? = nil,
        character: AnimationCharacter
    ) -> Float {
        if let override = asset?.placement?.zOrderOverride {
            return Float(override)
        }

        if let rigPart = character.parts.first(where: { $0.partType == partType }) {
            return Float(rigPart.zOrder)
        }

        switch partType {
        case .hairBack: return 3
        case .hips: return 8
        case .upperLegLeft, .upperLegRight: return 10
        case .lowerLegLeft, .lowerLegRight: return 11
        case .footLeft, .footRight: return 12
        case .torso, .chest: return 18
        case .upperArmLeft, .upperArmRight: return 22
        case .lowerArmLeft, .lowerArmRight: return 24
        case .handLeft, .handRight: return 26
        case .neck: return 28
        case .head, .face, .mouth, .nose, .eyeLeft, .eyeRight,
             .eyebrowLeft, .eyebrowRight, .hairFront:
            return 32
        case .accessory: return 36
        case .root, .shoulderLeft, .shoulderRight: return 20
        }
    }

    private func layout(for partType: PartType) -> (center: SIMD2<Float>, size: SIMD2<Float>)? {
        switch partType {
        case .hairBack:
            return (SIMD2<Float>(0.5, 0.22), SIMD2<Float>(0.34, 0.26))
        case .head, .face:
            return (SIMD2<Float>(0.5, 0.22), SIMD2<Float>(0.28, 0.24))
        case .hairFront:
            return (SIMD2<Float>(0.5, 0.20), SIMD2<Float>(0.30, 0.22))
        case .neck:
            return (SIMD2<Float>(0.5, 0.34), SIMD2<Float>(0.10, 0.08))
        case .torso, .chest:
            return (SIMD2<Float>(0.5, 0.48), SIMD2<Float>(0.42, 0.34))
        case .hips:
            return (SIMD2<Float>(0.5, 0.66), SIMD2<Float>(0.28, 0.16))
        case .upperArmLeft:
            return (SIMD2<Float>(0.32, 0.44), SIMD2<Float>(0.18, 0.22))
        case .lowerArmLeft:
            return (SIMD2<Float>(0.22, 0.58), SIMD2<Float>(0.16, 0.22))
        case .handLeft:
            return (SIMD2<Float>(0.18, 0.72), SIMD2<Float>(0.12, 0.12))
        case .upperArmRight:
            return (SIMD2<Float>(0.68, 0.44), SIMD2<Float>(0.18, 0.22))
        case .lowerArmRight:
            return (SIMD2<Float>(0.78, 0.58), SIMD2<Float>(0.16, 0.22))
        case .handRight:
            return (SIMD2<Float>(0.82, 0.72), SIMD2<Float>(0.12, 0.12))
        case .upperLegLeft:
            return (SIMD2<Float>(0.44, 0.82), SIMD2<Float>(0.18, 0.24))
        case .lowerLegLeft:
            return (SIMD2<Float>(0.42, 0.94), SIMD2<Float>(0.16, 0.22))
        case .footLeft:
            return (SIMD2<Float>(0.42, 1.03), SIMD2<Float>(0.18, 0.10))
        case .upperLegRight:
            return (SIMD2<Float>(0.56, 0.82), SIMD2<Float>(0.18, 0.24))
        case .lowerLegRight:
            return (SIMD2<Float>(0.58, 0.94), SIMD2<Float>(0.16, 0.22))
        case .footRight:
            return (SIMD2<Float>(0.58, 1.03), SIMD2<Float>(0.18, 0.10))
        case .mouth:
            return (SIMD2<Float>(0.5, 0.27), SIMD2<Float>(0.12, 0.06))
        case .nose:
            return (SIMD2<Float>(0.5, 0.24), SIMD2<Float>(0.08, 0.08))
        case .eyeLeft:
            return (SIMD2<Float>(0.45, 0.22), SIMD2<Float>(0.08, 0.04))
        case .eyeRight:
            return (SIMD2<Float>(0.55, 0.22), SIMD2<Float>(0.08, 0.04))
        case .eyebrowLeft:
            return (SIMD2<Float>(0.45, 0.18), SIMD2<Float>(0.10, 0.04))
        case .eyebrowRight:
            return (SIMD2<Float>(0.55, 0.18), SIMD2<Float>(0.10, 0.04))
        case .shoulderLeft:
            return (SIMD2<Float>(0.38, 0.40), SIMD2<Float>(0.14, 0.10))
        case .shoulderRight:
            return (SIMD2<Float>(0.62, 0.40), SIMD2<Float>(0.14, 0.10))
        case .accessory:
            return (SIMD2<Float>(0.5, 0.46), SIMD2<Float>(0.22, 0.18))
        case .root:
            return nil
        }
    }

    private func isRenderableImage(path: String) -> Bool {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        return ["png", "jpg", "jpeg", "webp", "heic"].contains(ext)
    }

    private func resolvedPlacement(
        for asset: CharacterPackageAsset,
        defaultLayout: (center: SIMD2<Float>, size: SIMD2<Float>)?
    ) -> (center: SIMD2<Float>, size: SIMD2<Float>, usesFullCanvasPlacement: Bool)? {
        let authoredPlacement = asset.placement
        let usesAuthoredFullCanvasPlacement =
            authoredPlacement?.resolvedMode == .fullCanvasAligned ||
            authoredPlacement?.usesFullCanvasPlacement == true
        let usesFullCanvasPlacement = usesAuthoredFullCanvasPlacement || usesFullCanvasPlacement(asset)
        let fallbackCenter = defaultLayout?.center ?? SIMD2<Float>(0.5, 0.5)
        let fallbackSize = defaultLayout?.size ?? (
            usesFullCanvasPlacement
                ? SIMD2<Float>(1.0, 1.0)
                : SIMD2<Float>(0.72, 1.0)
        )

        if authoredPlacement == nil && defaultLayout == nil && !usesFullCanvasPlacement {
            return nil
        }

        return (
            center: authoredCenter(from: authoredPlacement) ?? fallbackCenter,
            size: authoredSize(from: authoredPlacement) ?? fallbackSize,
            usesFullCanvasPlacement: usesFullCanvasPlacement
        )
    }

    private func usesFullCanvasPlacement(_ asset: CharacterPackageAsset) -> Bool {
        let tags = asset.tags.map { $0.lowercased() }
        return tags.contains("full-canvas") || tags.contains("full_canvas")
    }

    private func authoredCenter(
        from placement: CharacterPackageAssetPlacement?
    ) -> SIMD2<Float>? {
        guard let point = placement?.normalizedCenter else { return nil }
        return SIMD2<Float>(Float(point.x), Float(point.y))
    }

    private func authoredSize(
        from placement: CharacterPackageAssetPlacement?
    ) -> SIMD2<Float>? {
        guard let size = placement?.normalizedSize else { return nil }
        return SIMD2<Float>(Float(size.width), Float(size.height))
    }
}
