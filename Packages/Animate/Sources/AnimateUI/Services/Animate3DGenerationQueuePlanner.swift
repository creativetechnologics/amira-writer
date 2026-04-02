import Foundation

@available(macOS 26.0, *)
@MainActor
struct Animate3DGenerationQueuePlanner {
    let store: AnimateStore

    func buildPlan(
        scene: AnimationScene,
        backgroundName: String?,
        worldChunk: Animate3DWorldChunkDescriptor?,
        styleProfile: Animate3DStyleProfileDescriptor?,
        lightRig: Animate3DLightRigDescriptor?,
        atmospherePreset: Animate3DAtmospherePresetDescriptor?,
        bundleReadiness: [Animate3DCharacterBundleReadinessStatus],
        runtimeCharacters: [Animate3DCharacterPerformanceStatus] = []
    ) -> [Animate3DGenerationQueueItem] {
        let productionPlan = SceneProductionPlan(
            sceneID: scene.id,
            sceneName: scene.name,
            backgroundName: backgroundName,
            totalFrames: 0,
            baseFPS: max(store.fps, 1),
            worldChunk: worldChunk,
            styleProfile: styleProfile,
            availableCameraPresetCount: 0,
            lightRig: lightRig,
            atmospherePreset: atmospherePreset,
            characterBlocking: [],
            cameraChoreography: CameraChoreographyPlan(keyframes: []),
            objectPlacements: [],
            depthAssignments: [],
            frameRateProfile: VariableFrameRateProfile(
                characterHoldStyles: [:],
                defaultCharacterHold: .onTwos,
                cameraHold: .onOnes,
                backgroundHold: .onThrees,
                defaultObjectHold: .onTwos
            )
        )
        let allItems = plan(
            scene: scene,
            productionPlan: productionPlan,
            runtimeCharacters: runtimeCharacters
        ).items
        let missingCategoriesBySlug = Dictionary(
            uniqueKeysWithValues: bundleReadiness.map { ($0.characterSlug, Set($0.missingCategories)) }
        )

        return allItems.filter { item in
            switch item.kind {
            case .bodyModel:
                return matchesMissing(.models, item: item, missing: missingCategoriesBySlug)
            case .faceRig:
                return matchesMissing(.faceRigs, item: item, missing: missingCategoriesBySlug)
            case .mouthProfile:
                return matchesMissing(.mouthProfiles, item: item, missing: missingCategoriesBySlug)
            case .expressionLibrary:
                return matchesMissing(.expressions, item: item, missing: missingCategoriesBySlug)
            case .motionSet:
                return matchesMissing(.motions, item: item, missing: missingCategoriesBySlug)
            case .materialProfile:
                return matchesMissing(.materials, item: item, missing: missingCategoriesBySlug)
            default:
                return true
            }
        }
    }

    func plan(
        scene: AnimationScene,
        productionPlan: SceneProductionPlan,
        runtimeCharacters: [Animate3DCharacterPerformanceStatus] = []
    ) -> Animate3DGenerationQueue {
        let assetService = Animate3DCharacterAssetService()
        let registryBundleService = Animate3DRegistryBundleService(store: store)
        var items: [Animate3DGenerationQueueItem] = []
        let runtimeStatusesBySlug = Dictionary(grouping: runtimeCharacters) { $0.characterSlug.lowercased() }

        let sceneCharacters = scene.characterIDs.compactMap { id in
            store.characters.first(where: { $0.id == id })
        }
        let placeName = productionPlan.backgroundName ?? scene.name

        for character in sceneCharacters {
            let inventory = assetService.inventory(for: character.assetFolderSlug, in: store.animateURL)
            let referencePath = character.approvedMasterReferenceSheetVariant?.imagePath
                ?? character.approvedHeadTurnaroundSheetVariant?.imagePath
                ?? character.masterReferenceSourceImagePaths.first

            if !hasCharacterAsset(.models, character: character, inventory: inventory, registryBundleService: registryBundleService) {
                items.append(
                    queueItem(
                        kind: .bodyModel,
                        title: "\(character.name) 3D body model",
                        detail: "Generate a cel-shaded 3D body model aligned to the approved turnaround/master sheet.",
                        destinationPath: "Animate/characters/\(character.assetFolderSlug)/models/",
                        providerHint: "Meshy / Rodin / local 2D→3D",
                        prompt: "Create a cel-shaded anime 3D body model for \(character.name) using \(referencePrompt(referencePath)) as the geometry and costume reference.",
                        characterSlug: character.assetFolderSlug,
                        characterName: character.name,
                        sceneName: scene.name,
                        placeName: placeName
                    )
                )
            }

            if !hasCharacterAsset(.faceRigs, character: character, inventory: inventory, registryBundleService: registryBundleService) {
                items.append(
                    queueItem(
                        kind: .faceRig,
                        title: "\(character.name) face rig",
                        detail: "Map brows, eyes, mouth, and jaw so the expression engine can drive the model.",
                        destinationPath: "Animate/characters/\(character.assetFolderSlug)/face-rigs/",
                        providerHint: "Author / export JSON sidecar",
                        prompt: "Author a face-rig sidecar for \(character.name) with brows, eyes, mouth, jaw, and blendshape mappings for cel-shaded performance.",
                        characterSlug: character.assetFolderSlug,
                        characterName: character.name,
                        sceneName: scene.name,
                        placeName: placeName
                    )
                )
            }

            if !hasCharacterAsset(.mouthProfiles, character: character, inventory: inventory, registryBundleService: registryBundleService) {
                items.append(
                    queueItem(
                        kind: .mouthProfile,
                        title: "\(character.name) mouth profile",
                        detail: "Add viseme presets for lyrical mouth movement.",
                        destinationPath: "Animate/characters/\(character.assetFolderSlug)/mouth-profiles/",
                        providerHint: "JSON viseme profile",
                        prompt: "Create a Preston-Blair style viseme mouth profile for \(character.name) tuned for anime singing and dialogue.",
                        characterSlug: character.assetFolderSlug,
                        characterName: character.name,
                        sceneName: scene.name,
                        placeName: placeName
                    )
                )
            }

            if !hasCharacterAsset(.expressions, character: character, inventory: inventory, registryBundleService: registryBundleService) {
                items.append(
                    queueItem(
                        kind: .expressionLibrary,
                        title: "\(character.name) expression library",
                        detail: "Add authored expression presets beyond the fallback heuristic runtime.",
                        destinationPath: "Animate/characters/\(character.assetFolderSlug)/expressions/",
                        providerHint: "Nano Banana 2 / JSON metadata",
                        prompt: "Generate an expression library for \(character.name) covering joy, sadness, anger, determination, surprise, attentive, and neutral anime states.",
                        characterSlug: character.assetFolderSlug,
                        characterName: character.name,
                        sceneName: scene.name,
                        placeName: placeName
                    )
                )
            }

            if !hasCharacterAsset(.motions, character: character, inventory: inventory, registryBundleService: registryBundleService) {
                let motionCueSummary = summarizeMotionCues(
                    runtimeStatusesBySlug[character.assetFolderSlug.lowercased()] ?? []
                )
                items.append(
                    queueItem(
                        kind: .motionSet,
                        title: "\(character.name) motion set",
                        detail: motionCueSummary.map {
                            "Add reusable locomotion and acting clips for low-touch staging. Prioritize \($0)."
                        } ?? "Add reusable locomotion and acting clips for low-touch staging.",
                        destinationPath: "Animate/characters/\(character.assetFolderSlug)/motions/",
                        providerHint: "Motion clips / animation JSON",
                        prompt: motionCueSummary.map {
                            "Author a reusable motion set for \(character.name) including idle, walk, turn, present, listen, react, and sing beats. Prioritize the currently observed scene cues: \($0)."
                        } ?? "Author a reusable motion set for \(character.name) including idle, walk, turn, present, listen, react, and sing beats.",
                        characterSlug: character.assetFolderSlug,
                        characterName: character.name,
                        sceneName: scene.name,
                        placeName: placeName
                    )
                )
            }

            if !hasCharacterAsset(.materials, character: character, inventory: inventory, registryBundleService: registryBundleService) {
                items.append(
                    queueItem(
                        kind: .materialProfile,
                        title: "\(character.name) material profile",
                        detail: "Tune cel shading/material response so the model matches the Amira look.",
                        destinationPath: "Animate/characters/\(character.assetFolderSlug)/materials/",
                        providerHint: "Lookdev JSON",
                        prompt: "Create a cel-shaded material profile for \(character.name) with anime-safe skin, fabric, hair, and outline response.",
                        characterSlug: character.assetFolderSlug,
                        characterName: character.name,
                        sceneName: scene.name,
                        placeName: placeName
                    )
                )
            }
        }

        if productionPlan.styleProfile == nil {
            items.append(
                queueItem(
                    kind: .styleProfile,
                    title: "Project style profile",
                    detail: "Define the cel bands and outline settings used by the 3D production preview.",
                    destinationPath: "Animate/3d/style-profiles/style-profiles.json",
                    providerHint: "In-app registry",
                    prompt: "Define a mature cel-shaded anime style profile for Amira with 3 bands and medium outlines.",
                    sceneName: scene.name,
                    placeName: placeName,
                    manifestKind: .styleProfiles
                )
            )
        }

        if productionPlan.availableCameraPresetCount == 0 {
            items.append(
                queueItem(
                    kind: .cameraPresetLibrary,
                    title: "Camera preset library",
                    detail: "Seed deterministic focal-length presets for wide, medium, close, and specialty shots.",
                    destinationPath: "Animate/3d/camera-presets/camera-presets.json",
                    providerHint: "In-app registry",
                    prompt: "Create a camera preset library mapping extremeWide, wide, medium, mediumClose, close, and extremeClose to cinematic focal lengths.",
                    sceneName: scene.name,
                    placeName: placeName,
                    manifestKind: .cameraPresets
                )
            )
        }

        if productionPlan.worldChunk == nil {
            items.append(
                queueItem(
                    kind: .worldChunk,
                    title: "\(placeName) world chunk",
                    detail: "Map this scene place to an explorable 3D zone in the world catalog.",
                    destinationPath: "Animate/3d/world-catalog/world-catalog.json",
                    providerHint: "World registry",
                    prompt: "Create a world catalog entry for \(placeName) with placeNames, preview image, mesh path, and linked light/atmosphere presets.",
                    characterName: "Environment",
                    sceneName: scene.name,
                    placeName: placeName,
                    manifestKind: .worldCatalog
                )
            )
        } else {
            let chunk = productionPlan.worldChunk!
            if chunk.previewImagePath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                items.append(
                    queueItem(
                        kind: .worldPreviewImage,
                        title: "\(placeName) world preview",
                        detail: "Add a preview image that the 3D engine can use as a background while world meshes are incomplete.",
                        destinationPath: "Animate/3d/world-catalog/",
                        providerHint: GeminiModel.flash.displayName,
                        prompt: "Generate a 21:9 cel-shaded anime environment plate for \(placeName) suitable for use as a 3D world chunk preview.",
                        characterName: "Environment",
                        sceneName: scene.name,
                        placeName: placeName,
                        manifestKind: .worldCatalog
                    )
                )
            }
            if chunk.meshPath?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                items.append(
                    queueItem(
                        kind: .worldMesh,
                        title: "\(placeName) world mesh",
                        detail: "Add the actual 3D world geometry for this chunk.",
                        destinationPath: "Animate/3d/world-catalog/",
                        providerHint: "World Labs / local DCC",
                        prompt: "Generate or export the 3D world mesh for \(placeName) as an explorable cel-shaded zone.",
                        characterName: "Environment",
                        sceneName: scene.name,
                        placeName: placeName,
                        manifestKind: .worldCatalog
                    )
                )
            }
        }

        if productionPlan.lightRig == nil {
            items.append(
                queueItem(
                    kind: .lightRig,
                    title: "\(placeName) light rig",
                    detail: "Add a reusable lighting package for this world chunk/scene.",
                    destinationPath: "Animate/3d/light-rigs/light-rigs.json",
                    providerHint: "In-app registry",
                    prompt: "Create a cinematic anime light rig for \(placeName) with balanced key, fill, and rim intensities.",
                    characterName: "Environment",
                    sceneName: scene.name,
                    placeName: placeName,
                    manifestKind: .lightRigs
                )
            )
        }

        if productionPlan.atmospherePreset == nil {
            items.append(
                queueItem(
                    kind: .atmospherePreset,
                    title: "\(placeName) atmosphere preset",
                    detail: "Add haze/fog/palette settings for the scene world chunk.",
                    destinationPath: "Animate/3d/atmosphere-presets/atmosphere-presets.json",
                    providerHint: "In-app registry",
                    prompt: "Create an atmosphere preset for \(placeName) defining fog density, haze, and a cel-shaded anime palette tint.",
                    characterName: "Environment",
                    sceneName: scene.name,
                    placeName: placeName,
                    manifestKind: .atmospherePresets
                )
            )
        }

        return Animate3DGenerationQueue(items: items)
    }

    private func queueItem(
        kind: Animate3DGenerationQueueItem.Kind,
        title: String,
        detail: String,
        destinationPath: String,
        providerHint: String,
        prompt: String,
        characterSlug: String? = nil,
        characterName: String? = nil,
        sceneName: String? = nil,
        placeName: String? = nil,
        manifestKind: Animate3DRegistryManifestKind? = nil
    ) -> Animate3DGenerationQueueItem {
        Animate3DGenerationQueueItem(
            kind: kind,
            title: title,
            detail: detail,
            destinationPath: destinationPath,
            providerHint: providerHint,
            prompt: prompt,
            characterSlug: characterSlug,
            characterName: characterName,
            sceneName: sceneName,
            placeName: placeName,
            manifestKind: manifestKind
        )
    }

    private func referencePrompt(_ path: String?) -> String {
        path ?? "the approved turnaround and master-sheet references"
    }

    private func summarizeMotionCues(_ statuses: [Animate3DCharacterPerformanceStatus]) -> String? {
        let cues = Array(Set(statuses.flatMap { status in
            [status.sourceActionCue, status.sourcePoseCue, status.resolvedMotionTitle]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        })).sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        guard !cues.isEmpty else { return nil }
        return cues.joined(separator: ", ")
    }

    private func matchesMissing(
        _ category: Animate3DCharacterAssetCategory,
        item: Animate3DGenerationQueueItem,
        missing: [String: Set<Animate3DCharacterAssetCategory>]
    ) -> Bool {
        guard item.kind == .bodyModel || item.kind == .faceRig || item.kind == .mouthProfile
            || item.kind == .expressionLibrary || item.kind == .motionSet || item.kind == .materialProfile else {
            return true
        }
        return missing.contains { slug, categories in
            item.destinationPath.contains("/\(slug)/") && categories.contains(category)
        }
    }

    private func hasCharacterAsset(
        _ category: Animate3DCharacterAssetCategory,
        character: AnimationCharacter,
        inventory: Animate3DCharacterAssetInventory,
        registryBundleService: Animate3DRegistryBundleService
    ) -> Bool {
        if !inventory.files(for: category).isEmpty {
            return true
        }
        if category == .models && !character.models3D.isEmpty {
            return true
        }
        return registryBundleService.provides(category, for: character.assetFolderSlug)
    }
}
