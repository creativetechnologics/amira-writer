import Foundation
import SwiftUI

@available(macOS 26.0, *)
struct Animate3DCharacterPerformanceStatus: Identifiable, Hashable, Sendable {
    var id: String { characterName }
    var characterName: String
    var characterSlug: String
    var preferredCostumeName: String?
    var resolvedBundleCostumeName: String?
    var resolvedBundleSourcePath: String?
    var resolvedBundleAssetPaths: [String]
    var modelFileName: String?
    var modelSourcePath: String?
    var driverMode: CharacterPerformanceDriverMode
    var profileSourceFileName: String?
    var profileSourcePath: String?
    var profileSourceCount: Int
    var profileSourcePaths: [String]
    var mouthProfileID: String?
    var expressionPresetCount: Int
    var visemePresetCount: Int
    var usingExpressionPreset: Bool
    var usingVisemePreset: Bool
    var resolvedExpressionPresetCue: String?
    var resolvedVisemePresetCue: String?
    var sourceExpressionCue: String
    var sourceVisemeCue: String
    var expressionBehaviorCue: String?
    var expressionCueProvenance: String?
    var visemeCueProvenance: String?
    var activeExpressionCue: String
    var activeVisemeCue: String
    var isVisible: Bool

    var driverSummary: String {
        switch driverMode {
        case .profileMapped:
            return "Authored profile"
        case .hybridFallback:
            return "Profile + generated fallback"
        case .generatedOverlay:
            return "Generated overlay"
        }
    }
}

@available(macOS 26.0, *)
struct Animate3DCharacterBundleReadinessStatus: Identifiable, Hashable, Sendable {
    var id: String { characterSlug }
    var characterName: String
    var characterSlug: String
    var preferredCostumeName: String?
    var resolvedBundleCostumeName: String?
    var resolvedBundleSourcePath: String?
    var resolvedBundleAssetPaths: [String]
    var readyCategories: [Animate3DCharacterAssetCategory]
    var registryBackedCategories: [Animate3DCharacterAssetCategory]
    var missingCategories: [Animate3DCharacterAssetCategory]
    var totalFileCount: Int

    var isReady: Bool { missingCategories.isEmpty }
}

@available(macOS 26.0, *)
struct Animate3DProductionStatus: Hashable, Sendable {
    var planLoaded: Bool
    var rendererModeTitle: String
    var sceneName: String
    var backgroundName: String?
    var worldChunkTitle: String?
    var styleProfileTitle: String?
    var lightRigTitle: String?
    var atmospherePresetTitle: String?
    var cameraPresetCount: Int
    var baseFPS: Int
    var totalFrames: Int
    var characterCount: Int
    var propCount: Int
    var modelBackedCharacterCount: Int
    var performanceProfileCount: Int
    var runtimeCharacters: [Animate3DCharacterPerformanceStatus]
    var bundleReadiness: [Animate3DCharacterBundleReadinessStatus]
    var generationQueueItems: [Animate3DGenerationQueueItem]
    var warnings: [String]

    static let empty = Animate3DProductionStatus(
        planLoaded: false,
        rendererModeTitle: "Production Engine",
        sceneName: "No Scene",
        backgroundName: nil,
        worldChunkTitle: nil,
        styleProfileTitle: nil,
        lightRigTitle: nil,
        atmospherePresetTitle: nil,
        cameraPresetCount: 0,
        baseFPS: 24,
        totalFrames: 0,
        characterCount: 0,
        propCount: 0,
        modelBackedCharacterCount: 0,
        performanceProfileCount: 0,
        runtimeCharacters: [],
        bundleReadiness: [],
        generationQueueItems: [],
        warnings: []
    )
}

@available(macOS 26.0, *)
@MainActor
final class Animate3DProductionCoordinator: ObservableObject {
    @Published private(set) var status: Animate3DProductionStatus = .empty
    @Published private(set) var plan: SceneProductionPlan?

    let renderer: ScenePreviewRenderer

    private weak var store: AnimateStore?
    private var loadedSignature = ""

    init(store: AnimateStore) {
        self.store = store
        self.renderer = ScenePreviewRenderer(store: store)
    }

    func refresh(
        scene: AnimationScene?,
        lyrics: String,
        scenario: Animate3DPreviewScenario,
        forceReload: Bool = false
    ) async {
        guard let store, let scene else {
            plan = nil
            status = .empty
            return
        }

        let signature = signatureFor(scene: scene, lyrics: lyrics, store: store)
        let existingPlan = plan
        if !forceReload, signature == loadedSignature, existingPlan != nil {
            renderer.renderFrame(min(max(0, store.currentFrame), max(0, renderer.totalFrames - 1)))
            return
        }

        let productionInput = makeInput(scene: scene, lyrics: lyrics, store: store, scenario: scenario)
        let compiledPlan = SceneProductionCompiler.compile(productionInput)
        await renderer.loadPlan(compiledPlan)
        renderer.renderFrame(min(max(0, store.currentFrame), max(0, compiledPlan.totalFrames - 1)))

        loadedSignature = signature
        plan = compiledPlan
        status = makeStatus(for: compiledPlan, scene: scene, store: store, renderer: renderer)
    }

    func render(frame: Int) {
        renderer.renderFrame(frame)
    }
}

@available(macOS 26.0, *)
private extension Animate3DProductionCoordinator {
    func signatureFor(scene: AnimationScene, lyrics: String, store: AnimateStore) -> String {
        let assetService = Animate3DCharacterAssetService()
        let registryBundleService = Animate3DRegistryBundleService(store: store)
        let modelSignature = scene.characterIDs.compactMap { id in
            store.characters.first(where: { $0.id == id })
        }.map { character in
            let inventory = assetService.inventory(for: character.assetFolderSlug, in: store.animateURL)
            let inventorySignature = Animate3DCharacterAssetCategory.allCases.map { category in
                let files = inventory.files(for: category).map {
                    "\($0.relativePath):\(Int(($0.modificationDate ?? .distantPast).timeIntervalSince1970))"
                }.joined(separator: ",")
                return "\(category.folderName)=\(files)"
            }.joined(separator: ";")
            let registrySignature = registryBundleService.signature(for: character.assetFolderSlug)
            return "\(character.assetFolderSlug):models3D=\(character.models3D.map(\.modelFileName).joined(separator: ","))#inventory=\(inventorySignature)#registry=\(registrySignature)"
        }.joined(separator: "|")
        let shotSignature = scene.shots.map { "\($0.id.uuidString):\($0.startFrame)-\($0.endFrame)" }.joined(separator: "|")
        let objectSignature = scene.objectSetups.map { "\($0.objectName):\($0.enterFrame)-\($0.exitFrame ?? -1)" }.joined(separator: "|")
        let registrySignature = (store.workingOWPURL ?? store.owpURL).map(registrySignature(projectURL:)) ?? "no-registry"
        return [
            scene.id.uuidString,
            String(lyrics.hashValue),
            String(store.fps),
            String(store.currentFrame),
            shotSignature,
            objectSignature,
            modelSignature,
            registrySignature
        ].joined(separator: "#")
    }

    func makeInput(
        scene: AnimationScene,
        lyrics: String,
        store: AnimateStore,
        scenario: Animate3DPreviewScenario
    ) -> SceneProductionInput {
        let parseResult = lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : SceneDirectionParser.parse(lyrics)
        let bpm = store.currentSongData?.tempoEvents.sorted(by: { $0.tick < $1.tick }).first?.bpm ?? 120
        let totalBeats: Int = {
            guard let songData = store.currentSongData else {
                return max(4, Int(ceil(Double(max(scene.shots.map(\.endFrame).max() ?? store.fps, store.fps)) / Double(max(store.fps, 1))) * bpm / 60.0))
            }
            return max(4, Int(ceil(Double(songData.lengthTicks) / Double(max(songData.ticksPerQuarter, 1)))))
        }()
        let backgroundName = scene.backgroundID.flatMap { id in
            store.backgrounds.first(where: { $0.id == id })?.name
        } ?? scenario.backgroundName
        let automationProfile = store.resolvedAutomationProfile(for: scene)
        let characterCast = scene.characterIDs.compactMap { id -> SceneProductionCharacterInput? in
            guard let character = store.characters.first(where: { $0.id == id }) else {
                return nil
            }
            let preferredCostumeName = automationProfile?
                .characterProfile(for: id)?
                .preferredCostumeName
                ?? character.costumeReferenceSets.first?.name
            return SceneProductionCharacterInput(
                name: character.name,
                slug: character.assetFolderSlug,
                preferredCostumeName: preferredCostumeName
            )
        }
        let projectURL = store.workingOWPURL ?? store.owpURL
        let worldCatalog = projectURL.flatMap(ProjectDatabaseBridge.loadAnimate3DWorldCatalogFromDisk(projectURL:))
            ?? Animate3DWorldCatalog()
        let styleProfiles = projectURL.flatMap(ProjectDatabaseBridge.loadAnimate3DStyleProfilesFromDisk(projectURL:))
            ?? Animate3DStyleProfileManifest()
        let cameraPresets = projectURL.flatMap(ProjectDatabaseBridge.loadAnimate3DCameraPresetsFromDisk(projectURL:))
            ?? Animate3DCameraPresetManifest()
        let lightRigs = projectURL.flatMap(ProjectDatabaseBridge.loadAnimate3DLightRigsFromDisk(projectURL:))
            ?? Animate3DLightRigManifest()
        let atmospherePresets = projectURL.flatMap(ProjectDatabaseBridge.loadAnimate3DAtmospherePresetsFromDisk(projectURL:))
            ?? Animate3DAtmospherePresetManifest()
        let worldChunk = resolveWorldChunk(
            worldCatalog: worldCatalog,
            backgroundName: backgroundName,
            sceneName: scene.name
        )
        let styleProfile = resolveStyleProfile(worldChunk: worldChunk, styleProfiles: styleProfiles)
        let lightRig = resolveLightRig(worldChunk: worldChunk, lightRigs: lightRigs)
        let atmospherePreset = resolveAtmospherePreset(worldChunk: worldChunk, atmospherePresets: atmospherePresets)
        let characterSlugs = scene.characterIDs.compactMap { id in
            store.characters.first(where: { $0.id == id })?.assetFolderSlug
        }
        return SceneProductionInput(
            sceneName: scene.name,
            sceneID: scene.id,
            lyrics: lyrics,
            directions: parseResult?.directions ?? [],
            shots: scene.shots,
            characterSlugs: characterSlugs,
            characterCast: characterCast,
            objectSetups: scene.objectSetups,
            backgroundName: backgroundName,
            worldChunk: worldChunk,
            styleProfile: styleProfile,
            cameraPresets: cameraPresets.presets,
            availableCameraPresetCount: cameraPresets.presets.count,
            lightRig: lightRig,
            atmospherePreset: atmospherePreset,
            baseFPS: max(store.fps, 1),
            totalBeats: totalBeats,
            bpm: bpm
        )
    }

    func makeStatus(
        for plan: SceneProductionPlan,
        scene: AnimationScene,
        store: AnimateStore,
        renderer: ScenePreviewRenderer
    ) -> Animate3DProductionStatus {
        let registryBundleService = Animate3DRegistryBundleService(store: store)
        let preferredCostumeBySlug = Dictionary(
            uniqueKeysWithValues: plan.characterBlocking.map { ($0.characterSlug, $0.preferredCostumeName) }
        )
        let sceneCharacters = scene.characterIDs.compactMap { id in
            store.characters.first(where: { $0.id == id })
        }
        let modelBackedCount = sceneCharacters.filter { character in
            let inventory = Animate3DCharacterAssetService().inventory(for: character.assetFolderSlug, in: store.animateURL)
            let preferredCostume = preferredCostumeBySlug[character.assetFolderSlug] ?? nil
            return !inventory.files(for: .models).isEmpty
                || character.models3D.contains(where: {
                    preferredCostume == nil || $0.costumeName.caseInsensitiveCompare(preferredCostume ?? "") == .orderedSame
                })
                || registryBundleService.provides(.models, for: character.assetFolderSlug, costumeName: preferredCostume)
        }.count
        let profileCount = plan.characterBlocking.filter { blocking in
            renderer.assetProfileExists(slug: blocking.characterSlug, costumeName: blocking.preferredCostumeName)
        }.count
        let assetService = Animate3DCharacterAssetService()
        let bundleReadiness: [Animate3DCharacterBundleReadinessStatus] = sceneCharacters.map { character in
            let inventory = assetService.inventory(for: character.assetFolderSlug, in: store.animateURL)
            let preferredCostume = preferredCostumeBySlug[character.assetFolderSlug] ?? nil
            let resolvedBundleInfo = registryBundleService.resolvedBundleInfo(
                for: character.assetFolderSlug,
                costumeName: preferredCostume
            )
            let categories = Animate3DCharacterAssetCategory.allCases
            let readyCategories = categories.filter { category in
                !inventory.files(for: category).isEmpty
                    || (category == .models && character.models3D.contains(where: {
                        preferredCostume == nil || $0.costumeName.caseInsensitiveCompare(preferredCostume ?? "") == .orderedSame
                    }))
                    || registryBundleService.provides(category, for: character.assetFolderSlug, costumeName: preferredCostume)
            }
            let registryBackedCategories = categories.filter { category in
                inventory.files(for: category).isEmpty
                    && !(category == .models && character.models3D.contains(where: {
                        preferredCostume == nil || $0.costumeName.caseInsensitiveCompare(preferredCostume ?? "") == .orderedSame
                    }))
                    && registryBundleService.provides(category, for: character.assetFolderSlug, costumeName: preferredCostume)
            }
            let missingCategories = categories.filter { !readyCategories.contains($0) }
            return Animate3DCharacterBundleReadinessStatus(
                characterName: character.name,
                characterSlug: character.assetFolderSlug,
                preferredCostumeName: preferredCostume,
                resolvedBundleCostumeName: resolvedBundleInfo?.descriptor.costumeName,
                resolvedBundleSourcePath: resolvedBundleInfo?.sourceManifestPath,
                resolvedBundleAssetPaths: resolvedBundleInfo?.resolvedAssetPaths ?? [],
                readyCategories: readyCategories,
                registryBackedCategories: registryBackedCategories,
                missingCategories: missingCategories,
                totalFileCount: inventory.totalFileCount
            )
        }
        let generationQueueItems = Animate3DGenerationQueuePlanner(store: store).buildPlan(
            scene: scene,
            backgroundName: plan.backgroundName,
            worldChunk: plan.worldChunk,
            styleProfile: plan.styleProfile,
            lightRig: plan.lightRig,
            atmospherePreset: plan.atmospherePreset,
            bundleReadiness: bundleReadiness
        )

        var warnings: [String] = []
        if modelBackedCount < sceneCharacters.count {
            warnings.append("\(sceneCharacters.count - modelBackedCount) character(s) still rely on placeholder body models.")
        }
        if profileCount < sceneCharacters.count {
            warnings.append("\(sceneCharacters.count - profileCount) character(s) are missing 3D face/mouth performance profiles.")
        }
        if plan.objectPlacements.isEmpty {
            warnings.append("No prop placements compiled yet; object blocking is still sparse.")
        }
        let missingBundleCount = bundleReadiness.filter { !$0.isReady }.count
        if missingBundleCount > 0 {
            warnings.append("\(missingBundleCount) character bundle(s) are still missing 3D sidecars required for one-shot preview.")
        }
        if !generationQueueItems.isEmpty {
            warnings.append("\(generationQueueItems.count) queued 3D asset/world deliverable(s) still need to be generated or assigned.")
        }

        return Animate3DProductionStatus(
            planLoaded: true,
            rendererModeTitle: "Production Engine",
            sceneName: plan.sceneName,
            backgroundName: plan.backgroundName,
            worldChunkTitle: plan.worldChunk?.title.nilIfEmpty ?? plan.worldChunk.map { "\($0.worldID) / \($0.zoneID)" },
            styleProfileTitle: plan.styleProfile?.title,
            lightRigTitle: plan.lightRig?.title,
            atmospherePresetTitle: plan.atmospherePreset?.title,
            cameraPresetCount: plan.availableCameraPresetCount,
            baseFPS: plan.baseFPS,
            totalFrames: plan.totalFrames,
            characterCount: plan.characterBlocking.count,
            propCount: plan.objectPlacements.count,
            modelBackedCharacterCount: modelBackedCount,
            performanceProfileCount: profileCount,
            runtimeCharacters: renderer.characterPerformanceStatuses,
            bundleReadiness: bundleReadiness,
            generationQueueItems: generationQueueItems,
            warnings: warnings
        )
    }

    func resolveWorldChunk(
        worldCatalog: Animate3DWorldCatalog,
        backgroundName: String?,
        sceneName: String
    ) -> Animate3DWorldChunkDescriptor? {
        let candidates = [backgroundName, sceneName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return worldCatalog.chunks.first { chunk in
            chunk.placeNames.contains { placeName in
                candidates.contains { $0.caseInsensitiveCompare(placeName) == .orderedSame }
            } || candidates.contains {
                chunk.title.caseInsensitiveCompare($0) == .orderedSame
            }
        }
    }

    func resolveLightRig(
        worldChunk: Animate3DWorldChunkDescriptor?,
        lightRigs: Animate3DLightRigManifest
    ) -> Animate3DLightRigDescriptor? {
        if let lightRigID = worldChunk?.lightRigID,
           let matched = lightRigs.rigs.first(where: { $0.rigID.caseInsensitiveCompare(lightRigID) == .orderedSame }) {
            return matched
        }
        return lightRigs.rigs.first
    }

    func resolveAtmospherePreset(
        worldChunk: Animate3DWorldChunkDescriptor?,
        atmospherePresets: Animate3DAtmospherePresetManifest
    ) -> Animate3DAtmospherePresetDescriptor? {
        if let atmospherePresetID = worldChunk?.atmospherePresetID,
           let matched = atmospherePresets.presets.first(where: { $0.presetID.caseInsensitiveCompare(atmospherePresetID) == .orderedSame }) {
            return matched
        }
        return atmospherePresets.presets.first
    }

    func resolveStyleProfile(
        worldChunk: Animate3DWorldChunkDescriptor?,
        styleProfiles: Animate3DStyleProfileManifest
    ) -> Animate3DStyleProfileDescriptor? {
        if let styleProfileID = worldChunk?.styleProfileID,
           let matched = styleProfiles.profiles.first(where: { $0.profileID.caseInsensitiveCompare(styleProfileID) == .orderedSame }) {
            return matched
        }
        return styleProfiles.profiles.first
    }

    func registrySignature(projectURL: URL) -> String {
        let assetBundles = ProjectDatabaseBridge.loadAnimate3DAssetRegistryFromDisk(projectURL: projectURL)?.bundles.map {
            "\($0.characterSlug)|\($0.costumeName)|\($0.bodyModelPath)|\($0.faceRigPath ?? "nil")|\($0.mouthProfilePath ?? "nil")|\($0.expressionLibraryPath ?? "nil")|\($0.motionSetPaths.joined(separator: ","))|\($0.materialProfilePath ?? "nil")"
        }.joined(separator: ";") ?? "assets:nil"
        let characterBundles = ProjectDatabaseBridge.loadAnimate3DCharacterRegistryFromDisk(projectURL: projectURL)?.bundles.map {
            "\($0.characterSlug)|\($0.costumeName)|\($0.bodyModelPath)|\($0.faceRigPath ?? "nil")|\($0.mouthProfilePath ?? "nil")|\($0.expressionLibraryPath ?? "nil")|\($0.motionSetPaths.joined(separator: ","))|\($0.materialProfilePath ?? "nil")"
        }.joined(separator: ";") ?? "chars:nil"
        let motions = ProjectDatabaseBridge.loadAnimate3DMotionRegistryFromDisk(projectURL: projectURL)?.motions.map {
            "\($0.motionID)|\($0.relativePath)|\($0.tags.joined(separator: ","))"
        }.joined(separator: ";") ?? "motions:nil"
        let world = ProjectDatabaseBridge.loadAnimate3DWorldCatalogFromDisk(projectURL: projectURL)?.chunks.map {
            "\($0.worldID)|\($0.zoneID)|\($0.title)|\($0.previewImagePath ?? "nil")|\($0.styleProfileID ?? "nil")|\($0.lightRigID ?? "nil")|\($0.atmospherePresetID ?? "nil")"
        }.joined(separator: ";") ?? "world:nil"
        let styles = ProjectDatabaseBridge.loadAnimate3DStyleProfilesFromDisk(projectURL: projectURL)?.profiles.map {
            "\($0.profileID)|\($0.title)|\($0.celBands)|\($0.outlineWidth)"
        }.joined(separator: ";") ?? "styles:nil"
        let cameras = ProjectDatabaseBridge.loadAnimate3DCameraPresetsFromDisk(projectURL: projectURL)?.presets.map {
            "\($0.presetID)|\($0.shotName)|\($0.focalLength)"
        }.joined(separator: ";") ?? "cams:nil"
        let lights = ProjectDatabaseBridge.loadAnimate3DLightRigsFromDisk(projectURL: projectURL)?.rigs.map {
            "\($0.rigID)|\($0.keyIntensity)|\($0.fillIntensity)|\($0.rimIntensity)"
        }.joined(separator: ";") ?? "lights:nil"
        let atmosphere = ProjectDatabaseBridge.loadAnimate3DAtmospherePresetsFromDisk(projectURL: projectURL)?.presets.map {
            "\($0.presetID)|\($0.fogDensity)|\($0.haze)|\($0.colorHex)"
        }.joined(separator: ";") ?? "atmo:nil"
        return [assetBundles, characterBundles, motions, world, styles, cameras, lights, atmosphere].joined(separator: "#")
    }
}

@available(macOS 26.0, *)
private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
