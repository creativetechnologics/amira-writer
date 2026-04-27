import Foundation
import Network
import ProjectKit

// MARK: - AnimateAPIServer
//
// Loopback HTTP JSON API server for Animate. Lets an external tool (e.g. a
// Claude / Codex CLI session) enqueue place image generations as if the user
// had clicked the UI button: results appear in the Gemini activity queue and
// are attached to the correct BackgroundPlate record.
//
// This is loopback-only (127.0.0.1) — the listener binds to the IPv4 loopback
// interface, so it is unreachable from any other machine. No auth is enforced
// beyond that boundary; anything already running on Gary's machine is trusted.
//
// Vendored `AnimateHTTPRequest` / `AnimateHTTPResponse` types mirror the ones
// in Score's APIServer.swift so we don't take a cross-package dependency.

@available(macOS 26.0, *)
final class AnimateAPIServer: @unchecked Sendable {

    /// Idempotent singleton. Prevents a second WindowGroup `.task` or a hot
    /// reload from spawning a duplicate listener on the same port.
    @MainActor
    static var shared: AnimateAPIServer?

    /// Optional hook the host (e.g. Opera shell / Animate bootstrap) sets so the
    /// API can eagerly hydrate the bound AnimateStore when a request arrives
    /// before any UI has triggered a project load. Returns once the load is
    /// complete (or has failed); the router polls `store.owpURL` afterwards.
    @MainActor
    static var projectActivator: (@MainActor () async -> Void)?

    private let listener: NWListener
    private let queue = DispatchQueue(label: "com.amira.animate.api", qos: .userInitiated)
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]
    private let router: AnimateAPIRouter
    private(set) var port: UInt16

    var logHandler: (@Sendable (String, String, Int, String) -> Void)?

    @MainActor
    init(store: AnimateStore, port: UInt16 = 19849) throws {
        self.port = port
        self.router = AnimateAPIRouter(store: store)

        let params = NWParameters.tcp
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "AnimateAPIServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Invalid port: \(port)"])
        }
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)
        params.allowLocalEndpointReuse = true

        self.listener = try NWListener(using: params)
    }

    deinit {
        listener.cancel()
        queue.async { [connections = self.connections] in
            for conn in connections.values { conn.cancel() }
        }
    }

    /// Starts the server. Idempotent at the shared-singleton level: if
    /// `shared` is already non-nil, callers should skip creating a new one.
    @MainActor
    static func startIfNeeded(store: AnimateStore, port: UInt16 = 19849) {
        guard shared == nil else { return }
        do {
            let server = try AnimateAPIServer(store: store, port: port)
            server.logHandler = { method, path, status, summary in
                NSLog("[AnimateAPI] %@ %@ -> %d %@", method, path, status, summary)
            }
            server.start()
            shared = server
        } catch {
            NSLog("[AnimateAPI] Failed to start: %@", error.localizedDescription)
        }
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                if let port = self?.listener.port?.rawValue {
                    self?.port = port
                    NSLog("[AnimateAPI] Listening on localhost:%d", port)
                }
            case .failed(let error):
                NSLog("[AnimateAPI] Listener failed: %@", error.localizedDescription)
                self?.listener.cancel()
            case .cancelled:
                NSLog("[AnimateAPI] Listener cancelled")
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
        queue.async { [weak self] in
            guard let self else { return }
            for conn in self.connections.values { conn.cancel() }
            self.connections.removeAll()
            self.receiveBuffers.removeAll()
        }
    }

    // MARK: - Connection Handling

    private func handleConnection(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        receiveBuffers[id] = Data()

        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.cleanupConnection(id)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receiveMore(on: connection, id: id)
    }

    private func cleanupConnection(_ id: ObjectIdentifier) {
        guard let conn = connections.removeValue(forKey: id) else { return }
        receiveBuffers.removeValue(forKey: id)
        conn.cancel()
    }

    private func receiveMore(on connection: NWConnection, id: ObjectIdentifier) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard self.connections[id] != nil else { return }

            if let data, !data.isEmpty {
                self.receiveBuffers[id, default: Data()].append(data)
            }
            let buffer = self.receiveBuffers[id] ?? Data()

            if let request = AnimateHTTPRequest.parse(buffer) {
                self.receiveBuffers[id] = nil
                self.processRequest(request, connection: connection, id: id)
            } else if isComplete || error != nil {
                self.cleanupConnection(id)
            } else if buffer.count > 4_194_304 {
                self.sendResponse(AnimateHTTPResponse.error(413, "Request too large"),
                                  on: connection, id: id)
            } else {
                self.receiveMore(on: connection, id: id)
            }
        }
    }

    private func processRequest(_ request: AnimateHTTPRequest,
                                connection: NWConnection,
                                id: ObjectIdentifier) {
        Task { @MainActor [weak self, router] in
            let response = await router.handle(request)
            guard let self else {
                connection.cancel()
                return
            }
            let summary = String(response.body.prefix(120))
            self.logHandler?(request.method, request.path, response.status, summary)
            self.queue.async { [weak self] in
                self?.sendResponse(response, on: connection, id: id)
            }
        }
    }

    private func sendResponse(_ response: AnimateHTTPResponse,
                              on connection: NWConnection,
                              id: ObjectIdentifier) {
        let httpData = response.serialize()
        connection.send(content: httpData, completion: .contentProcessed { [weak self] error in
            if let error {
                NSLog("[AnimateAPI] Send error: %@", error.localizedDescription)
            }
            self?.cleanupConnection(id)
        })
    }
}

// MARK: - AnimateAPIRouter

@available(macOS 26.0, *)
@MainActor
final class AnimateAPIRouter {
    private let store: AnimateStore

    init(store: AnimateStore) {
        self.store = store
    }

    func handle(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        if request.method == "GET", request.path == "/automation/project/summary" {
            await ensureProjectHydrated()
            return automationProjectSummaryResponse()
        }
        if request.method == "GET", let shotID = automationShotEffectiveSpecID(from: request.path) {
            await ensureProjectHydrated()
            return automationEffectiveShotSpecResponse(shotID: shotID)
        }
        if request.method == "GET", let sceneID = automationSceneEffectiveSpecsID(from: request.path) {
            await ensureProjectHydrated()
            return automationSceneEffectiveShotSpecsResponse(sceneID: sceneID)
        }
        if request.method == "POST", request.path == "/automation/references/resolve" {
            await ensureProjectHydrated()
            return automationReferenceResolveResponse(request)
        }
        if request.method == "GET", let ids = automationReferenceIDs(from: request.path) {
            await ensureProjectHydrated()
            return automationReferenceGetResponse(sceneID: ids.sceneID, shotID: ids.shotID)
        }
        if request.method == "POST", request.path == "/automation/frame-plans/dry-run" {
            await ensureProjectHydrated()
            return await automationFramePlansDryRunResponse(request)
        }
        if request.method == "POST", request.path == "/automation/minimax/scaffold" {
            await ensureProjectHydrated()
            return await automationMiniMaxScaffoldResponse(request)
        }
        if request.method == "POST", request.path == "/automation/frames/generate" {
            await ensureProjectHydrated()
            return await automationFramesGenerateResponse(request)
        }
        if request.method == "GET", request.path == "/automation/continuity-builder/session" {
            await ensureProjectHydrated()
            return await automationContinuityBuilderSessionResponse()
        }
        if request.method == "POST", request.path == "/automation/continuity-builder/generate" {
            await ensureProjectHydrated()
            return await automationContinuityBuilderGenerateResponse(request)
        }
        if request.method == "POST", request.path == "/automation/feedback/rules/extract" {
            await ensureProjectHydrated()
            return await automationFeedbackRulesExtractResponse(request)
        }
        if request.method == "POST", request.path == "/automation/feedback/rules/query" {
            await ensureProjectHydrated()
            return automationFeedbackRulesQueryResponse(request)
        }
        if request.method == "GET", let ids = automationGeneratedFrameIDs(from: request.path), !ids.isApproval {
            await ensureProjectHydrated()
            return automationGeneratedFrameGetResponse(sceneID: ids.sceneID, shotID: ids.shotID, moment: ids.moment)
        }
        if request.method == "POST", let ids = automationGeneratedFrameIDs(from: request.path), ids.isApproval {
            await ensureProjectHydrated()
            return automationGeneratedFrameApprovalResponse(request, sceneID: ids.sceneID, shotID: ids.shotID, moment: ids.moment)
        }

        switch (request.method, request.path) {
        case ("GET", "/health"):
            // /health reports current state without forcing a load.
            return healthResponse()
        case ("GET", "/places"):
            await ensureProjectHydrated()
            return listPlacesResponse()
        case ("POST", "/places/generate"):
            await ensureProjectHydrated()
            return await generatePlaceResponse(request)
        case ("GET", "/image-intelligence/status"):
            await ensureProjectHydrated()
            return await imageIntelligenceStatusResponse()
        case ("POST", "/image-intelligence/configure"):
            await ensureProjectHydrated()
            return await configureImageIntelligenceResponse(request)
        case ("POST", "/image-intelligence/backfill"):
            await ensureProjectHydrated()
            return await imageIntelligenceBackfillResponse(request)
        case ("POST", "/image-intelligence/worker/start"):
            await ensureProjectHydrated()
            return await imageIntelligenceWorkerResponse(shouldStart: true)
        case ("POST", "/image-intelligence/worker/stop"):
            await ensureProjectHydrated()
            return await imageIntelligenceWorkerResponse(shouldStart: false)
        case ("POST", "/image-intelligence/queue/reset"):
            await ensureProjectHydrated()
            return await imageIntelligenceQueueResetResponse()
        case ("GET", "/image-intelligence/jobs"):
            await ensureProjectHydrated()
            return await imageIntelligenceJobsResponse(request)
        case ("GET", "/image-intelligence/logs"):
            await ensureProjectHydrated()
            return await imageIntelligenceLogsResponse(request)
        case ("GET", "/image-intelligence/asset"):
            await ensureProjectHydrated()
            return await imageIntelligenceAssetResponse(request)
        case ("POST", "/shot-frames/dry-run"):
            await ensureProjectHydrated()
            return await shotFrameDryRunResponse(request)
        case ("POST", "/vertex/image-smoke"):
            await ensureProjectHydrated()
            return await vertexImageSmokeResponse(request)
        case ("POST", "/map3d/regenerate"):
            // No `ensureProjectHydrated()` — the pipeline reads canon JSON
            // from disk, not from the AnimateStore, so a regen can run before
            // any project is loaded.
            return map3DRegenerateResponse()
        case ("GET", "/map3d/regenerate/status"):
            return map3DRegenerateStatusResponse()
        default:
            return AnimateHTTPResponse.error(404, "Unknown route: \(request.method) \(request.path)")
        }
    }

    /// If the bound AnimateStore has no project loaded, invoke the host's
    /// `projectActivator` (if any) and poll briefly for the load to complete.
    /// No-op when a project is already loaded.
    private func ensureProjectHydrated() async {
        guard store.owpURL == nil else { return }
        guard let activator = AnimateAPIServer.projectActivator else { return }
        await activator()
        let deadline = Date().addingTimeInterval(45)
        while store.owpURL == nil, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(200))
        }
    }

    // MARK: Routes

    private func healthResponse() -> AnimateHTTPResponse {
        let vertex = ImageGenBackendStore.currentVertexSettings()
        let payload: [String: Any] = [
            "ok": true,
            "project": store.owpURL?.lastPathComponent ?? NSNull(),
            "placesCount": store.backgrounds.count,
            "selectedGeminiModel": store.selectedGeminiModel.rawValue,
            "selectedGeminiModelDisplayName": store.selectedGeminiModel.displayName,
            "geminiAllowed": store.isGeminiAllowed(),
            "backend": ImageGenBackendStore.currentBackend().rawValue,
            "backendDisplayName": ImageGenBackendStore.currentBackend().displayName,
            "vertexProjectID": vertex.projectID,
            "vertexRegion": vertex.region
        ]
        return AnimateHTTPResponse.okJSON(payload)
    }

    private func listPlacesResponse() -> AnimateHTTPResponse {
        let payload = store.backgrounds.map { bg -> [String: Any] in
            [
                "id": bg.id.uuidString,
                "name": bg.name,
                "locationCategory": bg.locationCategory,
                "hasVisualBrief": !bg.visualBrief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "photorealImageCount": bg.imagePaths.count,
                "animatedImageCount": bg.animatedImagePaths.count
            ]
        }
        return AnimateHTTPResponse.okJSON(["places": payload])
    }

    private func generatePlaceResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        guard let body = request.jsonBody() else {
            return .error(400, "Missing or malformed JSON body")
        }
        guard let identifier = (body["place"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !identifier.isEmpty else {
            return .error(400, "'place' field is required (name or UUID)")
        }

        let workflowRaw = (body["workflow"] as? String) ?? "photorealistic"
        guard let workflow = PlaceWorkflowMode(rawValue: workflowRaw) else {
            return .error(400, "Invalid workflow: \(workflowRaw) (use 'photorealistic' or 'animated')")
        }

        let modelOverride: GeminiModel?
        if let modelRaw = body["model"] as? String, !modelRaw.isEmpty {
            switch modelRaw.lowercased() {
            case "flash", "nano-banana-2", "nano_banana_2", "nanobanana2":
                modelOverride = .flash
            case "pro", "nano-banana-pro", "nano_banana_pro", "nanobananapro":
                modelOverride = .pro
            default:
                return .error(400, "Invalid model: \(modelRaw) (use 'flash' or 'pro')")
            }
        } else {
            modelOverride = nil
        }

        let count = max(1, min(4, (body["count"] as? Int) ?? 1))

        let aspectRatioOverride = (body["aspectRatio"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let imageSizeOverride = (body["imageSize"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let referenceMode: AnimateStore.APIReferenceMode
        switch (body["referenceMode"] as? String)?.lowercased() {
        case "curated":
            referenceMode = .curated
        case nil, "", "default", "auto":
            referenceMode = .default
        case let other?:
            return .error(400, "Invalid referenceMode: \(other) (use 'default' or 'curated')")
        }

        do {
            let result = try await store.generatePlaceImageForAPI(
                placeIdentifier: identifier,
                workflow: workflow,
                model: modelOverride,
                count: count,
                aspectRatio: (aspectRatioOverride?.isEmpty == false) ? aspectRatioOverride : nil,
                imageSize: (imageSizeOverride?.isEmpty == false) ? imageSizeOverride : nil,
                referenceMode: referenceMode
            )
            let payload: [String: Any] = [
                "ok": true,
                "placeID": result.placeID.uuidString,
                "placeName": result.placeName,
                "workflow": workflow.rawValue,
                "model": result.model.rawValue,
                "modelDisplayName": result.model.displayName,
                "aspectRatio": result.aspectRatio,
                "imageSize": result.imageSize,
                "referenceMode": referenceMode.rawValue,
                "referenceCount": result.referenceCount,
                "referencePaths": result.referencePaths,
                "backend": ImageGenBackendStore.currentBackend().rawValue,
                "activityIDs": result.activityIDs.map(\.uuidString),
                "storedPaths": result.storedPaths
            ]
            return AnimateHTTPResponse.okJSON(payload)
        } catch let error as AnimateStore.APIGenerationError {
            return .error(error.status, error.message)
        } catch {
            return .error(500, "Generation failed: \(error.localizedDescription)")
        }
    }


    // MARK: Automation Phase 0/1 API (dry-run only)

    private func automationProjectSummaryResponse() -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let summary = AutomationSourceResolver.projectSummary(store: store, projectRoot: projectRoot)
        return .okCodable(summary)
    }

    private func automationEffectiveShotSpecResponse(shotID: UUID) -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        guard let located = locateShot(shotID: shotID) else {
            return .error(404, "No shot matched \(shotID.uuidString).")
        }
        let spec = EffectiveShotSpecBuilder(store: store).build(
            scene: located.scene,
            shotIndex: located.shotIndex,
            projectRoot: projectRoot
        )
        return .okCodable(spec)
    }

    private func automationSceneEffectiveShotSpecsResponse(sceneID: UUID) -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        guard let scene = store.scenes.first(where: { $0.id == sceneID }) else {
            return .error(404, "No scene matched \(sceneID.uuidString).")
        }
        let builder = EffectiveShotSpecBuilder(store: store)
        let specs = scene.shots.indices.map { index in
            builder.build(scene: scene, shotIndex: index, projectRoot: projectRoot)
        }
        return .okCodable(specs)
    }

    private func automationReferenceResolveResponse(_ request: AnimateHTTPRequest) -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let body = request.jsonBody() ?? [:]
        guard let shotID = uuidValue(body["shotID"]) else {
            return .error(400, "Missing required shotID.")
        }
        guard let located = locateShot(shotID: shotID) else {
            return .error(404, "No shot matched \(shotID.uuidString).")
        }
        if let sceneID = uuidValue(body["sceneID"]), sceneID != located.scene.id {
            return .error(400, "shotID does not belong to supplied sceneID.")
        }
        let writeSidecar = boolValue(body["write"]) ?? true
        do {
            let spec = EffectiveShotSpecBuilder(store: store).build(
                scene: located.scene,
                shotIndex: located.shotIndex,
                projectRoot: projectRoot
            )
            let resolved = try ReferenceContractResolver(store: store).resolve(
                spec: spec,
                projectRoot: projectRoot,
                write: writeSidecar
            )
            return .okCodable(AutomationReferenceResolvePayload(
                ok: true,
                referenceContractPath: resolved.url?.path,
                referenceContract: resolved.contract
            ))
        } catch {
            return .error(500, "Reference resolve failed: \(error.localizedDescription)")
        }
    }

    private func automationReferenceGetResponse(sceneID: UUID, shotID: UUID) -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let resolver = ReferenceContractResolver(store: store)
        if let contract = resolver.readExisting(sceneID: sceneID, shotID: shotID, projectRoot: projectRoot) {
            return .okCodable(contract)
        }
        guard let located = locateShot(shotID: shotID), located.scene.id == sceneID else {
            return .error(404, "No reference contract or matching shot found for scene/shot.")
        }
        do {
            let spec = EffectiveShotSpecBuilder(store: store).build(scene: located.scene, shotIndex: located.shotIndex, projectRoot: projectRoot)
            let resolved = try resolver.resolve(spec: spec, projectRoot: projectRoot, write: false)
            return .okCodable(resolved.contract)
        } catch {
            return .error(500, "Reference get failed: \(error.localizedDescription)")
        }
    }

    private func automationFramePlansDryRunResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let body = request.jsonBody() ?? [:]
        let model = resolvedGeminiModel(from: stringValue(body["model"]))
        let imageSize = stringValue(body["imageSize"]) ?? ShotFrameOpenMattePlan.defaultGeneratedImageSize
        let maxCostUSD = doubleValue(body["maxCostUSD"])
        let writeSidecars = boolValue(body["write"]) ?? true

        do {
            let sceneFilter = try resolvedSceneFilter(stringValue(body["scene"]))
            let shotFilter = uuidValue(body["shotID"])
            let summary = AutomationSourceResolver.projectSummary(store: store, projectRoot: projectRoot)
            let specBuilder = EffectiveShotSpecBuilder(store: store)
            let referenceResolver = ReferenceContractResolver(store: store)
            let planBuilder = ShotFramePlanBuilder(store: store)
            var results: [AutomationDryRunShotResult] = []
            var allBlockers: [AutomationBlocker] = []

            for scene in store.scenes where sceneFilter?.contains(scene.id) ?? true {
                for index in scene.shots.indices {
                    let shot = scene.shots[index]
                    if let shotFilter, shot.id != shotFilter { continue }
                    let spec = specBuilder.build(scene: scene, shotIndex: index, projectRoot: projectRoot)
                    let specURL = writeSidecars ? try specBuilder.write(spec, projectRoot: projectRoot) : nil
                    let resolved = try referenceResolver.resolve(spec: spec, projectRoot: projectRoot, write: writeSidecars)
                    let planSet = planBuilder.buildPlans(spec: spec, contract: resolved.contract, projectRoot: projectRoot, imageSize: imageSize)
                    let planURL = writeSidecars ? try planBuilder.write(planSet, projectRoot: projectRoot) : nil
                    let shotCost = planSet.plans.reduce(0) { $0 + model.estimatedCost(for: $1.openMattePlan?.generatedImageSize ?? imageSize) }
                    let blockers = spec.blockers + resolved.contract.blockers + planSet.plans.compactMap { plan -> AutomationBlocker? in
                        plan.canExecute ? nil : .init(code: .blockedMissingEditSource, message: "\(plan.moment.rawValue) plan requires an edit source image that is not readable.", field: "shotFrameGenerationPlan.\(plan.moment.rawValue)")
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
                allBlockers.append(.init(code: .blockedCostCap, message: "Estimated Vertex cost $\(String(format: "%.4f", totalCost)) exceeds cap $\(String(format: "%.2f", maxCostUSD)).", field: "maxCostUSD"))
            }
            let report = AutomationDryRunReport(
                model: model.rawValue,
                imageSize: imageSize,
                projectSummary: summary,
                shots: results,
                estimatedVertexCostUSD: totalCost,
                blockers: allBlockers
            )
            let reportURL = try writeAutomationDryRunReport(report, projectRoot: projectRoot)
            return .okCodable(AutomationFramePlansDryRunPayload(ok: true, reportPath: reportURL.path, report: report))
        } catch {
            return .error(400, error.localizedDescription)
        }
    }

    private func automationMiniMaxScaffoldResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let body = request.jsonBody() ?? [:]
        let mode = stringValue(body["mode"])?.lowercased() ?? "dry_run"
        guard mode == "dry_run" || mode == "dry-run" || mode == "preview" || mode == "execute" else {
            return .error(400, "Invalid mode '\(mode)'. Use dry_run or execute.")
        }
        let normalizedMode = mode == "execute" ? "execute" : "dry_run"
        let model = stringValue(body["model"]) ?? "MiniMax-M2.7"
        let writeSidecars = boolValue(body["write"]) ?? true

        do {
            let sceneFilter = try resolvedSceneFilter(stringValue(body["scene"]) ?? "first")
            let matchedScenes = store.scenes.filter { scene in sceneFilter?.contains(scene.id) ?? false }
            guard let scene = matchedScenes.first else {
                return .error(404, "No scene matched MiniMax scaffold request.")
            }
            guard matchedScenes.count <= 1 else {
                return .error(400, "MiniMax scaffold currently accepts one scene at a time.")
            }
            let scaffold = try await MiniMaxAutomationScaffoldService(store: store).build(
                .init(
                    scene: scene,
                    projectRoot: projectRoot,
                    mode: normalizedMode,
                    model: model,
                    writeSidecars: writeSidecars,
                    apiKey: store.miniMaxAPIKey
                )
            )
            return .okCodable(AutomationMiniMaxScaffoldPayload(
                ok: scaffold.errorMessage == nil,
                scaffoldPath: scaffold.artifactPath,
                scaffold: scaffold
            ))
        } catch {
            return .error(400, error.localizedDescription)
        }
    }


    private func automationFramesGenerateResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let body = request.jsonBody() ?? [:]
        let mode = (stringValue(body["mode"]) ?? "preflight").lowercased()
        guard mode == "preflight" || mode == "execute" else {
            return .error(400, "Invalid mode: \(mode). Use preflight or execute.")
        }
        let model = resolvedGeminiModel(from: stringValue(body["model"]))
        let imageSize = stringValue(body["imageSize"]) ?? ShotFrameOpenMattePlan.defaultGeneratedImageSize
        let maxCostUSD = doubleValue(body["maxCostUSD"])
        let maxFrames = intValue(body["maxFrames"])
        let shotID = uuidValue(body["shotID"])
        do {
            let sceneFilter = try resolvedSceneFilter(stringValue(body["scene"]))
            let moments = try resolvedMoments(body["moments"])
            let response = await AutomationFrameGenerationService(store: store).run(
                projectRoot: projectRoot,
                sceneFilter: sceneFilter,
                shotFilter: shotID,
                moments: moments,
                model: model,
                imageSize: imageSize,
                mode: mode,
                maxCostUSD: maxCostUSD,
                maxFrames: maxFrames
            )
            return .okCodable(response)
        } catch {
            return .error(400, error.localizedDescription)
        }
    }

    private func automationContinuityBuilderSessionResponse() async -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let session = await ContinuityBuilderService(store: store).loadOrCreateSession(projectRoot: projectRoot)
        return .okCodable(session)
    }

    private func automationContinuityBuilderGenerateResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let body = request.jsonBody() ?? [:]
        let mode = (stringValue(body["mode"]) ?? "dry_run").lowercased()
        guard mode == "dry_run" || mode == "dry-run" || mode == "preview" || mode == "execute" else {
            return .error(400, "Invalid mode: \(mode). Use dry_run or execute.")
        }
        let normalizedMode = mode == "execute" ? "execute" : "dry_run"
        guard normalizedMode != "execute" || doubleValue(body["maxCostUSD"]) != nil else {
            return .error(400, "Continuity Builder execute mode requires maxCostUSD.")
        }

        let session = await ContinuityBuilderService(store: store).loadOrCreateSession(projectRoot: projectRoot)
        let model = resolvedGeminiModel(from: stringValue(body["model"]))
        let imageSize = stringValue(body["imageSize"]) ?? "1K"
        let aspectRatio = stringValue(body["aspectRatio"]) ?? "4:3"
        let candidateCount = intValue(body["candidateCount"]) ?? intValue(body["count"]) ?? 3
        let maxCostUSD = doubleValue(body["maxCostUSD"]) ?? 0
        let turnID = uuidValue(body["turnID"])

        let result = await ContinuityBuilderGenerationService(store: store).generate(
            .init(
                session: session,
                turnID: turnID,
                projectRoot: projectRoot,
                mode: normalizedMode,
                maxCostUSD: maxCostUSD,
                candidateCount: candidateCount,
                model: model,
                imageSize: imageSize,
                aspectRatio: aspectRatio,
                apiKey: store.geminiAPIKey
            )
        )
        return .okCodable(result)
    }

    private func automationFeedbackRulesExtractResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let body = request.jsonBody() ?? [:]
        let mode = (stringValue(body["mode"]) ?? "dry_run").lowercased()
        guard mode == "dry_run" || mode == "dry-run" || mode == "preview" || mode == "execute" else {
            return .error(400, "Invalid mode: \(mode). Use dry_run or execute.")
        }
        let normalizedMode = mode == "execute" ? "execute" : "dry_run"
        let model = stringValue(body["model"]) ?? "MiniMax-M2.7"
        let writeSidecars = boolValue(body["write"]) ?? true
        let maxSources = intValue(body["maxSources"]) ?? 80

        do {
            let artifact = try await ContinuityRuleExtractionService(store: store).build(
                .init(
                    projectRoot: projectRoot,
                    mode: normalizedMode,
                    model: model,
                    writeSidecars: writeSidecars,
                    apiKey: store.miniMaxAPIKey,
                    maxSources: maxSources
                )
            )
            return .okCodable(artifact)
        } catch {
            return .error(400, error.localizedDescription)
        }
    }

    private func automationFeedbackRulesQueryResponse(_ request: AnimateHTTPRequest) -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let body = request.jsonBody() ?? [:]
        let query = stringValue(body["query"]) ?? ""
        guard !query.isEmpty else {
            return .error(400, "Missing required query.")
        }
        let limit = intValue(body["limit"]) ?? 8
        let clauses = ContinuityRuleExtractionService.relevantPromptClauses(projectRoot: projectRoot, query: query, limit: limit)
        let latest = ContinuityRuleExtractionService.latest(projectRoot: projectRoot)
        return .okJSON([
            "ok": true,
            "query": query,
            "artifactPath": latest?.artifactPath ?? NSNull(),
            "fingerprintCount": latest?.fingerprints.count ?? 0,
            "clauses": clauses
        ])
    }

    private func automationGeneratedFrameGetResponse(sceneID: UUID, shotID: UUID, moment: ImagineShotMoment) -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        guard let record = readFrameRecord(projectRoot: projectRoot, sceneID: sceneID, shotID: shotID, moment: moment) else {
            return .error(404, "No generated-frame record found for \(sceneID.uuidString)/\(shotID.uuidString)/\(moment.directoryName).")
        }
        let recordURL = generatedFrameRecordURL(projectRoot: projectRoot, sceneID: sceneID, shotID: shotID, moment: moment)
        let selectedPath = store.imagineGallery(for: sceneID, shotIndex: record.shotIndex)?.selectedPath(for: moment)
        return .okCodable(AutomationGeneratedFramePayload(
            ok: true,
            recordPath: recordURL.path,
            record: record,
            imageMetadataPath: record.outputPath.map { ImageLibraryMetadataSidecarService.sidecarURL(forImagePath: $0).path },
            selectedFramePath: selectedPath
        ))
    }

    private func automationGeneratedFrameApprovalResponse(
        _ request: AnimateHTTPRequest,
        sceneID: UUID,
        shotID: UUID,
        moment: ImagineShotMoment
    ) -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        guard var record = readFrameRecord(projectRoot: projectRoot, sceneID: sceneID, shotID: shotID, moment: moment) else {
            return .error(404, "No generated-frame record found for \(sceneID.uuidString)/\(shotID.uuidString)/\(moment.directoryName).")
        }

        let body = request.jsonBody() ?? [:]
        let approvalStatus = (stringValue(body["approvalStatus"]) ?? stringValue(body["status"]) ?? "approved")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard ["approved", "rejected", "unapproved", "needs_manual_review"].contains(approvalStatus) else {
            return .error(400, "Invalid approvalStatus: \(approvalStatus). Use approved, rejected, unapproved, or needs_manual_review.")
        }

        let notes = stringValue(body["notes"])
        let syncImageMetadata = boolValue(body["syncImageMetadata"]) ?? true
        let setAsSelectedFrame = boolValue(body["setAsSelectedFrame"]) ?? (approvalStatus == "approved")
        let rating = intValue(body["rating"]).map { min(max($0, 1), 5) }

        if approvalStatus == "approved" {
            guard let outputPath = record.outputPath, FileManager.default.fileExists(atPath: outputPath) else {
                return .error(400, "Cannot approve a generated-frame record without a readable outputPath.")
            }
        }

        record.approvalStatus = approvalStatus
        record.approvalNotes = notes
        record.approvalUpdatedAt = Date()
        record.updatedAt = Date()

        var selectedPath: String?
        var imageMetadataPath: String?
        if let outputPath = record.outputPath {
            if syncImageMetadata {
                var metadata = ImageLibraryMetadataSidecarService.load(forImagePath: outputPath)
                    ?? ImageLibraryReviewMetadata(rating: nil, isRejected: false, notes: "", updatedAt: nil)
                switch approvalStatus {
                case "approved":
                    metadata.isRejected = false
                    metadata.visualStyle = .animated
                    if let rating { metadata.rating = rating }
                case "rejected":
                    metadata.isRejected = true
                    if let rating { metadata.rating = rating }
                default:
                    if let rating { metadata.rating = rating }
                }
                if let notes {
                    metadata.notes = notes
                }
                metadata.updatedAt = Date()
                ImageLibraryMetadataSidecarService.save(metadata, forImagePath: outputPath)
            }
            imageMetadataPath = ImageLibraryMetadataSidecarService.sidecarURL(forImagePath: outputPath).path

            if setAsSelectedFrame || approvalStatus == "rejected" {
                syncImagineSelectedFrame(record: record, moment: moment, outputPath: outputPath, approvalStatus: approvalStatus, setAsSelectedFrame: setAsSelectedFrame)
                selectedPath = store.imagineGallery(for: sceneID, shotIndex: record.shotIndex)?.selectedPath(for: moment)
            }
        }

        do {
            try writeFrameRecord(record, projectRoot: projectRoot)
            let recordURL = generatedFrameRecordURL(projectRoot: projectRoot, sceneID: sceneID, shotID: shotID, moment: moment)
            return .okCodable(AutomationGeneratedFramePayload(
                ok: true,
                recordPath: recordURL.path,
                record: record,
                imageMetadataPath: imageMetadataPath,
                selectedFramePath: selectedPath
            ))
        } catch {
            return .error(500, "Could not write generated-frame approval: \(error.localizedDescription)")
        }
    }

    private func syncImagineSelectedFrame(
        record: GeneratedFrameRecord,
        moment: ImagineShotMoment,
        outputPath: String,
        approvalStatus: String,
        setAsSelectedFrame: Bool
    ) {
        guard let scene = store.scenes.first(where: { $0.id == record.sceneID }),
              record.shotIndex >= 0,
              record.shotIndex < scene.shots.count,
              scene.shots[record.shotIndex].id == record.shotID else { return }
        var galleries = store.imagineSceneGalleries[record.sceneID]
        if galleries == nil || galleries?.count != scene.shots.count {
            galleries = scene.shots.map { ImagineSceneShotGallery(shotID: $0.id, sceneID: scene.id) }
        }
        guard var resolvedGalleries = galleries else { return }
        var gallery = resolvedGalleries[record.shotIndex]
        if !gallery.paths(for: moment).contains(outputPath) {
            gallery.appendPath(outputPath, for: moment)
        }
        if approvalStatus == "approved", setAsSelectedFrame {
            gallery.setSelectedPath(outputPath, for: moment)
        } else if approvalStatus == "rejected", gallery.selectedPath(for: moment) == outputPath {
            gallery.setSelectedPath(nil, for: moment)
        }
        resolvedGalleries[record.shotIndex] = gallery
        store.imagineSceneGalleries[record.sceneID] = resolvedGalleries
        store.saveImagineGalleries()
    }

    private func writeAutomationDryRunReport(_ report: AutomationDryRunReport, projectRoot: URL) throws -> URL {
        let directory = AutomationSourceResolver.automationDirectory(projectRoot: projectRoot, component: "shot-frame-plans")
            .appendingPathComponent("DryRuns", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("automation-frame-plans-latest.json")
        try writeCodable(report, to: url)
        return url
    }

    private func locateShot(shotID: UUID) -> (scene: AnimationScene, shotIndex: Int)? {
        for scene in store.scenes {
            if let index = scene.shots.firstIndex(where: { $0.id == shotID }) {
                return (scene, index)
            }
        }
        return nil
    }

    private func automationShotEffectiveSpecID(from path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "automation", parts[1] == "shots", parts[3] == "effective-shot-spec" else { return nil }
        return UUID(uuidString: parts[2])
    }

    private func automationSceneEffectiveSpecsID(from path: String) -> UUID? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "automation", parts[1] == "scenes", parts[3] == "effective-shot-specs" else { return nil }
        return UUID(uuidString: parts[2])
    }

    private func automationReferenceIDs(from path: String) -> (sceneID: UUID, shotID: UUID)? {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count == 4, parts[0] == "automation", parts[1] == "references",
              let sceneID = UUID(uuidString: parts[2]),
              let shotID = UUID(uuidString: parts[3]) else { return nil }
        return (sceneID, shotID)
    }

    private func automationGeneratedFrameIDs(from path: String) -> (sceneID: UUID, shotID: UUID, moment: ImagineShotMoment, isApproval: Bool)? {
        let parts = path.split(separator: "/").map(String.init)
        guard (parts.count == 5 || parts.count == 6),
              parts[0] == "automation",
              parts[1] == "generated-frames",
              let sceneID = UUID(uuidString: parts[2]),
              let shotID = UUID(uuidString: parts[3]),
              let moment = momentValue(parts[4]) else { return nil }
        if parts.count == 6 {
            guard parts[5] == "approval" else { return nil }
            return (sceneID, shotID, moment, true)
        }
        return (sceneID, shotID, moment, false)
    }

    private func momentValue(_ raw: String) -> ImagineShotMoment? {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "beginning", "begin", "start": return .beginning
        case "middle", "mid": return .middle
        case "end", "ending", "last": return .end
        default: return nil
        }
    }

    private func resolvedMoments(_ raw: Any?) throws -> [ImagineShotMoment] {
        guard let raw, !(raw is NSNull) else { return [.beginning] }
        let values: [String]
        if let string = raw as? String {
            values = string
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else if let strings = raw as? [String] {
            values = strings
        } else {
            throw apiError("moments must be a string or string array.")
        }
        if values.contains(where: { $0.lowercased() == "all" }) {
            return ImagineShotMoment.allCases
        }
        let moments = try values.map { value -> ImagineShotMoment in
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            switch normalized {
            case "beginning", "begin", "start": return .beginning
            case "middle", "mid": return .middle
            case "end", "ending", "last": return .end
            default: throw apiError("Invalid moment: \(value). Use beginning, middle, end, or all.")
            }
        }
        var seen = Set<String>()
        return moments.filter { seen.insert($0.rawValue).inserted }
    }

    private func uuidValue(_ value: Any?) -> UUID? {
        if let uuid = value as? UUID { return uuid }
        if let string = stringValue(value) { return UUID(uuidString: string) }
        return nil
    }

    private struct AutomationReferenceResolvePayload: Codable, Sendable {
        var ok: Bool
        var referenceContractPath: String?
        var referenceContract: ReferenceContract
    }

    private struct AutomationFramePlansDryRunPayload: Codable, Sendable {
        var ok: Bool
        var reportPath: String
        var report: AutomationDryRunReport
    }

    private struct AutomationMiniMaxScaffoldPayload: Codable, Sendable {
        var ok: Bool
        var scaffoldPath: String?
        var scaffold: MiniMaxAutomationScaffoldArtifact
    }

    private struct AutomationGeneratedFramePayload: Codable, Sendable {
        var ok: Bool
        var recordPath: String
        var record: GeneratedFrameRecord
        var imageMetadataPath: String?
        var selectedFramePath: String?
    }


    private struct AutomationContinuityBuilderSessionPayload: Codable, Sendable {
        var ok: Bool
        var session: ContinuityBuilderSession
    }

    private struct AutomationFeedbackRulesExtractPayload: Codable, Sendable {
        var ok: Bool
        var artifactPath: String?
        var artifact: ContinuityRuleExtractionArtifact
    }

    private struct AutomationFeedbackRulesQueryPayload: Codable, Sendable {
        var ok: Bool
        var query: String
        var clauses: [String]
        var latestArtifactPath: String?
        var ruleCount: Int
    }

    // MARK: Image Intelligence API

    private func imageIntelligenceStatusResponse() async -> AnimateHTTPResponse {
        let stats = await store.imageIntelligenceStats()
        let backend = ImageAnalysisBackendStore.currentBackend()
        let queue = await store.imageIntelligenceQueueSnapshot(limit: 20)
        let logs = await store.imageIntelligenceRecentLogs(limit: 10)
        let payload: [String: Any] = [
            "ok": stats != nil,
            "initialized": stats != nil,
            "project": store.owpURL?.path ?? NSNull(),
            "backend": backend.rawValue,
            "backendDisplayName": backend.displayName,
            "aiStudioAPIKeySet": !store.imageAnalysisGeminiAPIKey.isEmpty,
            "vertexProjectID": ImageAnalysisBackendStore.currentVertexProjectID(),
            "vertexRegion": ImageAnalysisBackendStore.currentVertexRegion(),
            "worker": stats.map(workerStatsPayload) ?? NSNull(),
            "recentJobs": queue.map(jobPayload),
            "recentLogs": logs.map(logPayload)
        ]
        return .okJSON(payload)
    }

    private func configureImageIntelligenceResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        guard let body = request.jsonBody() else {
            return .error(400, "Missing or malformed JSON body")
        }

        if let backendRaw = body["backend"] as? String,
           !backendRaw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = backendRaw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let backend = ImageAnalysisBackend(rawValue: normalized) ??
                    ImageAnalysisBackend.allCases.first(where: {
                        $0.displayName.localizedCaseInsensitiveContains(normalized) ||
                        normalized.localizedCaseInsensitiveContains($0.rawValue)
                    }) else {
                return .error(400, "Invalid backend: \(backendRaw) (use 'aiStudio' or 'vertex')")
            }
            ImageAnalysisBackendStore.setBackend(backend)
        }

        let vertexProjectID = stringValue(body["vertexProjectID"])
            ?? stringValue(body["projectID"])
            ?? ImageAnalysisBackendStore.currentVertexProjectID()
        let vertexRegion = stringValue(body["vertexRegion"])
            ?? stringValue(body["region"])
            ?? ImageAnalysisBackendStore.currentVertexRegion()
        ImageAnalysisBackendStore.setVertexSettings(
            projectID: vertexProjectID,
            region: vertexRegion.isEmpty ? "global" : vertexRegion
        )

        if let key = stringValue(body["aiStudioAPIKey"])
            ?? stringValue(body["imageAnalysisGeminiAPIKey"])
            ?? stringValue(body["geminiAPIKey"]) {
            store.setImageAnalysisGeminiAPIKey(key)
        } else {
            store.refreshImageAnalysisConfiguration()
        }

        return await imageIntelligenceStatusResponse()
    }

    private func imageIntelligenceBackfillResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        let body = request.jsonBody() ?? [:]
        let dryRun = boolValue(body["dryRun"]) ?? true
        let maxBatchSize = intValue(body["maxBatchSize"]).flatMap { $0 > 0 ? $0 : nil }
        let forceReanalysis = boolValue(body["forceReanalysis"]) ?? false
        let enqueueExistingWithoutRuns = boolValue(body["enqueueExistingWithoutRuns"]) ?? true
        let enqueueExistingMissingAnalysis = boolValue(body["enqueueExistingMissingAnalysis"]) ?? false
        let markMissingAssets = boolValue(body["markMissingAssets"]) ?? true
        let startWorker = boolValue(body["startWorker"]) ?? false

        let linkKinds: [ImageAssetLinkKind]?
        do {
            linkKinds = try parseLinkKinds(from: body["linkKinds"])
        } catch {
            return .error(400, error.localizedDescription)
        }

        guard let report = await store.imageIntelligenceBackfillReport(
            dryRun: dryRun,
            maxBatchSize: maxBatchSize,
            forceReanalysis: forceReanalysis,
            linkKinds: linkKinds,
            enqueueExistingWithoutRuns: enqueueExistingWithoutRuns,
            enqueueExistingMissingAnalysis: enqueueExistingMissingAnalysis,
            markMissingAssets: markMissingAssets
        ) else {
            return .error(500, "Image intelligence is not initialized for this project yet.")
        }

        if startWorker && !dryRun {
            store.startImageAnalysisWorker()
        }

        let stats = await store.imageIntelligenceStats()
        let payload: [String: Any] = [
            "ok": true,
            "report": backfillReportPayload(report),
            "workerStarted": startWorker && !dryRun,
            "worker": stats.map(workerStatsPayload) ?? NSNull()
        ]
        return .okJSON(payload)
    }

    private func imageIntelligenceWorkerResponse(shouldStart: Bool) async -> AnimateHTTPResponse {
        if shouldStart {
            store.startImageAnalysisWorker()
        } else {
            store.stopImageAnalysisWorker()
        }
        try? await Task.sleep(for: .milliseconds(100))
        return await imageIntelligenceStatusResponse()
    }

    private func imageIntelligenceQueueResetResponse() async -> AnimateHTTPResponse {
        let message = await store.resetImageAnalysisQueue()
        let stats = await store.imageIntelligenceStats()
        return .okJSON([
            "ok": true,
            "message": message,
            "worker": stats.map(workerStatsPayload) ?? NSNull()
        ])
    }

    private func imageIntelligenceJobsResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        let limit = max(1, min(500, intValue(request.queryParams["limit"]) ?? 100))
        let jobs = await store.imageIntelligenceQueueSnapshot(limit: limit)
        return .okJSON([
            "ok": true,
            "limit": limit,
            "jobs": jobs.map(jobPayload)
        ])
    }

    private func imageIntelligenceLogsResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        let limit = max(1, min(500, intValue(request.queryParams["limit"]) ?? 100))
        let logs = await store.imageIntelligenceRecentLogs(limit: limit)
        return .okJSON([
            "ok": true,
            "limit": limit,
            "logs": logs.map(logPayload)
        ])
    }

    private func imageIntelligenceAssetResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        guard let path = request.queryParams["path"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return .error(400, "Missing required query parameter: path")
        }

        guard let record = await store.imageIntelligenceRecord(for: path) else {
            return .error(404, "No image intelligence asset is registered for path: \(path)")
        }

        async let jobs = store.imageIntelligenceJobs(for: record.resolvedPath)
        async let runs = store.imageIntelligenceRuns(for: record.resolvedPath)
        async let metadata = store.imageIntelligenceLatestMetadata(for: record.resolvedPath)
        let resolvedJobs = await jobs
        let resolvedRuns = await runs
        let resolvedMetadata = await metadata

        return .okJSON([
            "ok": true,
            "asset": assetPayload(record),
            "jobs": resolvedJobs.map(jobPayload),
            "runs": resolvedRuns.map(runPayload),
            "latestMetadata": resolvedMetadata.map(metadataPayload) ?? NSNull()
        ])
    }

    // MARK: Shot-frame / Vertex agent API

    private func shotFrameDryRunResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let body = request.jsonBody() ?? [:]
        let model = resolvedGeminiModel(from: stringValue(body["model"]))
        let imageSize = stringValue(body["imageSize"])
            ?? ShotFrameOpenMattePlan.defaultGeneratedImageSize

        do {
            let sceneFilter = try resolvedSceneFilter(stringValue(body["scene"]))
            let planner = ShotFrameGenerationDryRunPlanner(store: store)
            let report = await planner.buildReport(
                scenes: store.scenes,
                projectRoot: projectRoot,
                sceneFilter: sceneFilter,
                model: model,
                imageSize: imageSize
            )
            let reportURL = try await planner.writeReportAsync(report, projectRoot: projectRoot)
            return .okJSON([
                "ok": true,
                "reportURL": reportURL.path,
                "model": report.model.rawValue,
                "modelDisplayName": report.model.displayName,
                "imageSize": report.imageSize,
                "summary": dryRunSummaryPayload(report.summary)
            ])
        } catch {
            return .error(400, error.localizedDescription)
        }
    }

    private func vertexImageSmokeResponse(_ request: AnimateHTTPRequest) async -> AnimateHTTPResponse {
        guard let projectRoot = store.fileOWPURL else {
            return .error(400, "No project is loaded.")
        }
        let body = request.jsonBody() ?? [:]
        let model = resolvedGeminiModel(from: stringValue(body["model"]))
        let imageSize = stringValue(body["imageSize"])
            ?? ShotFrameOpenMattePlan.defaultGeneratedImageSize
        let aspectRatio = stringValue(body["aspectRatio"])
            ?? ShotFrameOpenMattePlan.defaultGeneratedAspectRatio
        let maxSpendUSD = doubleValue(body["maxSpendUSD"]) ?? 1.0
        let estimatedCost = model.estimatedCost(for: imageSize)
        guard estimatedCost <= maxSpendUSD else {
            return .error(400, "Estimated Vertex cost $\(String(format: "%.4f", estimatedCost)) exceeds cap $\(String(format: "%.2f", maxSpendUSD)).")
        }

        let projectID = firstNonEmpty(
            stringValue(body["vertexProjectID"]),
            stringValue(body["projectID"]),
            ProjectCredentialStore.shared.vertexProjectID(),
            ImageGenBackendStore.currentVertexSettings().projectID
        )
        let region = firstNonEmpty(
            stringValue(body["vertexRegion"]),
            stringValue(body["region"]),
            ProjectCredentialStore.shared.vertexRegion(),
            ImageGenBackendStore.currentVertexSettings().region,
            "global"
        ) ?? "global"
        guard let projectID, !projectID.isEmpty else {
            return .error(400, "Missing Vertex project ID. Set it in Gemini Settings or pass vertexProjectID.")
        }

        let directory = ProjectPaths(root: projectRoot)
            .animate
            .appendingPathComponent("Imagine/VertexSmokeTests", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .error(500, "Could not create smoke-test directory: \(error.localizedDescription)")
        }

        let timestamp = Int(Date().timeIntervalSince1970)
        let stem = "vertex_api_smoke_\(timestamp)_\(model.rawValue)_\(imageSize)_\(aspectRatio.replacingOccurrences(of: ":", with: "x"))"
        var smokeRecord = VertexImageSmokeTestRecord(
            id: UUID(),
            startedAt: Date(),
            status: "running",
            model: model.rawValue,
            imageSize: imageSize,
            aspectRatio: aspectRatio,
            estimatedVertexCostUSD: estimatedCost,
            chargedEstimatedCostUSD: 0,
            maxSpendUSD: maxSpendUSD,
            projectID: projectID,
            region: region
        )

        do {
            try Self.writeVertexImageSmokeTestRecord(smokeRecord, directory: directory, stem: stem)

            let previousBackend = ImageGenBackendStore.currentBackend()
            let previousVertexSettings = ImageGenBackendStore.currentVertexSettings()
            ImageGenBackendStore.setBackend(.vertex)
            ImageGenBackendStore.setVertexSettings(VertexSettings(projectID: projectID, region: region))
            defer {
                ImageGenBackendStore.setBackend(previousBackend)
                ImageGenBackendStore.setVertexSettings(previousVertexSettings)
            }

            let prompt = [
                "Generate one safe open-matte pipeline smoke-test image.",
                "Subject: a cinematic alpine valley at sunrise with a river, distant mountains, and no people.",
                "Composition: \(aspectRatio) open-matte source plate, extra clean environment around all edges, no captions, no text, no logos.",
                "This is a technical validation frame for crop-controlled camera movement."
            ].joined(separator: " ")

            let result = try await GeminiImageService().generate(
                request: GeminiImageService.GenerationRequest(
                    prompt: prompt,
                    model: model,
                    aspectRatio: aspectRatio,
                    imageSize: imageSize
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

            return .okJSON([
                "ok": true,
                "record": smokeRecordPayload(smokeRecord),
                "recordURL": directory.appendingPathComponent("\(stem).json").path,
                "latestRecordURL": directory.appendingPathComponent("vertex_smoke_latest.json").path
            ])
        } catch {
            smokeRecord.status = "failed"
            smokeRecord.finishedAt = Date()
            smokeRecord.errorMessage = error.localizedDescription
            smokeRecord.chargedEstimatedCostUSD = 0
            try? Self.writeVertexImageSmokeTestRecord(smokeRecord, directory: directory, stem: stem)
            return .error(500, "Vertex image smoke test failed: \(error.localizedDescription)")
        }
    }

    // MARK: Response payload helpers

    private func workerStatsPayload(_ stats: ImageAnalysisCoordinator.WorkerStats) -> [String: Any] {
        [
            "totalJobs": stats.totalJobs,
            "pendingJobs": stats.pendingJobs,
            "runningJobs": stats.runningJobs,
            "completedJobs": stats.completedJobs,
            "failedJobs": stats.failedJobs,
            "isRunning": stats.isRunning
        ]
    }

    private func backfillReportPayload(_ report: ImageAnalysisBackfillService.BackfillReport) -> [String: Any] {
        [
            "totalDiscovered": report.totalDiscovered,
            "alreadyRegistered": report.alreadyRegistered,
            "newlyRegistered": report.newlyRegistered,
            "missingAssets": report.missingAssets,
            "queuedForAnalysis": report.queuedForAnalysis,
            "errors": report.errors,
            "errorCount": report.errors.count,
            "isDryRun": report.isDryRun,
            "summary": report.summary
        ]
    }

    private func jobPayload(_ job: ImageAnalysisCoordinator.JobRecord) -> [String: Any] {
        [
            "id": job.id,
            "imageAssetID": job.imageAssetID,
            "status": job.status.rawValue,
            "reason": job.reason,
            "attemptCount": job.attemptCount,
            "maxAttempts": job.maxAttempts,
            "lastError": job.lastError ?? NSNull(),
            "createdAt": isoString(job.createdAt),
            "updatedAt": isoString(job.updatedAt)
        ]
    }

    private func logPayload(_ log: ImageAnalysisCoordinator.LogEntry) -> [String: Any] {
        [
            "timestamp": isoString(log.timestamp),
            "message": log.message
        ]
    }

    private func assetPayload(_ asset: ImageAssetRecord) -> [String: Any] {
        [
            "id": asset.id,
            "resolvedPath": asset.resolvedPath,
            "projectRelativePath": asset.projectRelativePath ?? NSNull(),
            "filename": asset.filename ?? NSNull(),
            "mimeType": asset.mimeType ?? NSNull(),
            "width": asset.width ?? NSNull(),
            "height": asset.height ?? NSNull(),
            "aspectRatio": asset.aspectRatio ?? NSNull(),
            "fileSizeBytes": asset.fileSizeBytes ?? NSNull(),
            "contentHashSHA256": asset.contentHashSHA256 ?? NSNull(),
            "isMissing": asset.isMissing,
            "createdAt": isoString(asset.createdAt),
            "updatedAt": isoString(asset.updatedAt),
            "lastSeenAt": isoString(asset.lastSeenAt)
        ]
    }

    private func runPayload(_ run: ImageAnalysisRunRecord) -> [String: Any] {
        [
            "id": run.id,
            "imageAssetID": run.imageAssetID,
            "reason": run.reason ?? NSNull(),
            "status": run.status,
            "startedAt": run.startedAt.map(isoString) ?? NSNull(),
            "completedAt": run.completedAt.map(isoString) ?? NSNull(),
            "errorCode": run.errorCode ?? NSNull(),
            "errorMessage": run.errorMessage ?? NSNull(),
            "createdAt": isoString(run.createdAt),
            "updatedAt": isoString(run.updatedAt)
        ]
    }

    private func metadataPayload(_ metadata: ImageVisualMetadataRecord) -> [String: Any] {
        [
            "id": metadata.id,
            "imageAssetID": metadata.imageAssetID,
            "analysisRunID": metadata.analysisRunID ?? NSNull(),
            "summary": metadata.summary ?? NSNull(),
            "shortCaption": metadata.shortCaption ?? NSNull(),
            "longCaption": metadata.longCaption ?? NSNull(),
            "assetRolesJSON": metadata.assetRolesJSON ?? NSNull(),
            "entitiesJSON": metadata.entitiesJSON ?? NSNull(),
            "sceneJSON": metadata.sceneJSON ?? NSNull(),
            "cameraJSON": metadata.cameraJSON ?? NSNull(),
            "styleJSON": metadata.styleJSON ?? NSNull(),
            "qualityJSON": metadata.qualityJSON ?? NSNull(),
            "retrievalJSON": metadata.retrievalJSON ?? NSNull(),
            "confidenceJSON": metadata.confidenceJSON ?? NSNull(),
            "rawModelJSON": metadata.rawModelJSON ?? NSNull(),
            "modelID": metadata.modelID ?? NSNull(),
            "createdAt": isoString(metadata.createdAt),
            "updatedAt": isoString(metadata.updatedAt)
        ]
    }

    private func dryRunSummaryPayload(_ summary: ShotFrameGenerationDryRunSummary) -> [String: Any] {
        [
            "totalFrames": summary.totalFrames,
            "generateFrames": summary.generateFrames,
            "editFrames": summary.editFrames,
            "executableFrames": summary.executableFrames,
            "missingSourceFallbackFrames": summary.missingSourceFallbackFrames,
            "automaticReferenceCount": summary.automaticReferenceCount,
            "openMatteFrames": summary.openMatteFrames,
            "estimatedVertexCostUSD": summary.estimatedVertexCostUSD
        ]
    }

    private func smokeRecordPayload(_ record: VertexImageSmokeTestRecord) -> [String: Any] {
        [
            "id": record.id.uuidString,
            "startedAt": isoString(record.startedAt),
            "finishedAt": record.finishedAt.map(isoString) ?? NSNull(),
            "status": record.status,
            "model": record.model,
            "imageSize": record.imageSize,
            "aspectRatio": record.aspectRatio,
            "estimatedVertexCostUSD": record.estimatedVertexCostUSD,
            "chargedEstimatedCostUSD": record.chargedEstimatedCostUSD,
            "maxSpendUSD": record.maxSpendUSD,
            "projectID": record.projectID,
            "region": record.region,
            "imageURL": record.imageURL ?? NSNull(),
            "promptURL": record.promptURL ?? NSNull(),
            "responseURL": record.responseURL ?? NSNull(),
            "errorMessage": record.errorMessage ?? NSNull()
        ]
    }

    // MARK: Parsing helpers

    private func parseLinkKinds(from raw: Any?) throws -> [ImageAssetLinkKind]? {
        let values: [String]
        if raw == nil || raw is NSNull {
            return nil
        } else if let strings = raw as? [String] {
            values = strings
        } else if let string = raw as? String {
            values = string
                .split(separator: ",")
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        } else {
            throw apiError("linkKinds must be a string array or comma-separated string.")
        }

        var kinds: [ImageAssetLinkKind] = []
        for value in values {
            guard let kind = ImageAssetLinkKind(rawValue: value) else {
                throw apiError("Invalid link kind: \(value).")
            }
            kinds.append(kind)
        }
        return kinds.isEmpty ? nil : kinds
    }

    private func resolvedGeminiModel(from raw: String?) -> GeminiModel {
        let normalized = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if normalized == "pro" || normalized.contains("pro") {
            return .pro
        }
        if normalized == "flash" ||
            normalized.contains("banana-2") ||
            normalized.contains("banana_2") ||
            normalized.contains("nanobanana2") ||
            normalized.contains("nano banana 2") {
            return .flash
        }
        return raw.flatMap(GeminiModel.init(rawValue:)) ?? .flash
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
        throw apiError("No scene matched '\(raw)'.")
    }

    private func firstNonEmpty(_ values: String?...) -> String? {
        values
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        return nil
    }

    private func intValue(_ value: Any?) -> Int? {
        if let int = value as? Int { return int }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double { return double }
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }

    private func boolValue(_ value: Any?) -> Bool? {
        if let bool = value as? Bool { return bool }
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String {
            switch string.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "true", "yes", "1", "on": return true
            case "false", "no", "0", "off": return false
            default: return nil
            }
        }
        return nil
    }

    private func isoString(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private func apiError(_ message: String) -> NSError {
        NSError(domain: "AnimateAPIRouter", code: 1, userInfo: [
            NSLocalizedDescriptionKey: message
        ])
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

    // MARK: - 3D map regeneration

    /// POST /map3d/regenerate — kicks off the 6-phase pipeline at
    /// `Scripts/3d-map-pipeline/run_all.sh` if no job is in flight. Returns
    /// 202 Accepted with the job_id, or 409 Conflict if a job is already
    /// running. The work proceeds asynchronously; clients poll
    /// `GET /map3d/regenerate/status` for progress.
    private func map3DRegenerateResponse() -> AnimateHTTPResponse {
        let snapshotBefore = Map3DPipelineRunner.shared.snapshot()
        if snapshotBefore.state == .running {
            var payload = encodeMap3DSnapshot(snapshotBefore)
            payload["error"] = "A 3D map regeneration is already in flight."
            return AnimateHTTPResponse(
                status: 409,
                body: jsonString(payload) ?? #"{"error":"already running"}"#
            )
        }
        let result = Map3DPipelineRunner.shared.start()
        let snapshot = Map3DPipelineRunner.shared.snapshot()
        var payload = encodeMap3DSnapshot(snapshot)
        payload["accepted"] = result.started
        return AnimateHTTPResponse(
            status: 202,
            body: jsonString(payload) ?? #"{"error":"failed to encode response"}"#
        )
    }

    /// GET /map3d/regenerate/status — returns the current pipeline runner
    /// snapshot. Always 200 even when no job has ever run (state="idle").
    private func map3DRegenerateStatusResponse() -> AnimateHTTPResponse {
        let snapshot = Map3DPipelineRunner.shared.snapshot()
        return AnimateHTTPResponse.okJSON(encodeMap3DSnapshot(snapshot))
    }

    private func encodeMap3DSnapshot(_ snapshot: Map3DPipelineRunner.Snapshot) -> [String: Any] {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var payload: [String: Any] = [
            "state": snapshot.state.rawValue,
            "tail_log": snapshot.tailLog
        ]
        if let id = snapshot.jobId {
            payload["job_id"] = id.uuidString
        }
        if let phase = snapshot.currentPhase {
            payload["current_phase"] = phase
        }
        if let started = snapshot.startedAt {
            payload["started_at"] = iso.string(from: started)
        }
        if let finished = snapshot.finishedAt {
            payload["finished_at"] = iso.string(from: finished)
        }
        if let error = snapshot.errorMessage {
            payload["error"] = error
        }
        return payload
    }

    private func jsonString(_ payload: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json
    }
}

// MARK: - AnimateHTTPRequest

struct AnimateHTTPRequest {
    var method: String
    var path: String
    var queryParams: [String: String]
    var headers: [String: String]
    var body: Data?

    static func parse(_ data: Data) -> AnimateHTTPRequest? {
        let separator: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
        guard let separatorRange = data.range(of: Data(separator)) else { return nil }

        let headerData = data[data.startIndex..<separatorRange.lowerBound]
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerString.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        let requestLine = lines[0].split(separator: " ", maxSplits: 2)
        guard requestLine.count >= 2 else { return nil }

        let method = String(requestLine[0])
        let rawPath = String(requestLine[1])

        let pathParts = rawPath.split(separator: "?", maxSplits: 1)
        let path = String(pathParts[0])
        var queryParams: [String: String] = [:]
        if pathParts.count > 1 {
            let queryString = String(pathParts[1])
            for pair in queryString.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                if kv.count == 2 {
                    let key = String(kv[0]).replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? String(kv[0])
                    let value = String(kv[1]).replacingOccurrences(of: "+", with: " ")
                        .removingPercentEncoding ?? String(kv[1])
                    queryParams[key] = value
                }
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let headerParts = line.split(separator: ":", maxSplits: 1)
            if headerParts.count == 2 {
                let key = String(headerParts[0]).trimmingCharacters(in: .whitespaces).lowercased()
                let value = String(headerParts[1]).trimmingCharacters(in: .whitespaces)
                headers[key] = value
            }
        }

        let bodyStart = separatorRange.upperBound
        let availableBody = data[bodyStart...]

        if let contentLengthStr = headers["content-length"],
           let contentLength = Int(contentLengthStr), contentLength >= 0 {
            guard availableBody.count >= contentLength else { return nil }
            let body = availableBody.prefix(contentLength)
            return AnimateHTTPRequest(method: method, path: path, queryParams: queryParams,
                                      headers: headers,
                                      body: body.isEmpty ? nil : Data(body))
        } else {
            let body = Data(availableBody)
            return AnimateHTTPRequest(method: method, path: path, queryParams: queryParams,
                                      headers: headers,
                                      body: body.isEmpty ? nil : body)
        }
    }

    func jsonBody() -> [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

// MARK: - AnimateHTTPResponse

struct AnimateHTTPResponse {
    var status: Int
    var headers: [String: String] = ["Content-Type": "application/json; charset=utf-8"]
    var body: String

    static func okJSON(_ dict: [String: Any]) -> AnimateHTTPResponse {
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            return AnimateHTTPResponse(status: 200, body: json)
        }
        return AnimateHTTPResponse(status: 500, body: #"{"error":"failed to encode response"}"#)
    }

    static func okCodable<T: Encodable>(_ value: T) -> AnimateHTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(value),
           let json = String(data: data, encoding: .utf8) {
            return AnimateHTTPResponse(status: 200, body: json)
        }
        return AnimateHTTPResponse(status: 500, body: #"{"error":"failed to encode response"}"#)
    }

    static func error(_ status: Int, _ message: String) -> AnimateHTTPResponse {
        let payload = ["error": message]
        if let data = try? JSONEncoder().encode(payload),
           let json = String(data: data, encoding: .utf8) {
            return AnimateHTTPResponse(status: status, body: json)
        }
        return AnimateHTTPResponse(status: status, body: #"{"error":"internal error"}"#)
    }

    func serialize() -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 202: statusText = "Accepted"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 409: statusText = "Conflict"
        case 413: statusText = "Payload Too Large"
        case 500: statusText = "Internal Server Error"
        default: statusText = "Error"
        }

        let bodyData = body.data(using: .utf8) ?? Data()
        var allHeaders = headers
        allHeaders["Content-Length"] = "\(bodyData.count)"
        allHeaders["Access-Control-Allow-Origin"] = "http://127.0.0.1"
        allHeaders["Connection"] = "close"

        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        for (key, value) in allHeaders.sorted(by: { $0.key < $1.key }) {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        var data = response.data(using: .utf8) ?? Data()
        data.append(bodyData)
        return data
    }
}
