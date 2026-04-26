import Foundation
import ProjectKit

@available(macOS 26.0, *)
struct ShotFrameGenerationDryRunFrame: Codable, Sendable, Identifiable {
    var id: UUID
    var sceneID: UUID
    var sceneName: String
    var shotID: UUID
    var shotIndex: Int
    var shotName: String
    var moment: ImagineShotMoment
    var mode: ShotFrameGenerationMode
    var canExecute: Bool
    var sourceImagePath: String?
    var automaticReferenceImagePaths: [String]
    var planReferenceImagePaths: [String]
    var reasonCodes: [ShotFrameStrategyReason]
    var promptCharacterCount: Int
    var estimatedVertexCostUSD: Double
    var generatedAspectRatio: String?
    var generatedImageSize: String?
    var extractionTargetAspectRatio: String?
    var finalDeliveryAspectRatio: String?
    var cropMotion: ShotFrameCropMotion?
    var cropRect: CropRect?
    var cropKeyframes: [ShotFrameCropKeyframe]

    init(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        shotIndex: Int,
        moment: ImagineShotMoment,
        plan: ShotFrameGenerationPlan,
        automaticReferenceImagePaths: [String],
        estimatedVertexCostUSD: Double
    ) {
        self.id = UUID()
        self.sceneID = scene.id
        self.sceneName = scene.name
        self.shotID = shot.id
        self.shotIndex = shotIndex
        self.shotName = shot.name
        self.moment = moment
        self.mode = plan.mode
        self.canExecute = plan.canExecute
        self.sourceImagePath = plan.sourceImage?.path
        self.automaticReferenceImagePaths = automaticReferenceImagePaths
        self.planReferenceImagePaths = plan.referenceImagePaths
        self.reasonCodes = plan.decision.reasons
        self.promptCharacterCount = plan.executionPrompt.count
        self.estimatedVertexCostUSD = estimatedVertexCostUSD
        self.generatedAspectRatio = plan.openMattePlan?.generatedAspectRatio
        self.generatedImageSize = plan.openMattePlan?.generatedImageSize
        self.extractionTargetAspectRatio = plan.openMattePlan?.extractionTargetAspectRatio
        self.finalDeliveryAspectRatio = plan.openMattePlan?.finalDeliveryAspectRatio
        self.cropMotion = plan.openMattePlan?.cropMotion
        self.cropRect = plan.openMattePlan?.cropRect
        self.cropKeyframes = plan.openMattePlan?.cropKeyframes ?? []
    }
}

@available(macOS 26.0, *)
struct ShotFrameGenerationDryRunSummary: Codable, Sendable {
    var totalFrames: Int
    var generateFrames: Int
    var editFrames: Int
    var executableFrames: Int
    var missingSourceFallbackFrames: Int
    var automaticReferenceCount: Int
    var openMatteFrames: Int
    var estimatedVertexCostUSD: Double

    init(frames: [ShotFrameGenerationDryRunFrame]) {
        self.totalFrames = frames.count
        self.generateFrames = frames.filter { $0.mode == .generate }.count
        self.editFrames = frames.filter { $0.mode == .edit }.count
        self.executableFrames = frames.filter(\.canExecute).count
        self.missingSourceFallbackFrames = frames.filter {
            $0.reasonCodes.contains(.sourceImageMissing)
        }.count
        self.automaticReferenceCount = frames.reduce(0) {
            $0 + $1.automaticReferenceImagePaths.count
        }
        self.openMatteFrames = frames.filter {
            $0.generatedAspectRatio != nil && $0.cropRect != nil
        }.count
        self.estimatedVertexCostUSD = frames.reduce(0) {
            $0 + $1.estimatedVertexCostUSD
        }
    }
}

@available(macOS 26.0, *)
struct ShotFrameGenerationDryRunReport: Codable, Sendable {
    var schemaVersion: Int
    var generatedAt: Date
    var model: GeminiModel
    var imageSize: String
    var sceneFilter: [UUID]?
    var frames: [ShotFrameGenerationDryRunFrame]
    var summary: ShotFrameGenerationDryRunSummary

    init(
        schemaVersion: Int = 2,
        generatedAt: Date = Date(),
        model: GeminiModel,
        imageSize: String,
        sceneFilter: [UUID]?,
        frames: [ShotFrameGenerationDryRunFrame]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.model = model
        self.imageSize = imageSize
        self.sceneFilter = sceneFilter
        self.frames = frames
        self.summary = ShotFrameGenerationDryRunSummary(frames: frames)
    }

    var totalFrames: Int { summary.totalFrames }
    var generateFrames: Int { summary.generateFrames }
    var editFrames: Int { summary.editFrames }
    var executableFrames: Int { summary.executableFrames }
    var missingSourceFallbackFrames: Int { summary.missingSourceFallbackFrames }
    var automaticReferenceCount: Int { summary.automaticReferenceCount }
    var openMatteFrames: Int { summary.openMatteFrames }
    var estimatedVertexCostUSD: Double { summary.estimatedVertexCostUSD }
}

@available(macOS 26.0, *)
@MainActor
struct ShotFrameGenerationDryRunPlanner {
    var store: AnimateStore

    func buildReport(
        scenes: [AnimationScene],
        projectRoot: URL,
        sceneFilter: Set<UUID>? = nil,
        model: GeminiModel,
        imageSize: String = ShotFrameOpenMattePlan.defaultGeneratedImageSize
    ) async -> ShotFrameGenerationDryRunReport {
        let promptService = ImagineScenePromptService(store: store)
        let scenesToPlan = scenes.filter { scene in
            sceneFilter?.contains(scene.id) ?? true
        }
        var frames: [ShotFrameGenerationDryRunFrame] = []

        for scene in scenesToPlan {
            for (shotIndex, shot) in scene.shots.enumerated() {
                for moment in ImagineShotMoment.allCases {
                    let storedPrompt = store.imaginePrompt(
                        for: scene.id,
                        shotIndex: shotIndex,
                        moment: moment
                    )
                    let prompt = storedPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        ? promptService.prefillPrompt(
                            scene: scene,
                            shotIndex: shotIndex,
                            moment: moment,
                            subjectStyle: .neutralSubjects
                        )
                        : storedPrompt

                    let automaticReferences = await automaticReferencePaths(
                        scene: scene,
                        shotIndex: shotIndex,
                        moment: moment,
                        prompt: prompt
                    )
                    let plan = ShotFrameGenerationPlanResolver.resolve(
                        input: ShotFrameGenerationPlanResolver.Input(
                            projectRoot: projectRoot,
                            sceneID: scene.id,
                            shotID: shot.id,
                            shotIndex: shotIndex,
                            moment: moment,
                            prompt: prompt,
                            gallery: store.imagineGallery(for: scene.id, shotIndex: shotIndex),
                            previousShotGallery: shotIndex > 0
                                ? store.imagineGallery(for: scene.id, shotIndex: shotIndex - 1)
                                : nil,
                            automaticReferenceImagePaths: automaticReferences,
                            manualReferenceCount: 0,
                            cameraShot: resolvedCameraShot(for: scene, shot: shot),
                            cameraMovement: resolvedCameraMovement(for: shot),
                            generatedImageSize: imageSize
                        )
                    )
                    let planImageSize = plan.openMattePlan?.generatedImageSize ?? imageSize
                    frames.append(
                        ShotFrameGenerationDryRunFrame(
                            scene: scene,
                            shot: shot,
                            shotIndex: shotIndex,
                            moment: moment,
                            plan: plan,
                            automaticReferenceImagePaths: automaticReferences,
                            estimatedVertexCostUSD: model.estimatedCost(for: planImageSize)
                        )
                    )
                    if frames.count.isMultiple(of: 6) {
                        await Task.yield()
                    }
                }
            }
        }

        return ShotFrameGenerationDryRunReport(
            model: model,
            imageSize: imageSize,
            sceneFilter: sceneFilter.map { Array($0).sorted { $0.uuidString < $1.uuidString } },
            frames: frames
        )
    }

    func writeReport(_ report: ShotFrameGenerationDryRunReport, projectRoot: URL) throws -> URL {
        try Self.writeReportSync(report, projectRoot: projectRoot)
    }

    nonisolated func writeReportAsync(
        _ report: ShotFrameGenerationDryRunReport,
        projectRoot: URL
    ) async throws -> URL {
        try await Task.detached(priority: .utility) {
            try Self.writeReportSync(report, projectRoot: projectRoot)
        }.value
    }

    nonisolated private static func writeReportSync(
        _ report: ShotFrameGenerationDryRunReport,
        projectRoot: URL
    ) throws -> URL {
        let directory = ProjectPaths(root: projectRoot)
            .animate
            .appendingPathComponent("Imagine/DryRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("shot-frame-generation-latest.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(report).write(to: url, options: .atomic)
        return url
    }

    private func automaticReferencePaths(
        scene: AnimationScene,
        shotIndex: Int,
        moment: ImagineShotMoment,
        prompt: String
    ) async -> [String] {
        guard shotIndex >= 0,
              shotIndex < scene.shots.count,
              let searchService = store.imageIntelligenceSearchService() else {
            return []
        }

        let shot = scene.shots[shotIndex]
        let input = ImageSearchService.SelectorInput(
            sceneID: scene.id.uuidString,
            shotID: shot.id.uuidString,
            moment: moment.directoryName,
            characterIDs: resolvedCharacterIDs(for: scene, shot: shot),
            placeID: scene.backgroundID?.uuidString,
            queryText: referenceQueryText(scene: scene, shot: shot, prompt: prompt)
        )

        do {
            let selections = try await searchService.selectForShot(input: input, maxImages: 5)
            var seen = Set<String>()
            return selections.compactMap { selection in
                let path = URL(fileURLWithPath: selection.resolvedPath).standardizedFileURL.path
                guard FileManager.default.fileExists(atPath: path),
                      seen.insert(path).inserted else { return nil }
                return path
            }
        } catch {
            return []
        }
    }

    private func resolvedCharacterIDs(
        for scene: AnimationScene,
        shot: AnimationSceneShot
    ) -> [String] {
        var ids = scene.characterIDs
        if let focusCharacterID = scene.directionTemplate?.focusCharacterID {
            ids.append(focusCharacterID)
        }
        if let focusCharacterID = shot.focusCharacterID {
            ids.append(focusCharacterID)
        }

        let slugs = (
            scene.characterSlugs +
            [scene.directionTemplate?.focusCharacterSlug, shot.focusCharacterSlug].compactMap { $0 }
        )
        for slug in slugs {
            if let character = store.characters.first(where: { character in
                character.owpSlug == slug || character.storageSlug == slug
            }) {
                ids.append(character.id)
            }
        }

        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }.map(\.uuidString)
    }

    private func referenceQueryText(
        scene: AnimationScene,
        shot: AnimationSceneShot,
        prompt: String
    ) -> String {
        [
            scene.name,
            scene.directionTemplate?.notes,
            shot.name,
            shot.notes,
            shot.sourceLyricExcerpt,
            prompt
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n")
    }

    private func resolvedCameraShot(
        for scene: AnimationScene,
        shot: AnimationSceneShot
    ) -> CameraShot {
        shot.cameraShot
            ?? scene.directionTemplate?.defaultCameraShot
            ?? shot.shotIntent?.recommendedCameraShot
            ?? .medium
    }

    private func resolvedCameraMovement(for shot: AnimationSceneShot) -> CameraMovement? {
        shot.shotIntent?.recommendedCameraMovement
    }
}
