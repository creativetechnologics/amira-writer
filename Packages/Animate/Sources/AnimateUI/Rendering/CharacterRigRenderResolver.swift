import Foundation
import simd

@available(macOS 26.0, *)
struct CharacterRigResolvedRenderPlan: Sendable {
    var angle: AngleView
    var packageCanvasSizeHint: CharacterPackageCanvasSize?
    var layers: [CharacterRigResolvedLayer]
}

@available(macOS 26.0, *)
struct CharacterRigResolvedLayer: Identifiable, Sendable {
    var part: RigPart
    var variant: DrawingVariant
    var assetURL: URL
    var zOrder: Float
    var normalizedCenter: SIMD2<Float>
    var normalizedSizeHint: SIMD2<Float>
    var usesFullCanvasPlacement: Bool

    var id: UUID { variant.id }
}

@available(macOS 26.0, *)
struct CharacterRigRenderResolver: Sendable {
    private let library = CharacterPackageLibrary()
    private let selectionStore = CharacterPackageSelectionStore()

    func resolveRenderPlan(
        for character: AnimationCharacter,
        animateURL: URL?,
        selection: CharacterRenderSelectionContext? = nil
    ) -> CharacterRigResolvedRenderPlan? {
        guard let animateURL else { return nil }

        let angle = preferredAngle(for: character, selection: selection)
        let layers = character.parts.compactMap { part in
            resolveLayer(
                for: part,
                angle: angle,
                selection: selection,
                character: character,
                animateURL: animateURL
            )
        }

        guard !layers.isEmpty else { return nil }

        return CharacterRigResolvedRenderPlan(
            angle: angle,
            packageCanvasSizeHint: packageCanvasSizeHint(
                for: layers,
                character: character,
                animateURL: animateURL
            ),
            layers: layers.sorted { $0.zOrder < $1.zOrder }
        )
    }

    private func preferredAngle(
        for character: AnimationCharacter,
        selection: CharacterRenderSelectionContext?
    ) -> AngleView {
        if let selectedAngle = selection?.preferredAngle ?? character.preferredViewAngle {
            return selectedAngle
        }

        let ranked = AngleView.allCases
            .map { angle in
                (
                    angle: angle,
                    count: character.parts.reduce(into: 0) { total, part in
                        if let drawingSet = part.drawingSets[angle], !drawingSet.variants.isEmpty {
                            total += 1
                        }
                    }
                )
            }
            .sorted { lhs, rhs in
                if lhs.count != rhs.count {
                    return lhs.count > rhs.count
                }
                return anglePriority(lhs.angle) < anglePriority(rhs.angle)
            }

        return ranked.first(where: { $0.count > 0 })?.angle ?? .front
    }

    private func anglePriority(_ angle: AngleView) -> Int {
        switch angle {
        case .front: return 0
        case .threeQuarterFront: return 1
        case .side: return 2
        case .threeQuarterBack: return 3
        case .back: return 4
        }
    }

    private func resolveLayer(
        for part: RigPart,
        angle: AngleView,
        selection: CharacterRenderSelectionContext?,
        character: AnimationCharacter,
        animateURL: URL
    ) -> CharacterRigResolvedLayer? {
        guard let variant = preferredVariant(
                for: part,
                preferredAngle: angle,
                selection: selection
              ),
              let assetURL = drawingURL(for: variant, character: character, animateURL: animateURL),
              let placement = resolvedPlacement(
                for: variant,
                defaultLayout: layout(for: part.partType)
              )
        else {
            return nil
        }

        return CharacterRigResolvedLayer(
            part: part,
            variant: variant,
            assetURL: assetURL,
            zOrder: Float(variant.placement?.zOrderOverride ?? part.zOrder),
            normalizedCenter: placement.center,
            normalizedSizeHint: placement.size,
            usesFullCanvasPlacement: placement.usesFullCanvasPlacement
        )
    }

    private func preferredVariant(
        for part: RigPart,
        preferredAngle: AngleView,
        selection: CharacterRenderSelectionContext?
    ) -> DrawingVariant? {
        var candidates: [(variant: DrawingVariant, angle: AngleView, drawingSet: DrawingSet)] = []

        for angle in AngleView.allCases {
            guard let drawingSet = part.drawingSets[angle], !drawingSet.variants.isEmpty else { continue }
            for variant in drawingSet.variants {
                candidates.append((variant: variant, angle: angle, drawingSet: drawingSet))
            }
        }

        guard !candidates.isEmpty else { return nil }

        return candidates.max { lhs, rhs in
            variantScore(
                lhs.variant,
                angle: lhs.angle,
                drawingSet: lhs.drawingSet,
                requestedAngle: preferredAngle,
                selection: selection
            ) < variantScore(
                rhs.variant,
                angle: rhs.angle,
                drawingSet: rhs.drawingSet,
                requestedAngle: preferredAngle,
                selection: selection
            )
        }?.variant
    }

    private func variantScore(
        _ variant: DrawingVariant,
        angle: AngleView,
        drawingSet: DrawingSet,
        requestedAngle: AngleView,
        selection: CharacterRenderSelectionContext?
    ) -> Int {
        var score = 0
        let angleDistance = abs(anglePriority(angle) - anglePriority(requestedAngle))
        score += max(0, 120 - (angleDistance * 30))

        if drawingSet.activeVariantID == variant.id {
            score += 35
        } else if drawingSet.activeVariantID == nil, drawingSet.variants.last?.id == variant.id {
            score += 12
        }

        if variant.sourceAngle == requestedAngle {
            score += 18
        }

        let searchable = searchableText(for: variant)

        if let preferredPose = selection?.preferredPose {
            if variant.sourcePose == preferredPose {
                score += 95
            } else if variant.sourcePose == nil {
                score += 8
            }
        }

        if let expressionCue = selection?.normalizedExpressionCue {
            if searchable.contains(expressionCue) {
                score += 120
            } else if variant.sourceAssetRole == .expression {
                score -= 20
            }
        }

        if let actionCue = selection?.normalizedActionCue {
            if searchable.contains(actionCue) {
                score += 85
            } else if variant.sourceAssetRole == .handPose || variant.sourcePose == .action {
                score -= 10
            }
        }

        if let mouthCue = selection?.normalizedMouthCue {
            if searchable.contains(mouthCue) {
                score += 140
            } else if variant.sourceAssetRole == .viseme || partType(for: variant) == .mouth {
                score -= 25
            }
        }

        if searchable.contains("default") {
            score += 10
        }

        return score
    }

    private func partType(for variant: DrawingVariant) -> PartType? {
        variant.sourcePartType
    }

    private func searchableText(for variant: DrawingVariant) -> String {
        (
            (variant.sourceTags ?? []) +
            [
                variant.name,
                variant.sourceAssetName,
                variant.sourceAssetRole?.rawValue,
                variant.sourcePose?.rawValue,
                variant.sourceNotes
            ]
            .compactMap { $0 }
        )
        .joined(separator: " ")
        .lowercased()
    }

    private func drawingURL(
        for variant: DrawingVariant,
        character: AnimationCharacter,
        animateURL: URL
    ) -> URL? {
        let partsDirectory = animateURL
            .appendingPathComponent("characters")
            .appendingPathComponent(character.assetFolderSlug)
            .appendingPathComponent("parts")

        let localURL = partsDirectory.appendingPathComponent(variant.filename)
        if FileManager.default.fileExists(atPath: localURL.path) {
            return localURL
        }

        if let sourceURL = variant.sourceURL,
           FileManager.default.fileExists(atPath: sourceURL.path) {
            return sourceURL
        }

        return nil
    }

    private func packageCanvasSizeHint(
        for layers: [CharacterRigResolvedLayer],
        character: AnimationCharacter,
        animateURL: URL
    ) -> CharacterPackageCanvasSize? {
        let packages = library.installedPackages(
            for: character.assetFolderSlug,
            in: animateURL,
            preferredActivePackageID: selectionStore.activePackageID(for: character.owpSlug, in: animateURL)
        )

        for layer in layers {
            if let sourcePackageID = layer.variant.sourcePackageID,
               let package = packages.first(where: { $0.id == sourcePackageID }),
               let canvasSize = package.manifest.defaults.defaultCanvasSize {
                return canvasSize
            }
        }

        return packages.first?.manifest.defaults.defaultCanvasSize
    }

    private func resolvedPlacement(
        for variant: DrawingVariant,
        defaultLayout: (center: SIMD2<Float>, size: SIMD2<Float>)?
    ) -> (center: SIMD2<Float>, size: SIMD2<Float>, usesFullCanvasPlacement: Bool)? {
        let authoredPlacement = variant.placement
        let usesFullCanvasPlacement = authoredPlacement?.prefersFullCanvasPlacement ?? false
        let fallbackCenter = defaultLayout?.center ?? SIMD2<Float>(0.5, 0.5)
        let fallbackSize = defaultLayout?.size ?? (
            usesFullCanvasPlacement
                ? SIMD2<Float>(1.0, 1.0)
                : SIMD2<Float>(0.72, 1.0)
        )

        if authoredPlacement == nil && defaultLayout == nil && !usesFullCanvasPlacement {
            return nil
        }

        let center = authoredPlacement.flatMap { placement -> SIMD2<Float>? in
            guard let point = placement.normalizedCenter else { return nil }
            return SIMD2<Float>(Float(point.x), Float(point.y))
        } ?? fallbackCenter

        let size = authoredPlacement.flatMap { placement -> SIMD2<Float>? in
            guard let normalizedSize = placement.normalizedSize else { return nil }
            return SIMD2<Float>(Float(normalizedSize.width), Float(normalizedSize.height))
        } ?? fallbackSize

        return (
            center: center,
            size: size,
            usesFullCanvasPlacement: usesFullCanvasPlacement
        )
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
}
