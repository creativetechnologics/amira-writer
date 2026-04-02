import Foundation

@available(macOS 26.0, *)
@MainActor
struct Animate3DAssetGapQueueService {
    let store: AnimateStore

    @discardableResult
    func queueMissingDrafts(
        scene: AnimationScene?,
        status: Animate3DProductionStatus
    ) -> Int {
        enqueue(generationDrafts(scene: scene, status: status))
    }

    @discardableResult
    func queue(
        item: Animate3DGenerationQueueItem,
        scene: AnimationScene?,
        status: Animate3DProductionStatus
    ) -> Int {
        guard let draft = queuedDraft(for: item, scene: scene, status: status) else {
            return 0
        }
        return enqueue([draft])
    }

    func draft(
        for item: Animate3DGenerationQueueItem,
        scene: AnimationScene?,
        status: Animate3DProductionStatus
    ) -> GeminiGenerationDraft? {
        queuedDraft(for: item, scene: scene, status: status)?.draft
    }

    private func generationDrafts(
        scene: AnimationScene?,
        status: Animate3DProductionStatus
    ) -> [QueuedDraft] {
        let planned = plannedDrafts(scene: scene, status: status)
        guard !planned.isEmpty else {
            return legacyFallbackDrafts(scene: scene, status: status)
        }
        return deduplicated(planned)
    }

    private func queuedDraft(
        for item: Animate3DGenerationQueueItem,
        scene: AnimationScene?,
        status: Animate3DProductionStatus
    ) -> QueuedDraft? {
        guard item.isBatchDraftable else { return nil }
        return plannedDrafts(scene: scene, status: status)
            .first(where: { $0.matches(item: item) })
    }

    private func enqueue(_ drafts: [QueuedDraft]) -> Int {
        let existingKeys = Set(store.batchQueue.map { item in
            queueKey(
                owner: item.characterSlug ?? item.outputRootRelativePath ?? item.characterName,
                title: item.draftTitle,
                destination: item.draft.destinationDescription
            )
        })
        var queuedCount = 0
        for draft in drafts {
            let owner = draft.characterSlug
                ?? draft.outputRootRelativePath
                ?? draft.characterName
            let key = queueKey(
                owner: owner,
                title: draft.draft.title,
                destination: draft.draft.destinationDescription
            )
            guard !existingKeys.contains(key) else { continue }
            if let characterID = draft.characterID {
                store.addToBatchQueue(
                    characterID: characterID,
                    characterName: draft.characterName,
                    draftTitle: draft.draft.title,
                    draft: draft.draft,
                    characterSlug: draft.characterSlug
                )
            } else if let outputRootRelativePath = draft.outputRootRelativePath {
                store.addToBatchQueue(
                    pipelineName: draft.characterName,
                    draftTitle: draft.draft.title,
                    draft: draft.draft,
                    outputRootRelativePath: outputRootRelativePath
                )
            }
            queuedCount += 1
        }
        return queuedCount
    }

    private func referenceDrafts(for character: AnimationCharacter) -> [GeminiGenerationReferenceDraft] {
        var refs: [GeminiGenerationReferenceDraft] = []

        if let path = character.approvedMasterReferenceSheetVariant?.imagePath {
            refs.append(GeminiGenerationReferenceDraft(label: "Master Sheet", path: path))
        }
        if let path = character.approvedHeadTurnaroundSheetVariant?.imagePath {
            refs.append(GeminiGenerationReferenceDraft(label: "Head Turnaround", path: path))
        }
        if let path = character.profileImagePath {
            refs.append(GeminiGenerationReferenceDraft(label: "Profile", path: path))
        }

        if refs.isEmpty {
            refs = character.referenceImagePaths.prefix(3).enumerated().map { index, path in
                GeminiGenerationReferenceDraft(label: "Reference \(index + 1)", path: path)
            }
        }

        return refs
    }

    private func placeReferenceDrafts(placeName: String) -> [GeminiGenerationReferenceDraft] {
        let matchingPlace = store.backgrounds.first {
            $0.name.caseInsensitiveCompare(placeName) == .orderedSame
        }
        let referencePaths = [
            matchingPlace?.resolvedApprovedImagePath,
            matchingPlace?.imagePaths.first
        ].compactMap { $0 }

        return referencePaths.enumerated().map { index, path in
            GeminiGenerationReferenceDraft(label: "Place \(index + 1)", path: path)
        }
    }

    private func destinationDescription(for category: Animate3DCharacterAssetCategory) -> String {
        switch category {
        case .models:
            "3D character turnaround source sheet"
        case .faceRigs:
            "3D face rig guide sheet"
        case .mouthProfiles:
            "viseme / mouth profile sheet"
        case .expressions:
            "expression sheet"
        case .motions:
            "key pose motion sheet"
        case .materials:
            "material / lookdev board"
        }
    }

    private func aspectRatio(for category: Animate3DCharacterAssetCategory) -> String {
        switch category {
        case .motions, .materials:
            "16:9"
        default:
            "4:3"
        }
    }

    private func prompt(
        for character: AnimationCharacter,
        category: Animate3DCharacterAssetCategory
    ) -> String {
        let name = character.name
        switch category {
        case .models:
            return "Create a clean cel-shaded anime turnaround sheet for \(name) designed to support 3D model reconstruction. Include front, 3/4 left, left profile, back, right profile, and 3/4 right full-body views. Preserve costume shapes, proportions, silhouette clarity, hair volume, and surface color separation. Neutral pose, orthographic feeling, even lighting, plain studio backdrop, no text."
        case .faceRigs:
            return "Create a cel-shaded anime facial rig guide sheet for \(name). Show neutral face plus overlay-friendly guides for brows, eyes, lids, cheeks, jaw hinge, mouth corners, and mouth center. Keep the art clean and technical enough for 3D face-rig placement. Plain backdrop, consistent head angle, no extra props, no text."
        case .mouthProfiles:
            return "Create a Preston Blair style viseme mouth chart for \(name) in a cel-shaded anime style. Include rest, AI, E, O, U, MBP, FV, L, and WQ mouth shapes, aligned consistently for 3D lipsync profiling. Clean technical sheet, plain backdrop, no text."
        case .expressions:
            return "Create an 8-expression cel-shaded anime expression sheet for \(name): neutral, joy, determined, angry, sad, surprised, worried, and attentive. Keep head angle consistent for 3D expression extraction. Plain backdrop, clean lighting, no text."
        case .motions:
            return "Create a cel-shaded anime key-pose motion sheet for \(name) for 3D staging reference. Include clear silhouettes for idle, walk start, walk passing, point, present, react, listen, and confront poses. Full body, clean staging, plain backdrop, no text."
        case .materials:
            return "Create a cel-shaded anime material and lookdev board for \(name). Highlight costume fabrics, leather/metal accents, hair color breakup, skin tone reference, shadow shapes, and specular treatment needed for toon-shaded 3D rendering. Consistent lighting, plain backdrop, no text."
        }
    }

    private func worldPrompt(sceneName: String, placeName: String) -> String {
        "Create a cel-shaded anime world-building concept board for the place '\(placeName)' in scene '\(sceneName)'. Show a wide explorable environment suitable for conversion into a 3D world chunk, including traversal paths, landmark silhouettes, foreground/midground/background separation, and readable lighting mood. No characters, no text, cinematic 16:9 composition."
    }

    private func plannedDrafts(
        scene: AnimationScene?,
        status: Animate3DProductionStatus
    ) -> [QueuedDraft] {
        status.generationQueueItems.compactMap { item in
            guard item.isBatchDraftable else { return nil }

            if let character = character(for: item.characterSlug) {
                return QueuedDraft(
                    characterID: character.id,
                    characterName: character.name,
                    characterSlug: character.assetFolderSlug,
                    outputRootRelativePath: nil,
                    draft: GeminiGenerationDraft(
                        title: item.title,
                        destinationDescription: item.destinationDescription,
                        prompt: item.prompt,
                        model: store.selectedGeminiModel,
                        aspectRatio: item.draftAspectRatio,
                        imageSize: "1K",
                        referenceItems: referenceDrafts(for: character),
                        pricingMode: .batch
                    )
                )
            }

            let environmentName = item.placeName
                ?? status.backgroundName
                ?? scene?.directionTemplate?.notes.nilIfEmpty
                ?? item.sceneName
                ?? status.sceneName
            return QueuedDraft(
                characterID: nil,
                characterName: item.characterName ?? "Environment",
                characterSlug: nil,
                outputRootRelativePath: pipelineOutputRelativePath(for: item),
                draft: GeminiGenerationDraft(
                    title: item.title,
                    destinationDescription: item.destinationDescription,
                    prompt: item.prompt,
                    model: store.selectedGeminiModel,
                    aspectRatio: item.draftAspectRatio,
                    imageSize: "1K",
                    referenceItems: placeReferenceDrafts(placeName: environmentName),
                    pricingMode: .batch
                )
            )
        }
    }

    private func legacyFallbackDrafts(
        scene: AnimationScene?,
        status: Animate3DProductionStatus
    ) -> [QueuedDraft] {
        var results: [QueuedDraft] = []

        for readiness in status.bundleReadiness where !readiness.isReady {
            guard let character = character(for: readiness.characterSlug) else { continue }

            let references = referenceDrafts(for: character)
            for category in readiness.missingCategories {
                results.append(
                    QueuedDraft(
                        characterID: character.id,
                        characterName: character.name,
                        characterSlug: character.assetFolderSlug,
                        outputRootRelativePath: nil,
                        draft: GeminiGenerationDraft(
                            title: "\(character.name) — \(category.displayName)",
                            destinationDescription: destinationDescription(for: category),
                            prompt: prompt(for: character, category: category),
                            model: store.selectedGeminiModel,
                            aspectRatio: aspectRatio(for: category),
                            imageSize: "1K",
                            referenceItems: references,
                            pricingMode: .batch
                        )
                    )
                )
            }
        }

        if status.worldChunkTitle == nil,
           let scene,
           let placeName = status.backgroundName ?? scene.directionTemplate?.notes.nilIfEmpty {
            results.append(
                QueuedDraft(
                    characterID: nil,
                    characterName: "Environment",
                    characterSlug: nil,
                    outputRootRelativePath: "3d/world-catalog/batch-queue-batches",
                    draft: GeminiGenerationDraft(
                        title: "\(scene.name) — World Chunk Concept",
                        destinationDescription: "3D world chunk concept board",
                        prompt: worldPrompt(sceneName: scene.name, placeName: placeName),
                        model: store.selectedGeminiModel,
                        aspectRatio: "16:9",
                        imageSize: "1K",
                        referenceItems: placeReferenceDrafts(placeName: placeName),
                        pricingMode: .batch
                    )
                )
            )
        }

        return results
    }

    private func deduplicated(_ drafts: [QueuedDraft]) -> [QueuedDraft] {
        var seen: Set<String> = []
        return drafts.filter { queued in
            let owner = queued.characterSlug
                ?? queued.outputRootRelativePath
                ?? queued.characterName
            let key = queueKey(
                owner: owner,
                title: queued.draft.title,
                destination: queued.draft.destinationDescription
            )
            return seen.insert(key).inserted
        }
    }

    private func pipelineOutputRelativePath(for item: Animate3DGenerationQueueItem) -> String {
        let trimmed = item.targetRelativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.hasPrefix("Animate/")
            ? String(trimmed.dropFirst("Animate/".count))
            : trimmed
        let directory = normalized.hasSuffix("/")
            ? normalized
            : (normalized as NSString).deletingLastPathComponent
        let cleanedDirectory = directory.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return cleanedDirectory.isEmpty
            ? "3d/generation-queue-batches"
            : "\(cleanedDirectory)/batch-queue-batches"
    }

    private func character(for slug: String?) -> AnimationCharacter? {
        guard let slug, !slug.isEmpty else { return nil }
        return store.characters.first {
            $0.assetFolderSlug == slug || $0.owpSlug == slug
        }
    }

    private func queueKey(owner: String, title: String, destination: String) -> String {
        "\(owner.lowercased())|\(title.lowercased())|\(destination.lowercased())"
    }
}

@available(macOS 26.0, *)
private extension Animate3DAssetGapQueueService {
    struct QueuedDraft {
        var characterID: UUID?
        var characterName: String
        var characterSlug: String?
        var outputRootRelativePath: String?
        var draft: GeminiGenerationDraft

        func matches(item: Animate3DGenerationQueueItem) -> Bool {
            draft.title == item.title &&
            draft.destinationDescription == item.destinationDescription &&
            characterSlug == item.characterSlug &&
            characterName == (item.characterName ?? characterName)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
