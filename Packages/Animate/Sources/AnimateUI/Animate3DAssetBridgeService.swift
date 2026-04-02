import Foundation

@available(macOS 26.0, *)
enum Animate3DAssetBridgeReadiness: String, Hashable, Sendable {
    case unavailable
    case missing
    case partial
    case ready

    var title: String {
        switch self {
        case .unavailable:
            "Unavailable"
        case .missing:
            "Missing"
        case .partial:
            "Partial"
        case .ready:
            "Ready"
        }
    }
}

@available(macOS 26.0, *)
struct Animate3DCharacterAssetBridgeStatus: Identifiable, Hashable, Sendable {
    var id: String
    var characterName: String
    var assetFolderSlug: String?
    var selectionSlug: String?
    var readiness: Animate3DAssetBridgeReadiness
    var summary: String
    var referenceSummary: String
    var activePackageName: String?
    var packageCount: Int
    var assetCount: Int
    var blueprintCount: Int
    var errorCount: Int
    var warningCount: Int
    var currentCueSummary: String
    var currentSwapSummary: String?
    var isVisibleAtCurrentFrame: Bool
    var detailLines: [String]
}

@available(macOS 26.0, *)
@MainActor
struct Animate3DAssetBridgeService {
    private let library = CharacterPackageLibrary()
    private let assembler = CharacterPackageRigAssembler()
    private let rigResolver = CharacterRigRenderResolver()

    func bridgeStatuses(
        for scenario: Animate3DPreviewScenario,
        snapshot: Animate3DFrameSnapshot,
        store: AnimateStore
    ) -> [Animate3DCharacterAssetBridgeStatus] {
        let linkedCharacters = linkedCharacters(for: scenario, store: store)

        guard !linkedCharacters.isEmpty else {
            return unavailableStatuses(for: scenario, reason: unavailableReason(for: scenario))
        }

        guard let animateURL = store.animateURL else {
            return linkedCharacters.map { character in
                Animate3DCharacterAssetBridgeStatus(
                    id: character.id.uuidString,
                    characterName: character.name,
                    assetFolderSlug: character.assetFolderSlug,
                    selectionSlug: character.owpSlug,
                    readiness: .unavailable,
                    summary: "The project Animate folder is not available, so package readiness cannot be checked yet.",
                    referenceSummary: referenceSummary(for: character),
                    activePackageName: nil,
                    packageCount: 0,
                    assetCount: 0,
                    blueprintCount: 0,
                    errorCount: 0,
                    warningCount: 0,
                    currentCueSummary: cueSummary(
                        for: character,
                        store: store,
                        frame: snapshot.displayFrame
                    ),
                    currentSwapSummary: nil,
                    isVisibleAtCurrentFrame: visibleSnapshot(for: character, in: snapshot)?.visible ?? false,
                    detailLines: []
                )
            }
        }

        return linkedCharacters.map { character in
            status(
                for: character,
                scenario: scenario,
                snapshot: snapshot,
                animateURL: animateURL,
                store: store
            )
        }
        .sorted { lhs, rhs in
            if lhs.isVisibleAtCurrentFrame != rhs.isVisibleAtCurrentFrame {
                return lhs.isVisibleAtCurrentFrame && !rhs.isVisibleAtCurrentFrame
            }
            return lhs.characterName.localizedCaseInsensitiveCompare(rhs.characterName) == .orderedAscending
        }
    }

    private func status(
        for character: AnimationCharacter,
        scenario: Animate3DPreviewScenario,
        snapshot: Animate3DFrameSnapshot,
        animateURL: URL,
        store: AnimateStore
    ) -> Animate3DCharacterAssetBridgeStatus {
        let preferredActivePackageID = store.activePackageID(for: character.owpSlug)
        let packages = library.installedPackages(
            for: character.assetFolderSlug,
            in: animateURL,
            preferredActivePackageID: preferredActivePackageID
        )
        let cueSummary = cueSummary(
            for: character,
            store: store,
            frame: snapshot.displayFrame
        )
        let visibleNow = visibleSnapshot(for: character, in: snapshot)?.visible ?? false
        let referenceSummary = referenceSummary(for: character)

        guard let package = packages.first else {
            let hasReferenceWorkflow = character.approvedMasterReferenceSheetVariant != nil ||
                character.approvedHeadTurnaroundSheetVariant != nil ||
                !character.headTurnaroundSlots.isEmpty
            return Animate3DCharacterAssetBridgeStatus(
                id: character.id.uuidString,
                characterName: character.name,
                assetFolderSlug: character.assetFolderSlug,
                selectionSlug: character.owpSlug,
                readiness: .missing,
                summary: hasReferenceWorkflow
                    ? "Reference sheets exist, but no package is installed yet for a placeholder-to-package swap."
                    : "No package is installed yet for this character.",
                referenceSummary: referenceSummary,
                activePackageName: nil,
                packageCount: 0,
                assetCount: 0,
                blueprintCount: 0,
                errorCount: 0,
                warningCount: 0,
                currentCueSummary: cueSummary,
                currentSwapSummary: nil,
                isVisibleAtCurrentFrame: visibleNow,
                detailLines: [
                    "Expected package root: characters/\(character.assetFolderSlug)/packages",
                    "Selection key remains \(character.owpSlug) for active-package preferences."
                ]
            )
        }

        let selection = CharacterRenderSelectionContext(
            preferredAngle: store.evaluatedViewAngle(for: character.id, at: snapshot.displayFrame) ?? character.preferredViewAngle,
            preferredPose: store.evaluatedPose(for: character.id, at: snapshot.displayFrame),
            expressionCue: store.evaluatedExpression(for: character.id, at: snapshot.displayFrame),
            actionCue: store.evaluatedAction(for: character.id, at: snapshot.displayFrame),
            mouthCue: store.evaluatedMouthCue(for: character.id, at: snapshot.displayFrame)
        )
        let rigDerivedLayerCount = rigDerivedLayerCount(
            for: character,
            package: package,
            selection: selection,
            animateURL: animateURL
        )
        let renderPlan = assembler.assemble(
            character: character,
            package: package,
            selection: selection
        )
        let currentSwapSummary = rigDerivedLayerCount.map { "Rig-derived layered cutout · \($0) layers" }
            ?? renderPlanSummary(for: renderPlan)
        let hasSwappablePlan = currentSwapSummary != nil

        let assetCount = package.manifest.assets.count
        let blueprintCount = package.manifest.blueprints.count
        let errorCount = package.validationReport.issues.filter { $0.severity == .error }.count
        let warningCount = package.validationReport.issues.filter { $0.severity == .warning }.count
        let hasReferenceAssets = package.manifest.assets.contains(where: { $0.role == .reference })
        let hasBasePoseCoverage = package.manifest.assets.contains {
            $0.role == .basePose || $0.role == .turnaround
        }
        let hasReferenceWorkflow = character.approvedMasterReferenceSheetVariant != nil ||
            character.approvedHeadTurnaroundSheetVariant != nil ||
            !character.headTurnaroundSlots.isEmpty

        let readiness: Animate3DAssetBridgeReadiness
        let summary: String

        if hasSwappablePlan &&
            errorCount == 0 &&
            warningCount == 0 &&
            hasReferenceAssets &&
            hasBasePoseCoverage &&
            hasReferenceWorkflow {
            readiness = .ready
            summary = currentSwapSummary == nil
                ? "This character is ready for a package-backed placeholder swap."
                : "This character is ready for a package-backed placeholder swap at the current frame."
        } else if errorCount > 0 {
            readiness = .partial
            summary = "A package is installed, but validation errors still block a clean swap."
        } else if !hasSwappablePlan {
            readiness = .partial
            summary = "A package is installed, but the current frame cues do not resolve to a swappable render plan yet."
        } else {
            readiness = .partial
            summary = "A package resolves for this frame, but reference or package coverage still needs work."
        }

        var detailLines: [String] = []
        if !hasReferenceAssets {
            detailLines.append("Package is missing at least one reference asset.")
        }
        if !hasBasePoseCoverage {
            detailLines.append("Package is missing base-pose or turnaround coverage.")
        }
        if !hasReferenceWorkflow {
            detailLines.append("No approved master sheet or head-turnaround source is linked yet.")
        }
        detailLines.append(contentsOf: package.validationReport.issues.prefix(2).map(\.message))
        if let currentSwapSummary {
            detailLines.insert(currentSwapSummary, at: 0)
        }
        if scenario.sourceKind != .selectedTimeline {
            detailLines.append("Current 3D bridge status is exact because it is derived from the linked project scene cast, not the generated placeholder snapshot IDs.")
        }

        return Animate3DCharacterAssetBridgeStatus(
            id: character.id.uuidString,
            characterName: character.name,
            assetFolderSlug: character.assetFolderSlug,
            selectionSlug: character.owpSlug,
            readiness: readiness,
            summary: summary,
            referenceSummary: referenceSummary,
            activePackageName: package.manifest.displayName,
            packageCount: packages.count,
            assetCount: assetCount,
            blueprintCount: blueprintCount,
            errorCount: errorCount,
            warningCount: warningCount,
            currentCueSummary: cueSummary,
            currentSwapSummary: currentSwapSummary,
            isVisibleAtCurrentFrame: visibleNow,
            detailLines: detailLines
        )
    }

    private func linkedCharacters(
        for scenario: Animate3DPreviewScenario,
        store: AnimateStore
    ) -> [AnimationCharacter] {
        guard let sceneID = scenario.sceneID,
              let scene = store.scenes.first(where: { $0.id == sceneID }) else {
            return []
        }

        return scene.characterIDs.compactMap { characterID in
            store.characters.first(where: { $0.id == characterID })
        }
    }

    private func unavailableStatuses(
        for scenario: Animate3DPreviewScenario,
        reason: String
    ) -> [Animate3DCharacterAssetBridgeStatus] {
        scenario.castNames.map { name in
            Animate3DCharacterAssetBridgeStatus(
                id: unavailableID(for: name),
                characterName: name,
                assetFolderSlug: nil,
                selectionSlug: nil,
                readiness: .unavailable,
                summary: reason,
                referenceSummary: "No linked project character",
                activePackageName: nil,
                packageCount: 0,
                assetCount: 0,
                blueprintCount: 0,
                errorCount: 0,
                warningCount: 0,
                currentCueSummary: "",
                currentSwapSummary: nil,
                isVisibleAtCurrentFrame: false,
                detailLines: []
            )
        }
    }

    private func unavailableReason(for scenario: Animate3DPreviewScenario) -> String {
        if scenario.sourceKind == .fixture {
            return "Fixture characters do not carry canonical project character IDs, so exact package bridging is unavailable in fixture mode."
        }

        return "Link real project characters into the selected scene cast to inspect package-backed swap readiness."
    }

    private func referenceSummary(for character: AnimationCharacter) -> String {
        let hasMasterSheet = character.approvedMasterReferenceSheetVariant != nil
        let hasTurnaround = character.approvedHeadTurnaroundSheetVariant != nil || !character.headTurnaroundSlots.isEmpty

        return switch (hasMasterSheet, hasTurnaround) {
        case (true, true):
            "Approved master sheet + turnaround"
        case (true, false):
            "Approved master sheet only"
        case (false, true):
            "Turnaround coverage only"
        case (false, false):
            "No approved reference sheet yet"
        }
    }

    private func cueSummary(
        for character: AnimationCharacter,
        store: AnimateStore,
        frame: Int
    ) -> String {
        var parts: [String] = []

        if let angle = store.evaluatedViewAngle(for: character.id, at: frame) ?? character.preferredViewAngle {
            parts.append("view \(angle.rawValue)")
        }
        if let pose = store.evaluatedPose(for: character.id, at: frame) {
            parts.append("pose \(pose.rawValue)")
        }
        if let expression = CharacterRenderSelectionContext.normalize(
            store.evaluatedExpression(for: character.id, at: frame)
        ) {
            parts.append("expr \(expression)")
        }
        if let action = CharacterRenderSelectionContext.normalize(
            store.evaluatedAction(for: character.id, at: frame)
        ) {
            parts.append("act \(action)")
        }
        if let mouthCue = CharacterRenderSelectionContext.normalizeMouth(
            store.evaluatedMouthCue(for: character.id, at: frame)
        ) {
            parts.append("mouth \(mouthCue)")
        }

        return parts.isEmpty ? "Default package cues" : parts.joined(separator: " · ")
    }

    private func renderPlanSummary(for renderPlan: CharacterPackageResolvedRenderPlan?) -> String? {
        guard let renderPlan else { return nil }

        switch renderPlan.mode {
        case .layeredParts:
            return "Layered part swap · \(renderPlan.layers.count) layers"
        case .wholeCharacter:
            return "Whole-character card swap"
        }
    }

    private func rigDerivedLayerCount(
        for character: AnimationCharacter,
        package: InstalledCharacterPackage,
        selection: CharacterRenderSelectionContext,
        animateURL: URL
    ) -> Int? {
        guard let rigRenderPlan = rigResolver.resolveRenderPlan(
            for: character,
            animateURL: animateURL,
            selection: selection
        ) else {
            return nil
        }

        let matchingLayers = rigRenderPlan.layers.filter { layer in
            layer.variant.isPackageDerived &&
            packageMatches(layer.variant, package: package)
        }

        guard matchingLayers.count >= 2 else { return nil }
        return matchingLayers.count
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

    private func visibleSnapshot(
        for character: AnimationCharacter,
        in snapshot: Animate3DFrameSnapshot
    ) -> Animate3DCharacterSnapshot? {
        snapshot.characters.first(where: { snapshotCharacter in
            snapshotCharacter.characterUUID == character.id ||
            snapshotCharacter.id == character.id.uuidString
        })
    }

    private func unavailableID(for name: String) -> String {
        let normalized = name
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        return "asset-bridge-\(normalized)"
    }
}
