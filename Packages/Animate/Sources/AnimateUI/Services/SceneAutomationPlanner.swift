import Foundation

struct SceneAutomationPlanner: Sendable {
    private let packageLibrary = CharacterPackageLibrary()

    func makePlan(
        scene: AnimationScene,
        profile: SceneAutomationProfile,
        characters: [AnimationCharacter],
        animateURL: URL?,
        activePackageIDsByCharacterSlug: [String: UUID],
        liveTracks: [String: TimelineTrack]
    ) -> SceneAutomationPlan {
        let sceneCharacters = scene.characterIDs.compactMap { id in
            characters.first(where: { $0.id == id })
        }

        let packageByCharacterID = Dictionary(uniqueKeysWithValues: sceneCharacters.map { character in
            let package = animateURL.flatMap {
                packageLibrary.activePackage(
                    for: character.owpSlug,
                    in: $0,
                    preferredActivePackageID: activePackageIDsByCharacterSlug[character.owpSlug]
                )
            }
            return (character.id, package)
        })

        let characterSummaries = sceneCharacters.map { character in
            buildCharacterSummary(
                character: character,
                package: packageByCharacterID[character.id] ?? nil
            )
        }

        let checklist = buildChecklist(
            sceneCharacters: sceneCharacters,
            characterSummaries: characterSummaries
        )
        let readinessScore = checklist.isEmpty
            ? 1.0
            : checklist.reduce(0.0) { partial, item in
                partial + readinessWeight(for: item.readiness)
            } / Double(checklist.count)

        let complexityScore = buildComplexityScore(
            scene: scene,
            sceneCharacters: sceneCharacters,
            liveTracks: liveTracks
        )
        let supportedPasses = supportedPasses(
            profile: profile,
            characterSummaries: characterSummaries
        )
        let recommendedMode = recommendedExecutionMode(
            profile: profile,
            readinessScore: readinessScore,
            complexityScore: complexityScore,
            characterSummaries: characterSummaries
        )
        let effectiveMode = profile.executionMode == .autoRecommend
            ? recommendedMode
            : profile.executionMode

        return SceneAutomationPlan(
            sceneID: scene.id,
            configuredExecutionMode: profile.executionMode,
            recommendedExecutionMode: recommendedMode,
            effectiveExecutionMode: effectiveMode,
            readinessScore: readinessScore,
            complexityScore: complexityScore,
            supportedPasses: supportedPasses,
            checklist: checklist,
            characterSummaries: characterSummaries,
            recommendedNextSteps: nextSteps(
                checklist: checklist,
                profile: profile,
                recommendedMode: recommendedMode,
                supportedPasses: supportedPasses
            ),
            summary: summaryLine(
                readinessScore: readinessScore,
                complexityScore: complexityScore,
                recommendedMode: recommendedMode
            )
        )
    }

    private func buildCharacterSummary(
        character: AnimationCharacter,
        package: InstalledCharacterPackage?
    ) -> SceneAutomationCharacterSummary {
        let masterSheetCount = character.approvedMasterReferenceSheetVariant == nil ? 0 : 1
        let approvedHeadPoseCount = character.headTurnaroundSlots.filter { $0.approvedVariant != nil }.count
        let costumeSummaries = character.costumeReferenceSets.map { costume in
            let approvedFullBodyPoseCount = costume.fullBodySlots.filter { $0.approvedVariant != nil }.count
            let approvedAccessoryCount = costume.accessorySlots.filter { $0.approvedVariant != nil }.count
            let readiness: SceneAutomationReadiness
            if approvedFullBodyPoseCount >= 6 {
                readiness = approvedAccessoryCount > 0 ? .ready : .partial
            } else if approvedFullBodyPoseCount > 0 || approvedAccessoryCount > 0 {
                readiness = .partial
            } else {
                readiness = .missing
            }
            return SceneAutomationCostumeSummary(
                id: costume.id,
                costumeName: costume.name,
                approvedFullBodyPoseCount: approvedFullBodyPoseCount,
                approvedAccessoryCount: approvedAccessoryCount,
                readiness: readiness
            )
        }

        let expressionCount = package?.manifest.assets.filter { $0.role == .expression }.count ?? 0
        let visemeCount = package?.manifest.assets.filter { $0.role == .viseme }.count ?? 0
        let readyCostumes = costumeSummaries.filter { $0.readiness == .ready }.count
        let packageReady = package?.validationReport.isValid == true

        let readiness: SceneAutomationReadiness
        if masterSheetCount > 0 && approvedHeadPoseCount >= 6 && readyCostumes > 0 && packageReady && visemeCount >= 5 {
            readiness = .ready
        } else if masterSheetCount > 0 || approvedHeadPoseCount > 0 || readyCostumes > 0 || package != nil {
            readiness = .partial
        } else {
            readiness = .missing
        }

        return SceneAutomationCharacterSummary(
            id: character.id,
            characterName: character.name,
            readiness: readiness,
            approvedMasterSheetCount: masterSheetCount,
            approvedHeadPoseCount: approvedHeadPoseCount,
            activePackageName: package?.manifest.displayName,
            activePackageValid: packageReady,
            activePackageExpressionCount: expressionCount,
            activePackageVisemeCount: visemeCount,
            costumeSummaries: costumeSummaries
        )
    }

    private func buildChecklist(
        sceneCharacters: [AnimationCharacter],
        characterSummaries: [SceneAutomationCharacterSummary]
    ) -> [SceneAutomationChecklistItem] {
        guard !sceneCharacters.isEmpty else {
            return [
                SceneAutomationChecklistItem(
                    id: "scene-characters",
                    title: "Scene Characters",
                    detail: "Add at least one character to start building the engine workflow.",
                    metric: "0",
                    readiness: .missing
                )
            ]
        }

        let totalCharacters = sceneCharacters.count
        let masterReadyCount = characterSummaries.filter { $0.approvedMasterSheetCount > 0 }.count
        let headReadyCount = characterSummaries.filter { $0.approvedHeadPoseCount >= 6 }.count
        let costumeReadyCount = characterSummaries.filter { summary in
            summary.costumeSummaries.contains(where: { $0.approvedFullBodyPoseCount >= 6 })
        }.count
        let accessoryReadyCount = characterSummaries.filter { summary in
            summary.costumeSummaries.contains(where: { $0.approvedAccessoryCount > 0 })
        }.count
        let packageReadyCount = characterSummaries.filter {
            $0.activePackageName != nil && $0.activePackageValid
        }.count
        let lipSyncReadyCount = characterSummaries.filter { $0.activePackageVisemeCount >= 5 }.count

        return [
            SceneAutomationChecklistItem(
                id: "master-sheet",
                title: "Master Sheets",
                detail: "Approve one master sheet per scene character before automation branches out.",
                metric: "\(masterReadyCount)/\(totalCharacters)",
                readiness: readinessFrom(ready: masterReadyCount, total: totalCharacters)
            ),
            SceneAutomationChecklistItem(
                id: "head-turnaround",
                title: "Head Turnarounds",
                detail: "Six-pose head grids unlock blink, look-at, and facial automation.",
                metric: "\(headReadyCount)/\(totalCharacters)",
                readiness: readinessFrom(ready: headReadyCount, total: totalCharacters)
            ),
            SceneAutomationChecklistItem(
                id: "costume-turnaround",
                title: "Costume Full Body",
                detail: "At least one six-pose costume pack per character is needed for reusable body coverage.",
                metric: "\(costumeReadyCount)/\(totalCharacters)",
                readiness: readinessFrom(ready: costumeReadyCount, total: totalCharacters)
            ),
            SceneAutomationChecklistItem(
                id: "accessories",
                title: "Accessories",
                detail: "Approved props/gloves/overlays keep hybrid shots on-model.",
                metric: "\(accessoryReadyCount)/\(totalCharacters)",
                readiness: readinessFrom(ready: accessoryReadyCount, total: totalCharacters)
            ),
            SceneAutomationChecklistItem(
                id: "package",
                title: "Rig / Package",
                detail: "A valid installed package is required for reusable in-house animation coverage.",
                metric: "\(packageReadyCount)/\(totalCharacters)",
                readiness: readinessFrom(ready: packageReadyCount, total: totalCharacters)
            ),
            SceneAutomationChecklistItem(
                id: "lipsync",
                title: "Lip Sync",
                detail: "Viseme assets let the engine automate dialogue without handing every mouth cue manually.",
                metric: "\(lipSyncReadyCount)/\(totalCharacters)",
                readiness: readinessFrom(ready: lipSyncReadyCount, total: totalCharacters)
            )
        ]
    }

    private func buildComplexityScore(
        scene: AnimationScene,
        sceneCharacters: [AnimationCharacter],
        liveTracks: [String: TimelineTrack]
    ) -> Double {
        let totalKeyframes = liveTracks.values.reduce(0) { partial, track in
            partial + track.keyframes.count
        }
        let actionTracks = liveTracks.values.filter { $0.role == .action }.count
        let poseTracks = liveTracks.values.filter { $0.role == .pose }.count
        let cameraIntentTracks = liveTracks.values.filter { $0.role == .cameraIntent || $0.role == .cameraBeat }.count
        let motionTracks = liveTracks.values.filter {
            $0.role == .transform && $0.keyframes.count >= 2
        }.count
        let templateBias = scene.directionTemplate?.defaultCameraShot == .extremeWide ? 0.6 : 0

        return Double(max(sceneCharacters.count - 1, 0)) * 1.2
            + Double(actionTracks) * 1.4
            + Double(poseTracks) * 0.8
            + Double(cameraIntentTracks) * 1.5
            + Double(motionTracks) * 0.9
            + min(Double(totalKeyframes) / 12.0, 3.5)
            + templateBias
    }

    private func supportedPasses(
        profile: SceneAutomationProfile,
        characterSummaries: [SceneAutomationCharacterSummary]
    ) -> [SceneAutomationPass] {
        let maxHeadCoverage = characterSummaries.map(\.approvedHeadPoseCount).max() ?? 0
        let hasBodyCoverage = characterSummaries.contains { summary in
            summary.costumeSummaries.contains(where: { $0.approvedFullBodyPoseCount >= 6 })
        }
        let hasVisemes = characterSummaries.contains { $0.activePackageVisemeCount >= 5 }

        return SceneAutomationPass.allCases.filter { pass in
            guard profile.enabledPasses.contains(pass) else { return false }

            switch pass {
            case .blinkPass:
                return maxHeadCoverage >= 1
            case .lookAt:
                return maxHeadCoverage >= 3
            case .idleMotion, .secondaryMotion:
                return hasBodyCoverage
            case .lipSyncGuide:
                return hasVisemes || profile.lipSyncAssistMode != .manualGuide
            case .cameraAssist, .backgroundParallax:
                return true
            }
        }
    }

    private func recommendedExecutionMode(
        profile: SceneAutomationProfile,
        readinessScore: Double,
        complexityScore: Double,
        characterSummaries: [SceneAutomationCharacterSummary]
    ) -> SceneExecutionMode {
        let fullyReadyCharacters = characterSummaries.filter { $0.readiness == .ready }.count

        if readinessScore >= 0.82 && complexityScore <= 4.5 && fullyReadyCharacters == characterSummaries.count {
            return .animateKitOnly
        }

        if complexityScore >= 9.0 && profile.allowGenerativeVideoAssist {
            return .generativeAssist
        }

        if complexityScore >= 5.5 || readinessScore < 0.8 {
            return profile.allowGenerativeVideoAssist ? .hybrid : .animateKitOnly
        }

        return .animateKitOnly
    }

    private func nextSteps(
        checklist: [SceneAutomationChecklistItem],
        profile: SceneAutomationProfile,
        recommendedMode: SceneExecutionMode,
        supportedPasses: [SceneAutomationPass]
    ) -> [String] {
        var steps: [String] = []

        for item in checklist where item.readiness != .ready {
            switch item.id {
            case "master-sheet":
                steps.append("Approve one master sheet per scene character before branching into pose-specific generation.")
            case "head-turnaround":
                steps.append("Complete the six-pose head grids so blink, look-at, and facial automation have clean inputs.")
            case "costume-turnaround":
                steps.append("Finish at least one six-pose full-body costume pack for each character you expect Animate to carry.")
            case "accessories":
                steps.append("Approve accessory overlays such as gloves, field bags, and props to keep kit shots consistent.")
            case "package":
                steps.append("Import or build a valid character package so the engine can reuse assets instead of regenerating coverage.")
            case "lipsync":
                steps.append("Add viseme assets or a viseme-ready package before expecting automated dialogue coverage.")
            default:
                break
            }
        }

        if supportedPasses.isEmpty {
            steps.append("Enable at least one automation pass in the scene engine profile.")
        }

        if recommendedMode == .hybrid && !profile.allowGenerativeVideoAssist {
            steps.append("Allow generative video assist if you want the planner to escalate the hardest shots automatically.")
        }

        return Array(steps.prefix(5))
    }

    private func summaryLine(
        readinessScore: Double,
        complexityScore: Double,
        recommendedMode: SceneExecutionMode
    ) -> String {
        let readinessPercent = Int((readinessScore * 100).rounded())
        let complexityText = String(format: "%.1f", complexityScore)
        return "Readiness \(readinessPercent)% • Complexity \(complexityText) • Recommend \(recommendedMode.displayName)"
    }

    private func readinessFrom(ready: Int, total: Int) -> SceneAutomationReadiness {
        guard total > 0 else { return .missing }
        if ready >= total { return .ready }
        if ready > 0 { return .partial }
        return .missing
    }

    private func readinessWeight(for readiness: SceneAutomationReadiness) -> Double {
        switch readiness {
        case .missing: 0
        case .partial: 0.5
        case .ready: 1
        }
    }
}
