import Observation
import SwiftUI
import ProjectKit

@available(macOS 26.0, *)
@MainActor
public final class AnimateWorkspaceController: ObservableObject {
    let store = AnimateStore()
    let allProjectImagesState = AllProjectImagesState()
    let canvasLibraryState: AllProjectImagesState = {
        let state = AllProjectImagesState()
        state.thumbnailSize = 84
        return state
    }()
    let canvasFormState = CanvasFormState()
    private var loadedProjectPath: String?
    private var loadRequestID: UInt64 = 0
    /// Most recent project URL the host has selected. Written from Opera's
    /// shell on every project switch so the loopback API can activate the
    /// correct project when an external request arrives before any UI mode
    /// has triggered lazy loading.
    private var apiHostProjectURL: URL?
    @Published public private(set) var isLoadingProject = false
    @Published public private(set) var loadStatusMessage = "Ready"
    @Published public private(set) var saveIndicator: SaveIndicatorState = .idle
    @Published public private(set) var activeProjectPath: String?
    @Published public private(set) var selectedScenePath: String?
    @Published public private(set) var isSelectionRestorePending = false

    public init(startServers: Bool = true) {
        store.disableExternalFileWatch = true
        _ = RunPodMouthSyncService.shared
        RunPodMouthSyncService.shared.setActiveAnimateURL(store.animateURL)
        activeProjectPath = store.owpURL?.standardizedFileURL.path
        selectedScenePath = currentSelectionPath()
        saveIndicator = store.saveIndicator
        observeSaveIndicator()
        observeSelectionPath()
        if startServers {
            // Loopback HTTP API for external agents (curated Places generation, etc.).
            // Idempotent; safe if the shell re-inits or AnimateApp runs standalone.
            AnimateAPIServer.startIfNeeded(store: store)
            // Let the API hydrate the active project on demand, bypassing Opera's
            // lazy mode-switch gate. `apiHostProjectURL` is refreshed from the shell.
            AnimateAPIServer.projectActivator = { [weak self] in
                guard let self else { return }
                guard let url = self.apiHostProjectURL else { return }
                _ = await self.ensureProjectLoaded(url)
            }
            // LAN HTTP server for the iPad storyboard drawing tool (port 19850).
            StoryboardAPIServer.startIfNeeded(workspace: self)
        }
    }

    /// Called by the Opera shell whenever the active project URL changes so
    /// the loopback API can hydrate the correct project without waiting for a
    /// UI mode switch into Places/Animate.
    public func setAPIHostProjectURL(_ url: URL?) {
        apiHostProjectURL = url
    }

    public var isDirty: Bool { store.saveIndicator == .unsavedChanges }

    /// Whether any RunPod-backed Animate workflow currently has an active pod.
    public var isRunPodActive: Bool {
        RunPodMouthSyncService.shared.podStatus.isActive
    }

    /// Manual emergency stop for all active RunPod-backed Animate jobs.
    public func terminateRunPodPods() {
        RunPodMouthSyncService.shared.terminateAllPods()
    }

    /// Diagnostic: run a codex CLI test to verify the prompt service works.
    /// Returns the prompt string on success, throws on failure.
    public static func runCodexDiagnostic() async throws -> String {
        try await ImagineScenePromptService.runDiagnosticTest()
    }

    public func suspendBackgroundWork() {
        store.suspendBackgroundWork()
    }

    public func resumeBackgroundWork() {
        store.resumeBackgroundWork()
    }

    public func isProjectDisplayReady(_ projectURL: URL) -> Bool {
        let normalizedPath = projectURL.standardizedFileURL.path
        return loadedProjectPath == normalizedPath
            && store.owpURL?.standardizedFileURL.path == normalizedPath
            && !store.isLoadingProject
            && !isLoadingProject
            && store.loadErrorMessage == nil
    }

    public func save() {
        store.save()
    }

    /// Returns the title-bar AI generation activity badge bound to this workspace's store.
    /// Exposed here so the top-level Opera shell can host it without needing
    /// direct access to the internal AnimateStore type.
    public func aiGenerationStatusBadgeView() -> some View {
        GeminiStatusBadge(store: store)
    }

    /// Returns the global-settings gear button bound to this workspace's store.
    public func globalSettingsGearView() -> some View {
        GlobalSettingsGear(store: store)
    }

    /// Returns the storyboard URL button for the title bar.
    public func storyboardURLButtonView() -> some View {
        StoryboardURLButton()
    }

    /// Returns the compact storyboard/iPad server status pill for Opera's title bar.
    public func storyboardServerStatusIndicatorView() -> some View {
        StoryboardServerIndicatorView()
    }

    // Note: AllProjectImages is now dispatched from `OperaShellView` as a
    // first-class `AllProjectImagesWorkspace(controller: animateController)`,
    // matching every other workspace (Characters, Places, …). The old
    // `allProjectImagesPageView()` helper was removed because it returned a
    // raw page without the shared sidebar/inspector chrome.

    public func setSelectionRestorePending(_ isPending: Bool) {
        isSelectionRestorePending = isPending
    }

    @discardableResult
    public func applySelectionPath(_ relativePath: String?) -> Bool {
        guard let relativePath,
              let scene = store.scenes.first(where: { $0.owpSongPath == relativePath }) else {
            return false
        }
        if store.selectedSceneID != scene.id {
            store.selectedSceneID = scene.id
        }
        return true
    }

    public func ensureProjectLoaded(_ projectURL: URL) async -> String? {
        let normalizedURL = projectURL.standardizedFileURL
        let normalizedPath = normalizedURL.path
        loadRequestID &+= 1
        let requestID = loadRequestID
        if loadedProjectPath == normalizedPath,
           store.owpURL?.standardizedFileURL.path == normalizedPath,
           !store.isLoadingProject,
           store.loadErrorMessage == nil {
            activeProjectPath = normalizedPath
            RunPodMouthSyncService.shared.setActiveAnimateURL(store.animateURL)
            store.resumeBackgroundWork()
            allProjectImagesState.requestRebuildIfNeeded(store: store)
            return nil
        }

        isLoadingProject = true
        loadStatusMessage = "Loading Animate workspace from disk…"
        defer {
            if requestID == loadRequestID {
                isLoadingProject = false
            }
        }

        if store.isLoadingProject,
           store.owpURL?.standardizedFileURL.path != normalizedPath {
            while store.isLoadingProject {
                guard requestID == loadRequestID else { return nil }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }

        await Task.yield()
        guard requestID == loadRequestID else { return nil }
        await store.openOWP(url: normalizedURL)
        while store.isLoadingProject {
            guard requestID == loadRequestID else { return nil }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard requestID == loadRequestID else { return nil }
        loadStatusMessage = store.statusMessage

        if store.owpURL?.standardizedFileURL.path == normalizedPath,
           !store.isLoadingProject,
           store.loadErrorMessage == nil {
            loadedProjectPath = normalizedPath
            activeProjectPath = normalizedPath
            RunPodMouthSyncService.shared.setActiveAnimateURL(store.animateURL)
            allProjectImagesState.requestRebuildIfNeeded(store: store)
            return nil
        }

        let message = store.loadErrorMessage ?? store.statusMessage
        loadedProjectPath = store.owpURL?.standardizedFileURL.path
        activeProjectPath = store.owpURL?.standardizedFileURL.path

        return message
    }

    public func currentSelectionPath() -> String? {
        store.selectedScene?.owpSongPath
    }

    public func setDefaultAudioPath(_ path: String?, for sceneID: UUID) {
        store.setDefaultAudioPath(path, for: sceneID)
    }

    public func songPath(for sceneID: UUID) -> String? {
        store.scenes.first(where: { $0.id == sceneID })?.owpSongPath
    }

    /// Lightweight CLI/debug snapshot of the currently loaded characters.
    /// Kept intentionally string-based so diagnostics can use it without
    /// exposing internal AnimateUI model types across module boundaries.
    public func debugCharacterRows() -> [(name: String, owpSlug: String, storageSlug: String)] {
        store.characters.map { character in
            (
                name: character.name,
                owpSlug: character.owpSlug,
                storageSlug: character.assetFolderSlug
            )
        }
    }

    /// CLI/debug entrypoint for the Imagine beginning/middle/end dry-run planner.
    /// Stringly typed so the standalone Animate executable can call it without
    /// exposing internal AnimateUI planning models as public API.
    public func runShotFrameGenerationDryRun(
        sceneFilter: String?,
        modelName: String?,
        imageSize: String?
    ) async throws -> [String: String] {
        guard let projectRoot = store.fileOWPURL else {
            throw cliError("No project is loaded.")
        }

        let model = resolvedGeminiModel(from: modelName)
        let shotSettings = ShotGenerationSettingsStore.load(projectRoot: projectRoot)
        let resolvedImageSize = imageSize?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? imageSize!.trimmingCharacters(in: .whitespacesAndNewlines)
            : shotSettings.generatedImageSize
        let sceneFilterSet = try resolvedSceneFilter(sceneFilter)
        let planner = ShotFrameGenerationDryRunPlanner(store: store)
        let report = await planner.buildReport(
            scenes: store.scenes,
            projectRoot: projectRoot,
            sceneFilter: sceneFilterSet,
            model: model,
            imageSize: resolvedImageSize
        )
        let reportURL = try await planner.writeReportAsync(report, projectRoot: projectRoot)
        return [
            "reportURL": reportURL.path,
            "totalFrames": "\(report.totalFrames)",
            "generateFrames": "\(report.generateFrames)",
            "editFrames": "\(report.editFrames)",
            "openMatteFrames": "\(report.openMatteFrames)",
            "automaticReferenceCount": "\(report.automaticReferenceCount)",
            "estimatedVertexCostUSD": String(format: "%.4f", report.estimatedVertexCostUSD),
            "model": report.model.rawValue,
            "imageSize": report.imageSize
        ]
    }

    /// CLI/debug entrypoint that mirrors the API's `/automation/frame-plans/dry-run`
    /// endpoint, writing the exact effective specs, reference contracts, and
    /// beginning/middle/end frame plans to disk.
    public func runAutomationFramePlansDryRun(
        sceneFilter: String?,
        shotID: String?,
        modelName: String?,
        imageSize: String?,
        maxCostUSD: Double?,
        writeSidecars: Bool
    ) async throws -> [String: String] {
        guard let projectRoot = store.fileOWPURL else {
            throw cliError("No project is loaded.")
        }

        let model = resolvedGeminiModel(from: modelName)
        let shotSettings = ShotGenerationSettingsStore.load(projectRoot: projectRoot)
        let resolvedImageSize = imageSize?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? imageSize!.trimmingCharacters(in: .whitespacesAndNewlines)
            : shotSettings.generatedImageSize
        let sceneFilterSet = try resolvedSceneFilter(sceneFilter)
        let shotFilter: UUID? = {
            guard let raw = shotID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return nil
            }
            return UUID(uuidString: raw)
        }()
        if shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, shotFilter == nil {
            throw cliError("Invalid shot ID '\(shotID ?? "")'.")
        }

        let summary = AutomationSourceResolver.projectSummary(store: store, projectRoot: projectRoot)
        let specBuilder = EffectiveShotSpecBuilder(store: store)
        let referenceResolver = ReferenceContractResolver(store: store)
        let planBuilder = ShotFramePlanBuilder(store: store)
        var results: [AutomationDryRunShotResult] = []
        var allBlockers: [AutomationBlocker] = []

        for scene in store.scenes where sceneFilterSet?.contains(scene.id) ?? true {
            for index in scene.shots.indices {
                let shot = scene.shots[index]
                if let shotFilter, shot.id != shotFilter { continue }
                let spec = specBuilder.build(scene: scene, shotIndex: index, projectRoot: projectRoot)
                let specURL = writeSidecars ? try specBuilder.write(spec, projectRoot: projectRoot) : nil
                let resolved = try referenceResolver.resolve(spec: spec, projectRoot: projectRoot, write: writeSidecars)
                let planSet = planBuilder.buildPlans(spec: spec, contract: resolved.contract, projectRoot: projectRoot, imageSize: resolvedImageSize)
                let planURL = writeSidecars ? try planBuilder.write(planSet, projectRoot: projectRoot) : nil
                let shotCost = planSet.plans.reduce(0) { subtotal, plan in
                    subtotal + model.estimatedCost(for: plan.openMattePlan?.generatedImageSize ?? resolvedImageSize)
                }
                let blockers = spec.blockers + resolved.contract.blockers + planSet.plans.compactMap { plan -> AutomationBlocker? in
                    plan.canExecute ? nil : .init(
                        code: .blockedMissingEditSource,
                        message: "\(plan.moment.rawValue) plan requires an edit source image that is not readable.",
                        field: "shotFrameGenerationPlan.\(plan.moment.rawValue)"
                    )
                }
                allBlockers.append(contentsOf: blockers)
                results.append(
                    AutomationDryRunShotResult(
                        effectiveShotSpec: spec,
                        effectiveShotSpecPath: specURL?.path,
                        referenceContract: resolved.contract,
                        referenceContractPath: resolved.url?.path,
                        shotFrameGenerationPlanSet: planSet,
                        shotFrameGenerationPlanPath: planURL?.path,
                        estimatedVertexCostUSD: shotCost,
                        blockers: blockers
                    )
                )
                await Task.yield()
            }
        }

        let totalCost = results.reduce(0) { $0 + $1.estimatedVertexCostUSD }
        if let maxCostUSD, totalCost > maxCostUSD {
            allBlockers.append(
                .init(
                    code: .blockedCostCap,
                    message: "Estimated Vertex cost $\(String(format: "%.4f", totalCost)) exceeds cap $\(String(format: "%.2f", maxCostUSD)).",
                    field: "maxCostUSD"
                )
            )
        }

        let report = AutomationDryRunReport(
            model: model.rawValue,
            imageSize: resolvedImageSize,
            projectSummary: summary,
            shots: results,
            estimatedVertexCostUSD: totalCost,
            blockers: allBlockers
        )
        let directory = AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "shot-frame-plans")
            .appendingPathComponent("DryRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let reportURL = directory.appendingPathComponent("automation-frame-plans-latest.json")
        try writeCodable(report, to: reportURL)
        try writeShotReferenceTodoList(report: report, projectRoot: projectRoot)

        let totalFrames = results.reduce(0) { $0 + $1.shotFrameGenerationPlanSet.plans.count }
        return [
            "reportURL": reportURL.path,
            "totalShots": "\(results.count)",
            "totalFrames": "\(totalFrames)",
            "estimatedVertexCostUSD": String(format: "%.4f", totalCost),
            "model": model.rawValue,
            "imageSize": resolvedImageSize,
            "blockerCount": "\(allBlockers.count)"
        ]
    }

    /// CLI/debug entrypoint for `/automation/frames/generate`, with optional
    /// force-Vertex execution scoped to this run.
    public func runAutomationFramesGenerate(
        sceneFilter: String?,
        shotID: String?,
        momentsRaw: String?,
        modelName: String?,
        imageSize: String?,
        mode: String,
        maxCostUSD: Double?,
        maxFrames: Int?,
        forceVertex: Bool,
        vertexProjectID providedProjectID: String?,
        vertexRegion providedRegion: String?
    ) async throws -> [String: String] {
        guard let projectRoot = store.fileOWPURL else {
            throw cliError("No project is loaded.")
        }

        let normalizedMode = mode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedMode == "preflight" || normalizedMode == "execute" else {
            throw cliError("Invalid mode: \(mode). Use preflight or execute.")
        }

        let model = resolvedGeminiModel(from: modelName)
        let shotSettings = ShotGenerationSettingsStore.load(projectRoot: projectRoot)
        let resolvedImageSize = imageSize?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? imageSize!.trimmingCharacters(in: .whitespacesAndNewlines)
            : shotSettings.generatedImageSize
        let sceneFilterSet = try resolvedSceneFilter(sceneFilter)
        let shotFilter: UUID? = {
            guard let raw = shotID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty else {
                return nil
            }
            return UUID(uuidString: raw)
        }()
        if shotID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false, shotFilter == nil {
            throw cliError("Invalid shot ID '\(shotID ?? "")'.")
        }

        let moments = try resolvedMoments(momentsRaw)

        var previousBackend: ImageGenBackend?
        var previousVertexSettings: VertexSettings?
        if forceVertex || (providedProjectID?.isEmpty == false) || (providedRegion?.isEmpty == false) {
            let projectID = firstNonEmpty(
                providedProjectID,
                ProjectCredentialStore.shared.vertexProjectID(),
                ImageGenBackendStore.currentVertexSettings().projectID
            )
            let region = firstNonEmpty(
                providedRegion,
                ProjectCredentialStore.shared.vertexRegion(),
                ImageGenBackendStore.currentVertexSettings().region,
                "global"
            )
            guard let projectID, !projectID.isEmpty else {
                throw cliError("Missing Vertex project ID. Set it in API Settings or pass --vertex-project <id>.")
            }
            previousBackend = ImageGenBackendStore.currentBackend()
            previousVertexSettings = ImageGenBackendStore.currentVertexSettings()
            ImageGenBackendStore.setBackend(.vertex)
            ImageGenBackendStore.setVertexSettings(VertexSettings(projectID: projectID, region: region ?? "global"))
        }
        defer {
            if let previousBackend, let previousVertexSettings {
                ImageGenBackendStore.setBackend(previousBackend)
                ImageGenBackendStore.setVertexSettings(previousVertexSettings)
            }
        }

        let response = await AutomationFrameGenerationService(store: store).run(
            projectRoot: projectRoot,
            sceneFilter: sceneFilterSet,
            shotFilter: shotFilter,
            moments: moments,
            model: model,
            imageSize: resolvedImageSize,
            mode: normalizedMode,
            maxCostUSD: maxCostUSD,
            maxFrames: maxFrames
        )

        let outputDirectory = AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "generated-frames")
            .appendingPathComponent("DryRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let reportURL = outputDirectory.appendingPathComponent("automation-frames-generate-latest.json")
        try writeCodable(response, to: reportURL)

        let completedCount = response.records.filter { $0.status == "completed" }.count
        let plannedCount = response.records.filter { $0.status == "planned" }.count
        let blockedCount = response.records.filter { $0.status == "blocked" }.count
        let failedCount = response.records.filter { $0.status.hasPrefix("failed") }.count
        return [
            "responseURL": reportURL.path,
            "ok": response.ok ? "true" : "false",
            "mode": response.mode,
            "isDryRun": response.isDryRun ? "true" : "false",
            "model": response.model,
            "imageSize": response.imageSize,
            "estimatedCostUSD": String(format: "%.4f", response.estimatedCostUSD),
            "maxCostUSD": response.maxCostUSD.map { String(format: "%.2f", $0) } ?? "",
            "recordCount": "\(response.records.count)",
            "completedCount": "\(completedCount)",
            "plannedCount": "\(plannedCount)",
            "blockedCount": "\(blockedCount)",
            "failedCount": "\(failedCount)",
            "blockerCount": "\(response.blockers.count)"
        ]
    }

    /// Small paid Vertex smoke-test hook for agent/operator use. It does not
    /// launch or control the GUI app; it only uses the same Gemini service and
    /// local Vertex attempt/credit ledger as the app.
    public func runVertexImageSmokeTest(
        projectID providedProjectID: String?,
        region providedRegion: String?,
        modelName: String?,
        imageSize: String?,
        aspectRatio: String?,
        maxSpendUSD: Double
    ) async throws -> [String: String] {
        guard let projectRoot = store.fileOWPURL else {
            throw cliError("No project is loaded.")
        }

        let model = resolvedGeminiModel(from: modelName)
        let resolvedImageSize = imageSize?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? imageSize!.trimmingCharacters(in: .whitespacesAndNewlines)
            : ShotFrameOpenMattePlan.defaultGeneratedImageSize
        let resolvedAspectRatio = aspectRatio?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            ? aspectRatio!.trimmingCharacters(in: .whitespacesAndNewlines)
            : ShotFrameOpenMattePlan.defaultGeneratedAspectRatio
        let estimatedCost = model.estimatedCost(for: resolvedImageSize)
        guard estimatedCost <= maxSpendUSD else {
            throw cliError("Estimated Vertex cost $\(String(format: "%.4f", estimatedCost)) exceeds cap $\(String(format: "%.2f", maxSpendUSD)).")
        }

        let projectID = firstNonEmpty(
            providedProjectID,
            ProjectCredentialStore.shared.vertexProjectID(),
            ImageGenBackendStore.currentVertexSettings().projectID
        )
        let region = firstNonEmpty(
            providedRegion,
            ProjectCredentialStore.shared.vertexRegion(),
            ImageGenBackendStore.currentVertexSettings().region,
            "global"
        )
        guard let projectID, !projectID.isEmpty else {
            throw cliError("Missing Vertex project ID. Set it in API Settings or pass --vertex-project <id>.")
        }

        let directory = ProjectPaths(root: projectRoot)
            .animate
            .appendingPathComponent("Imagine/VertexSmokeTests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let timestamp = Int(Date().timeIntervalSince1970)
        let stem = "vertex_smoke_\(timestamp)_\(model.rawValue)_\(resolvedImageSize)_\(resolvedAspectRatio.replacingOccurrences(of: ":", with: "x"))"
        var smokeRecord = VertexImageSmokeTestRecord(
            id: UUID(),
            startedAt: Date(),
            status: "running",
            model: model.rawValue,
            imageSize: resolvedImageSize,
            aspectRatio: resolvedAspectRatio,
            estimatedVertexCostUSD: estimatedCost,
            chargedEstimatedCostUSD: 0,
            maxSpendUSD: maxSpendUSD,
            projectID: projectID,
            region: region ?? "global"
        )
        try Self.writeVertexImageSmokeTestRecord(smokeRecord, directory: directory, stem: stem)

        let previousBackend = ImageGenBackendStore.currentBackend()
        let previousVertexSettings = ImageGenBackendStore.currentVertexSettings()
        ImageGenBackendStore.setBackend(.vertex)
        ImageGenBackendStore.setVertexSettings(VertexSettings(projectID: projectID, region: region ?? "global"))
        defer {
            ImageGenBackendStore.setBackend(previousBackend)
            ImageGenBackendStore.setVertexSettings(previousVertexSettings)
        }

        let prompt = [
            "Generate one safe open-matte pipeline smoke-test image.",
            "Subject: a cinematic alpine valley at sunrise with a river, distant mountains, and no people.",
            "Composition: \(resolvedAspectRatio) open-matte source plate, extra clean environment around all edges, no captions, no text, no logos.",
            "This is a technical validation frame for crop-controlled camera movement."
        ].joined(separator: " ")

        do {
            let result = try await GeminiImageService().generate(
                request: GeminiImageService.GenerationRequest(
                    prompt: prompt,
                    model: model,
                    aspectRatio: resolvedAspectRatio,
                    imageSize: resolvedImageSize
                ),
                apiKey: ""
            )

            let imageURL = directory.appendingPathComponent("\(stem).png")
            try result.imageData.write(to: imageURL, options: .atomic)
            let promptURL = directory.appendingPathComponent("\(stem).prompt.txt")
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)
            smokeRecord.promptURL = promptURL.path
            smokeRecord.imageURL = imageURL.path
            if let textResponse = result.textResponse,
               !textResponse.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let responseURL = directory.appendingPathComponent("\(stem).response.txt")
                try textResponse.write(to: responseURL, atomically: true, encoding: .utf8)
                smokeRecord.responseURL = responseURL.path
            }
            smokeRecord.status = "succeeded"
            smokeRecord.finishedAt = Date()
            smokeRecord.chargedEstimatedCostUSD = estimatedCost
            try Self.writeVertexImageSmokeTestRecord(smokeRecord, directory: directory, stem: stem)

            return [
                "imageURL": imageURL.path,
                "recordURL": directory.appendingPathComponent("\(stem).json").path,
                "latestRecordURL": directory.appendingPathComponent("vertex_smoke_latest.json").path,
                "estimatedVertexCostUSD": String(format: "%.4f", estimatedCost),
                "chargedEstimatedCostUSD": String(format: "%.4f", estimatedCost),
                "model": model.rawValue,
                "imageSize": resolvedImageSize,
                "aspectRatio": resolvedAspectRatio,
                "projectID": projectID,
                "region": region ?? "global"
            ]
        } catch {
            smokeRecord.status = "failed"
            smokeRecord.finishedAt = Date()
            smokeRecord.errorMessage = error.localizedDescription
            smokeRecord.chargedEstimatedCostUSD = 0
            try? Self.writeVertexImageSmokeTestRecord(smokeRecord, directory: directory, stem: stem)
            throw error
        }
    }

    /// Paid, single-image Vertex smoke test for the Image Intelligence
    /// recognition/tagging pipeline. This bypasses the persistent batch queue
    /// and analyzes exactly one existing image, then writes an auditable
    /// project-local record.
    public func runImageIntelligenceSmokeTest(
        imagePath providedImagePath: String?,
        projectID providedProjectID: String?,
        region providedRegion: String?,
        maxSpendUSD: Double
    ) async throws -> [String: String] {
        guard let projectRoot = store.fileOWPURL else {
            throw cliError("No project is loaded.")
        }

        let estimatedCost = 0.05
        guard estimatedCost <= maxSpendUSD else {
            throw cliError("Estimated Vertex cost $\(String(format: "%.4f", estimatedCost)) exceeds cap $\(String(format: "%.2f", maxSpendUSD)).")
        }

        let projectID = firstNonEmpty(
            providedProjectID,
            ProjectCredentialStore.shared.vertexProjectID(),
            ImageAnalysisBackendStore.currentVertexProjectID()
        )
        let region = firstNonEmpty(
            providedRegion,
            ProjectCredentialStore.shared.vertexRegion(),
            ImageAnalysisBackendStore.currentVertexRegion(),
            "global"
        )
        guard let projectID, !projectID.isEmpty else {
            throw cliError("Missing Vertex project ID. Set it in API Settings or pass --vertex-project <id>.")
        }

        let imagePath = try resolvedImageIntelligenceSmokeImage(
            providedImagePath,
            projectRoot: projectRoot
        )

        let directory = ProjectPaths(root: projectRoot)
            .animate
            .appendingPathComponent("ImageIntelligenceSmokeTests", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let timestamp = Int(Date().timeIntervalSince1970)
        let stem = "image_intelligence_smoke_\(timestamp)"
        var smokeRecord = ImageIntelligenceSmokeTestRecord(
            id: UUID(),
            startedAt: Date(),
            status: "running",
            imagePath: imagePath,
            estimatedVertexCostUSD: estimatedCost,
            chargedEstimatedCostUSD: 0,
            maxSpendUSD: maxSpendUSD,
            projectID: projectID,
            region: region ?? "global"
        )
        try Self.writeImageIntelligenceSmokeTestRecord(smokeRecord, directory: directory, stem: stem)

        let previousBackend = ImageAnalysisBackendStore.currentBackend()
        let previousProjectID = ImageAnalysisBackendStore.currentVertexProjectID()
        let previousRegion = ImageAnalysisBackendStore.currentVertexRegion()
        ImageAnalysisBackendStore.setBackend(.vertex)
        ImageAnalysisBackendStore.setVertexSettings(projectID: projectID, region: region ?? "global")
        defer {
            ImageAnalysisBackendStore.setBackend(previousBackend)
            ImageAnalysisBackendStore.setVertexSettings(projectID: previousProjectID, region: previousRegion)
            store.refreshImageAnalysisConfiguration()
        }

        do {
            try await waitForImageIntelligenceReady()
            let result = try await store.analyzeImageIntelligenceAssetNow(
                path: imagePath,
                linkKind: .canvasGeneration,
                reason: "vertex_smoke_test"
            )

            smokeRecord.status = "succeeded"
            smokeRecord.finishedAt = Date()
            smokeRecord.chargedEstimatedCostUSD = estimatedCost
            smokeRecord.result = result
            try Self.writeImageIntelligenceSmokeTestRecord(smokeRecord, directory: directory, stem: stem)

            var payload = result
            payload["recordURL"] = directory.appendingPathComponent("\(stem).json").path
            payload["latestRecordURL"] = directory.appendingPathComponent("image_intelligence_smoke_latest.json").path
            payload["estimatedVertexCostUSD"] = String(format: "%.4f", estimatedCost)
            payload["chargedEstimatedCostUSD"] = String(format: "%.4f", estimatedCost)
            payload["projectID"] = projectID
            payload["region"] = region ?? "global"
            return payload
        } catch {
            smokeRecord.status = "failed"
            smokeRecord.finishedAt = Date()
            smokeRecord.errorMessage = error.localizedDescription
            smokeRecord.chargedEstimatedCostUSD = 0
            try? Self.writeImageIntelligenceSmokeTestRecord(smokeRecord, directory: directory, stem: stem)
            throw error
        }
    }

    private struct VertexImageSmokeTestRecord: Codable, Sendable {
        var schemaVersion: Int = 1
        var id: UUID
        var startedAt: Date
        var finishedAt: Date?
        var status: String
        var model: String
        var imageSize: String
        var aspectRatio: String
        var estimatedVertexCostUSD: Double
        var chargedEstimatedCostUSD: Double
        var maxSpendUSD: Double
        var projectID: String
        var region: String
        var imageURL: String?
        var promptURL: String?
        var responseURL: String?
        var errorMessage: String?
    }

    private struct ImageIntelligenceSmokeTestRecord: Codable, Sendable {
        var schemaVersion: Int = 1
        var id: UUID
        var startedAt: Date
        var finishedAt: Date?
        var status: String
        var imagePath: String
        var estimatedVertexCostUSD: Double
        var chargedEstimatedCostUSD: Double
        var maxSpendUSD: Double
        var projectID: String
        var region: String
        var result: [String: String]?
        var errorMessage: String?
    }

    nonisolated private static func writeVertexImageSmokeTestRecord(
        _ record: VertexImageSmokeTestRecord,
        directory: URL,
        stem: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: directory.appendingPathComponent("\(stem).json"), options: .atomic)
        try data.write(to: directory.appendingPathComponent("vertex_smoke_latest.json"), options: .atomic)
    }

    nonisolated private static func writeImageIntelligenceSmokeTestRecord(
        _ record: ImageIntelligenceSmokeTestRecord,
        directory: URL,
        stem: String
    ) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        try data.write(to: directory.appendingPathComponent("\(stem).json"), options: .atomic)
        try data.write(to: directory.appendingPathComponent("image_intelligence_smoke_latest.json"), options: .atomic)
    }

    /// Explicitly reload Animate/scenes.json from disk, refreshing authored shot data.
    public func reloadScenesFromDisk() {
        store.reloadScenesFromDisk()
    }

    /// Returns all scenes as (id, owpSongPath, hasAudio) tuples for cross-module coordination.
    public func sceneAudioStatus() -> [(id: UUID, songPath: String, hasAudio: Bool)] {
        store.scenes.map { scene in
            (id: scene.id, songPath: scene.owpSongPath, hasAudio: !(scene.defaultAudioPath ?? "").isEmpty)
        }
    }

    private func resolvedGeminiModel(from raw: String?) -> GeminiModel {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized == "pro" || normalized.contains("pro") {
            return .pro
        }
        if normalized == "flash" || normalized.contains("flash") || normalized.contains("banana") {
            return .flash
        }
        return raw.flatMap(GeminiModel.init(rawValue:)) ?? store.selectedGeminiModel
    }

    private func resolvedSceneFilter(_ raw: String?) throws -> Set<UUID>? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.lowercased() != "all" else {
            return nil
        }
        if raw.lowercased() == "first" {
            guard let first = store.scenes.first else { return [] }
            return [first.id]
        }
        if let uuid = UUID(uuidString: raw),
           store.scenes.contains(where: { $0.id == uuid }) {
            return [uuid]
        }
        if let index = Int(raw),
           index > 0,
           index <= store.scenes.count {
            return [store.scenes[index - 1].id]
        }
        if let scene = store.scenes.first(where: { scene in
            scene.name.localizedCaseInsensitiveContains(raw) ||
                scene.owpSongPath.localizedCaseInsensitiveContains(raw)
        }) {
            return [scene.id]
        }
        throw cliError("No scene matched '\(raw)'.")
    }

    private func resolvedMoments(_ raw: String?) throws -> [ImagineShotMoment] {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return [.beginning]
        }
        if raw.lowercased() == "all" {
            return ImagineShotMoment.allCases
        }

        let tokens = raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return [.beginning] }

        var moments: [ImagineShotMoment] = []
        for token in tokens {
            switch token {
            case "beginning", "start", "first":
                moments.append(.beginning)
            case "middle", "mid", "center", "centre":
                moments.append(.middle)
            case "end", "final", "last":
                moments.append(.end)
            default:
                throw cliError("Invalid moment token '\(token)'. Use beginning,middle,end or all.")
            }
        }

        var seen = Set<ImagineShotMoment>()
        return moments.filter { seen.insert($0).inserted }
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func waitForImageIntelligenceReady() async throws {
        for _ in 0..<60 {
            if await store.imageIntelligenceStats() != nil {
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        throw cliError("Image Intelligence SQLite store did not become ready within 6 seconds.")
    }

    private func writeShotReferenceTodoList(
        report: AutomationDryRunReport,
        projectRoot: URL
    ) throws {
        struct TodoEntry: Codable, Sendable {
            var sceneID: UUID
            var sceneName: String
            var shotID: UUID
            var shotIndex: Int
            var shotName: String
            var missingRequirements: [String]
            var blockerCodes: [String]
            var note: String
        }

        struct TodoFile: Codable, Sendable {
            var schemaVersion: Int = 1
            var generatedAt: Date = Date()
            var model: String
            var imageSize: String
            var totalOpenTodos: Int
            var entries: [TodoEntry]
        }

        var entries: [TodoEntry] = []
        for shot in report.shots {
            let blockerCodes = shot.blockers.map(\.code.rawValue)
            let missingReferenceFields = shot.blockers
                .filter { $0.code == .blockedMissingReferenceRole }
                .compactMap(\.field)
            guard !missingReferenceFields.isEmpty || blockerCodes.contains(AutomationBlockerCode.blockedMissingEditSource.rawValue) else {
                continue
            }
            let spec = shot.effectiveShotSpec
            entries.append(
                .init(
                    sceneID: spec.sceneID,
                    sceneName: spec.sceneName,
                    shotID: spec.shotID,
                    shotIndex: spec.shotIndex,
                    shotName: spec.shotName,
                    missingRequirements: Array(Set(missingReferenceFields)).sorted(),
                    blockerCodes: Array(Set(blockerCodes)).sorted(),
                    note: "Add liked/picked references for missing roles before execute mode. Generation should remain blocked until resolved."
                )
            )
        }

        let todo = TodoFile(
            model: report.model,
            imageSize: report.imageSize,
            totalOpenTodos: entries.count,
            entries: entries
        )
        let directory = AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "shot-frame-plans")
            .appendingPathComponent("DryRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let todoURL = directory.appendingPathComponent("shot-reference-todos-latest.json")
        try writeCodable(todo, to: todoURL)
    }

    private func resolvedImageIntelligenceSmokeImage(
        _ rawPath: String?,
        projectRoot: URL
    ) throws -> String {
        if let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawPath.isEmpty {
            let url = URL(fileURLWithPath: rawPath).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw cliError("Smoke-test image does not exist: \(url.path)")
            }
            return url.path
        }

        let supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "webp"]
        guard let enumerator = FileManager.default.enumerator(
            at: projectRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw cliError("Could not scan project for an image.")
        }

        for case let url as URL in enumerator {
            guard supportedExtensions.contains(url.pathExtension.lowercased()) else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true,
                  (values?.fileSize ?? 0) > 0 else { continue }
            return url.standardizedFileURL.path
        }

        throw cliError("No existing project image found for Image Intelligence smoke test.")
    }

    private func cliError(_ message: String) -> NSError {
        NSError(domain: "AnimateWorkspaceController.CLI", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
    }

    private func observeSaveIndicator() {
        withObservationTracking {
            _ = store.saveIndicator
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.saveIndicator = self.store.saveIndicator
                self.observeSaveIndicator()
            }
        }

        saveIndicator = store.saveIndicator
    }

    private func observeSelectionPath() {
        withObservationTracking {
            _ = currentSelectionPath()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.selectedScenePath = self.currentSelectionPath()
                self.observeSelectionPath()
            }
        }

        selectedScenePath = currentSelectionPath()
    }
}

// MARK: - Public Workspace (consumed by OperaShellView)

@available(macOS 26.0, *)
public struct AnimateWorkspace: View {
    @ObservedObject private var controller: AnimateWorkspaceController

    public init(controller: AnimateWorkspaceController) {
        _controller = ObservedObject(wrappedValue: controller)
    }

    public var body: some View {
        ZStack {
            AnimateWorkspaceContent(store: controller.store)
                .environment(\.unifiedImageFlipHandler) { path in
                    controller.store.flipImageHorizontallyAndAttachLikeOriginal(path: path)
                }
                .environment(\.unifiedImageRecategorizeHandler) { path, category in
                    controller.store.recategorizeImageReviewScope(path: path, semanticRole: category.semanticRole)
                }
                .allowsHitTesting(!(controller.isLoadingProject || controller.isSelectionRestorePending))

            if controller.isLoadingProject || controller.isSelectionRestorePending {
                AnimateWorkspaceLoadOverlay(
                    title: controller.store.owpURL == nil ? "Opening Animate" : "Refreshing Animate",
                    message: controller.loadStatusMessage
                )
            }
        }
    }
}

// MARK: - Three-Panel Content

@available(macOS 26.0, *)
private struct AnimateWorkspaceContent: View {
    @Bindable var store: AnimateStore
    @State private var selectedShotIndex: Int?
    @StateObject private var waveformCache = AnimateAudioWaveformCache()

    @AppStorage("amira.animate.sidebarVisible") private var sidebarVisible = true
    @AppStorage("amira.animate.sidebar.width") private var sidebarWidth: Double = OperaChromeSidebarMetrics.defaultWidth
    @AppStorage("amira.animate.showInspector") private var inspectorVisible = true
    @AppStorage("amira.animate.inspector.width") private var inspectorWidth: Double = 320

    private var projectTitle: String {
        store.owpURL?.deletingPathExtension().lastPathComponent ?? "Untitled Opera"
    }

    private var selectedShot: AnimationSceneShot? {
        guard let scene = store.selectedScene,
              let idx = selectedShotIndex,
              idx < scene.shots.count else { return nil }
        return scene.shots[idx]
    }

    var body: some View {
        Group {
            if store.owpURL == nil {
                OperaChromeEmptyState(
                    systemImage: "sparkles.tv",
                    title: "Open A Project",
                    message: "Use File > Open Project to pick a local Amira project folder from disk."
                )
            } else {
                workspaceBody
            }
        }
    }

    private var workspaceBody: some View {
        HStack(spacing: 0) {
            // MARK: Left Sidebar
            if sidebarVisible {
                OperaChromeFlatPane(
                    headerPadding: OperaChromeSidebarMetrics.headerPadding
                ) {
                    OperaChromePaneHeader(
                        eyebrow: "ANIMATE",
                        title: "Scenes",
                        subtitle: "\(store.scenes.count) staged"
                    ) {
                        OperaChromeActionButton(systemImage: "sidebar.left") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarVisible = false
                            }
                        }
                    }
                } content: {
                    SidebarView(store: store)
                }
                .frame(width: sidebarWidth)

                OperaChromeSplitHandle(
                    onDragChanged: resizeSidebar,
                    onDragEnded: { }
                )
            }

            // MARK: Main Content
            OperaChromeFlatPane {
                HStack(alignment: .center, spacing: 12) {
                    if !sidebarVisible {
                        OperaChromeActionButton(systemImage: "sidebar.left") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                sidebarVisible = true
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("ANIMATE")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .tracking(1.2)
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                        Text(projectTitle)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(OperaChromeTheme.textPrimary)
                            .lineLimit(1)
                        Text(store.selectedScene?.name ?? "Vidu animation workspace")
                            .font(.system(size: 11))
                            .foregroundStyle(OperaChromeTheme.textSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 10)

                    if !inspectorVisible {
                        OperaChromeActionButton(systemImage: "sidebar.right") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = true
                            }
                        }
                    }
                }
            } content: {
                VStack(spacing: 0) {
                    // Video player area — 16:9 placeholder (TODO: AVPlayer integration)
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.black)
                        .aspectRatio(16.0 / 9.0, contentMode: .fit)
                        .overlay {
                            if let shot = selectedShot,
                               let videoPath = shot.shotFrameGeneration?.viduOutputPath {
                                // TODO: AVPlayer integration
                                Text("Video: \(videoPath)")
                                    .foregroundStyle(.white)
                                    .font(.caption)
                            } else {
                                VStack(spacing: 8) {
                                    Image(systemName: "film")
                                        .font(.largeTitle)
                                        .foregroundStyle(.white.opacity(0.3))
                                    Text("Select a shot and generate video")
                                        .font(.caption)
                                        .foregroundStyle(.white.opacity(0.3))
                                }
                            }
                        }
                        .padding(16)

                    // Filmstrip + production strip for selected scene
                    if let scene = store.selectedScene, !scene.shots.isEmpty {
                        Divider()
                        ShotFilmstripView(store: store, shots: scene.shots, selectedShotIndex: $selectedShotIndex)
                        if let idx = selectedShotIndex, idx < scene.shots.count {
                            Divider()
                            ShotProductionStripView(store: store, scene: scene, shot: scene.shots[idx], shotIndex: idx)
                        }
                    }

                    // Audio waveform track — always visible when a scene is selected
                    if let scene = store.selectedScene {
                        Divider()
                        AudioWaveformTrackView(
                            store: store,
                            scene: scene,
                            waveformCache: waveformCache
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: Right Inspector
            if inspectorVisible {
                OperaChromeSplitHandle(
                    onDragChanged: resizeInspector,
                    onDragEnded: { }
                )

                OperaChromeFlatPane {
                    OperaChromePaneHeader(
                        eyebrow: "DETAILS",
                        title: "Inspector",
                        subtitle: "Animate"
                    ) {
                        OperaChromeActionButton(systemImage: "xmark") {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                inspectorVisible = false
                            }
                        }
                    }
                } content: {
                    AnimateViduInspectorView(store: store, selectedShot: selectedShot)
                }
                .frame(width: max(inspectorWidth, 320))
            }
        }
        .background(OperaChromeTheme.workspaceBackground)
    }

    private func resizeSidebar(_ delta: CGFloat) {
        sidebarWidth = min(
            max(sidebarWidth + Double(delta), OperaChromeSidebarMetrics.minWidth),
            OperaChromeSidebarMetrics.maxWidth
        )
    }

    private func resizeInspector(_ delta: CGFloat) {
        inspectorWidth = min(
            max(inspectorWidth - Double(delta), 320),
            600
        )
    }
}

// MARK: - Vidu Inspector Panel

@available(macOS 26.0, *)
private struct AnimateViduInspectorView: View {
    @Bindable var store: AnimateStore
    let selectedShot: AnimationSceneShot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Shot details
                if let shot = selectedShot {
                    shotDetailsSection(shot: shot)
                    Divider()
                    viduQueueSection(shot: shot)
                } else {
                    Text("Select a shot in the filmstrip to see details.")
                        .font(.system(size: 12))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                        .padding()
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func shotDetailsSection(shot: AnimationSceneShot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("SHOT")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(OperaChromeTheme.textTertiary)

            VStack(alignment: .leading, spacing: 4) {
                Text(shot.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                if let camera = shot.cameraShot {
                    Label(camera.rawValue, systemImage: "camera")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }

                HStack(spacing: 4) {
                    Text("Frames \(shot.startFrame)–\(shot.endFrame)")
                        .font(.system(size: 11))
                        .foregroundStyle(OperaChromeTheme.textSecondary)
                }
            }
        }
    }

    @ViewBuilder
    private func viduQueueSection(shot: AnimationSceneShot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("VIDU STATUS")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(1.0)
                .foregroundStyle(OperaChromeTheme.textTertiary)

            if let fg = shot.shotFrameGeneration {
                VStack(alignment: .leading, spacing: 4) {
                    // Read begin/end frames from the Imagine gallery
                    let sceneID = store.selectedScene?.id
                    let shotIndex = store.selectedScene?.shots.firstIndex(where: { $0.id == shot.id }) ?? -1
                    let gallery = (sceneID != nil && shotIndex >= 0) ? store.imagineGallery(for: sceneID!, shotIndex: shotIndex) : nil

                    statusRow(label: "Begin frame", ready: gallery?.selectedBeginningPath != nil)
                    statusRow(label: "End frame", ready: gallery?.selectedEndPath != nil)
                    statusRow(label: "Video output", ready: fg.viduOutputPath != nil)

                    if let videoPath = fg.viduOutputPath {
                        Text(videoPath)
                            .font(.system(size: 10))
                            .foregroundStyle(OperaChromeTheme.textTertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            } else {
                Text("No generation data yet. Use the production strip to set up begin/end frames and generate video.")
                    .font(.system(size: 11))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func statusRow(label: String, ready: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: ready ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11))
                .foregroundStyle(ready ? Color.green : OperaChromeTheme.textTertiary)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(OperaChromeTheme.textSecondary)
        }
    }
}

@available(macOS 26.0, *)
struct AnimateWorkspaceLoadOverlay: View {
    let title: String
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.14)
                .ignoresSafeArea()

            VStack(alignment: .leading, spacing: 10) {
                ProgressView()
                    .controlSize(.small)

                Text(title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(OperaChromeTheme.textPrimary)

                Text(message)
                    .font(.system(size: 12))
                    .foregroundStyle(OperaChromeTheme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: 320, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(OperaChromeTheme.panelBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(OperaChromeTheme.stroke, lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.12), radius: 10, y: 6)
        }
    }
}
