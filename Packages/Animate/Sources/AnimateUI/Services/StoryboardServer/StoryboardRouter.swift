import Foundation
import ProjectKit

// MARK: - StoryboardRouter
//
// HTTP/1.1 router for the storyboard web API. Accepts a weak reference to
// AnimateWorkspaceController so the router never extends the controller's
// lifetime. All route handlers run on @MainActor (called from processRequest).

@available(macOS 26.0, *)
@MainActor
final class StoryboardRouter {

    private weak var workspace: AnimateWorkspaceController?
    private let diskStore = StoryboardStore()

    init(workspace: AnimateWorkspaceController) {
        self.workspace = workspace
    }

    func updateWorkspace(_ workspace: AnimateWorkspaceController) {
        self.workspace = workspace
    }

    func handle(_ request: SBHTTPRequest) async -> SBHTTPResponse {
        let method = request.method
        let path = request.path

        // Static asset routes
        if method == "GET", let (data, mime) = StoryboardAssets.serve(path: path) {
            return SBHTTPResponse(status: 200, contentType: mime, body: data)
        }

        // API routes
        switch (method, path) {
        case ("GET", "/api/project"):
            return projectResponse()
        case ("GET", "/api/shots"):
            return shotsResponse()
        case ("GET", "/api/places"):
            return placesResponse()
        case ("GET", "/api/landmarks"):
            return landmarksResponse()
        case ("POST", "/api/shots"):
            return await postShotResponse(sceneIDStr: nil, request: request)
        case ("POST", "/api/shots/reorder"):
            return await reorderShotsResponse(request: request)
        case ("POST", "/api/places"):
            return await postPlaceResponse(request: request)
        case ("POST", "/api/landmarks"):
            return await postLandmarkResponse(request: request)
        case _ where method == "POST" && path.hasPrefix("/api/scenes/") && path.hasSuffix("/shots"):
            let sceneIDStr = extractPathComponent(from: path, prefix: "/api/scenes/", suffix: "/shots")
            return await postShotResponse(sceneIDStr: sceneIDStr, request: request)
        case _ where method == "PUT" && path.hasPrefix("/api/shots/") && path.hasSuffix("/summary"):
            let shotIDStr = extractPathComponent(from: path, prefix: "/api/shots/", suffix: "/summary")
            return await putSummaryResponse(shotIDStr: shotIDStr, request: request)
        case _ where method == "GET" && path.hasPrefix("/api/scenes/") && path.contains("/storyboard/"):
            guard let scoped = parseSceneScopedStoryboardPath(path) else {
                return .badRequest("Malformed scene storyboard path")
            }
            return getStoryboardResponse(
                sceneIDStr: scoped.sceneID,
                shotIDStr: scoped.shotID,
                frameStr: scoped.frame
            )
        case _ where method == "PUT" && path.hasPrefix("/api/scenes/") && path.contains("/storyboard/"):
            guard let scoped = parseSceneScopedStoryboardPath(path) else {
                return .badRequest("Malformed scene storyboard path")
            }
            return await putStoryboardResponse(
                sceneIDStr: scoped.sceneID,
                shotIDStr: scoped.shotID,
                frameStr: scoped.frame,
                request: request
            )
        case _ where method == "GET" && path.hasPrefix("/api/storyboard/"):
            let parts = path.dropFirst("/api/storyboard/".count).split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return .badRequest("Malformed storyboard path") }
            return getStoryboardResponse(shotIDStr: String(parts[0]), frameStr: String(parts[1]))
        case _ where method == "PUT" && path.hasPrefix("/api/storyboard/"):
            let parts = path.dropFirst("/api/storyboard/".count).split(separator: "/", maxSplits: 1)
            guard parts.count == 2 else { return .badRequest("Malformed storyboard path") }
            return await putStoryboardResponse(shotIDStr: String(parts[0]), frameStr: String(parts[1]), request: request)
        case _ where method == "GET" && path.hasPrefix("/api/places/") && path.hasSuffix("/sketch"):
            let placeIDStr = extractPathComponent(from: path, prefix: "/api/places/", suffix: "/sketch")
            return getPlaceSketchResponse(placeIDStr: placeIDStr)
        case _ where method == "PUT" && path.hasPrefix("/api/places/") && path.hasSuffix("/sketch"):
            let placeIDStr = extractPathComponent(from: path, prefix: "/api/places/", suffix: "/sketch")
            return await putPlaceSketchResponse(placeIDStr: placeIDStr, request: request)
        case _ where method == "GET" && path.hasPrefix("/api/landmarks/") && path.hasSuffix("/sketch"):
            let landmarkIDStr = extractPathComponent(from: path, prefix: "/api/landmarks/", suffix: "/sketch")
            return getLandmarkSketchResponse(landmarkIDStr: landmarkIDStr)
        case _ where method == "PUT" && path.hasPrefix("/api/landmarks/") && path.hasSuffix("/sketch"):
            let landmarkIDStr = extractPathComponent(from: path, prefix: "/api/landmarks/", suffix: "/sketch")
            return await putLandmarkSketchResponse(landmarkIDStr: landmarkIDStr, request: request)
        case ("OPTIONS", _):
            return SBHTTPResponse(status: 204, contentType: "text/plain", body: Data())
        default:
            return .notFound("Unknown route: \(method) \(path)")
        }
    }

    // MARK: - Route Handlers

    private func projectResponse() -> SBHTTPResponse {
        guard let ws = workspace, let root = projectRoot(ws) else {
            return .serviceUnavailable("no project open")
        }
        let projectName = root.lastPathComponent
        let projectID = projectName
        return .okJSON(["name": projectName, "id": projectID])
    }

    private func shotsResponse() -> SBHTTPResponse {
        guard let ws = workspace, let root = projectRoot(ws) else {
            return .serviceUnavailable("no project open")
        }
        var payload = shotEntries(projectRoot: root, scenes: ws.store.scenes)
        payload.sort {
            let s0 = $0["sceneOrder"] as? Int ?? 0
            let s1 = $1["sceneOrder"] as? Int ?? 0
            if s0 != s1 { return s0 < s1 }
            return ($0["shotOrder"] as? Int ?? 0) < ($1["shotOrder"] as? Int ?? 0)
        }
        return .okJSONArray(payload)
    }

    private func placesResponse() -> SBHTTPResponse {
        guard let ws = workspace, projectRoot(ws) != nil else {
            return .serviceUnavailable("no project open")
        }
        return .okJSONArray(ws.store.storyboardPlaceEntries())
    }

    private func landmarksResponse() -> SBHTTPResponse {
        guard let ws = workspace, projectRoot(ws) != nil else {
            return .serviceUnavailable("no project open")
        }
        return .okJSONArray(ws.store.storyboardLandmarkEntries())
    }

    private func postShotResponse(sceneIDStr: String?, request: SBHTTPRequest) async -> SBHTTPResponse {
        guard let ws = workspace, let root = projectRoot(ws) else {
            return .serviceUnavailable("no project open")
        }

        let explicitSceneID = sceneIDStr.flatMap(UUID.init(uuidString:))
        if sceneIDStr != nil, explicitSceneID == nil {
            return .badRequest("Invalid sceneId")
        }

        let body: [String: Any]?
        if let requestBody = request.body, !requestBody.isEmpty {
            guard let parsedBody = request.jsonBody() else {
                return .badRequest("Invalid JSON body")
            }
            body = parsedBody
        } else {
            body = nil
        }
        let bodySceneID: UUID?
        if let bodySceneIDString = body?["sceneId"] as? String {
            guard let parsedBodySceneID = UUID(uuidString: bodySceneIDString) else {
                return .badRequest("Invalid sceneId")
            }
            bodySceneID = parsedBodySceneID
        } else {
            bodySceneID = nil
        }
        let requestedSceneID = explicitSceneID ?? bodySceneID
        let title = body?["title"] as? String

        guard let created = ws.store.appendStoryboardShot(sceneID: requestedSceneID, title: title) else {
            return .serviceUnavailable("no scene selected")
        }

        await MainActor.run {
            StoryboardServerStatusModel.shared.recordIPadSave("Added shot")
        }
        let sceneOrder = ws.store.scenes.firstIndex(where: { $0.id == created.sceneID }) ?? 0

        let shot = created.shot
        let response: [String: Any] = [
            "sceneId": created.sceneID.uuidString,
            "sceneName": created.sceneName,
            "sceneOrder": sceneOrder,
            "shotId": shot.id.uuidString,
            "shotName": shot.name,
            "shotOrder": created.shotOrder,
            "startFrame": shot.startFrame,
            "summary": shot.notes,
            "hasFrames": diskStore.hasFrames(projectRoot: root, sceneID: created.sceneID, shotID: shot.id),
            "hasAnalysis": diskStore.hasAnalysisSidecars(projectRoot: root, sceneID: created.sceneID, shotID: shot.id)
        ]
        return SBHTTPResponse(
            status: 201,
            contentType: "application/json; charset=utf-8",
            body: (try? JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])) ?? Data()
        )
    }

    private func reorderShotsResponse(request: SBHTTPRequest) async -> SBHTTPResponse {
        guard let ws = workspace, projectRoot(ws) != nil else {
            return .serviceUnavailable("no project open")
        }
        guard let body = request.jsonBody() else {
            return .badRequest("Invalid JSON body")
        }
        guard let sceneIDString = body["sceneId"] as? String,
              let sceneID = UUID(uuidString: sceneIDString) else {
            return .badRequest("Missing or invalid sceneId")
        }
        guard let rawShotIDs = body["shotIds"] as? [String] else {
            return .badRequest("Missing shotIds array")
        }
        let shotIDs = rawShotIDs.compactMap { UUID(uuidString: $0) }
        guard shotIDs.count == rawShotIDs.count else {
            return .badRequest("Invalid shot UUID in shotIds")
        }

        let ok = ws.store.reorderSceneShots(sceneID: sceneID, shotIDs: shotIDs)
        guard ok else {
            return .badRequest("shotIds must be a permutation of the scene's existing shot IDs")
        }
        await MainActor.run {
            StoryboardServerStatusModel.shared.recordIPadSave("Reordered shots")
        }
        return SBHTTPResponse(status: 204, contentType: "application/json", body: Data())
    }

    private func postPlaceResponse(request: SBHTTPRequest) async -> SBHTTPResponse {
        guard let ws = workspace, projectRoot(ws) != nil else {
            return .serviceUnavailable("no project open")
        }
        let body = request.jsonBody()
        let name = (body?["name"] as? String) ?? "New Place"
        let created = ws.store.createStoryboardPlace(name: name)
        await MainActor.run {
            StoryboardServerStatusModel.shared.recordIPadSave("Added place")
        }
        return SBHTTPResponse(
            status: 201,
            contentType: "application/json; charset=utf-8",
            body: (try? JSONSerialization.data(withJSONObject: [
                "id": created.id.uuidString,
                "name": created.name
            ], options: [.sortedKeys])) ?? Data()
        )
    }

    private func postLandmarkResponse(request: SBHTTPRequest) async -> SBHTTPResponse {
        guard let ws = workspace, projectRoot(ws) != nil else {
            return .serviceUnavailable("no project open")
        }
        let body = request.jsonBody()
        let title = (body?["title"] as? String) ?? "New Landmark"
        let created = ws.store.createStoryboardLandmark(title: title)
        await MainActor.run {
            StoryboardServerStatusModel.shared.recordIPadSave("Added landmark")
        }
        return SBHTTPResponse(
            status: 201,
            contentType: "application/json; charset=utf-8",
            body: (try? JSONSerialization.data(withJSONObject: [
                "id": created.id.uuidString,
                "title": created.title
            ], options: [.sortedKeys])) ?? Data()
        )
    }

    private func shotEntries(projectRoot root: URL, scenes: [AnimationScene]) -> [[String: Any]] {
        var payload: [[String: Any]] = []
        for (sceneOrder, scene) in scenes.enumerated() {
            for (shotOrder, shot) in scene.shots.enumerated() {
                payload.append(shotEntry(
                    projectRoot: root,
                    scene: scene,
                    sceneOrder: sceneOrder,
                    shot: shot,
                    shotOrder: shotOrder
                ))
            }
        }
        return payload
    }

    private func shotEntry(
        projectRoot root: URL,
        scene: AnimationScene,
        sceneOrder: Int,
        shot: AnimationSceneShot,
        shotOrder: Int
    ) -> [String: Any] {
        let has = diskStore.hasFrames(projectRoot: root, sceneID: scene.id, shotID: shot.id)
        let hasAnalysis = diskStore.hasAnalysisSidecars(projectRoot: root, sceneID: scene.id, shotID: shot.id)
        return [
            "sceneId": scene.id.uuidString,
            "sceneName": scene.name,
            "sceneOrder": sceneOrder,
            "shotId": shot.id.uuidString,
            "shotName": shot.name,
            "shotOrder": shotOrder,
            "startFrame": shot.startFrame,
            "summary": shot.notes,
            "hasFrames": has,
            "hasAnalysis": hasAnalysis
        ]
    }

    private func putSummaryResponse(shotIDStr: String?, request: SBHTTPRequest) async -> SBHTTPResponse {
        guard let shotIDStr, let shotID = UUID(uuidString: shotIDStr) else {
            return .badRequest("Invalid shotId")
        }
        guard let body = request.jsonBody(), let summary = body["summary"] as? String else {
            return .badRequest("Missing 'summary' field in JSON body")
        }
        guard let ws = workspace else { return .serviceUnavailable("no project open") }

        let found = ws.store.updateShotNotes(shotID: shotID, notes: summary)
        guard found else { return .notFound("Shot not found: \(shotIDStr)") }
        await MainActor.run {
            StoryboardServerStatusModel.shared.recordIPadSave("Shot summary")
        }
        return SBHTTPResponse(status: 204, contentType: "application/json", body: Data())
    }

    private func getPlaceSketchResponse(placeIDStr: String?) -> SBHTTPResponse {
        guard let placeIDStr, let placeID = UUID(uuidString: placeIDStr) else {
            return .badRequest("Invalid placeId")
        }
        guard let ws = workspace, projectRoot(ws) != nil else {
            return .serviceUnavailable("no project open")
        }
        guard let data = ws.store.readStoryboardPlaceSketch(placeID: placeID) else {
            return .notFound("No sketch for place \(placeIDStr)")
        }
        return SBHTTPResponse(status: 200, contentType: "image/png", body: data)
    }

    private func putPlaceSketchResponse(placeIDStr: String?, request: SBHTTPRequest) async -> SBHTTPResponse {
        guard let placeIDStr, let placeID = UUID(uuidString: placeIDStr) else {
            return .badRequest("Invalid placeId")
        }
        guard let ws = workspace, projectRoot(ws) != nil else {
            return .serviceUnavailable("no project open")
        }
        guard let body = request.body, !body.isEmpty else {
            return .badRequest("Empty request body")
        }
        do {
            _ = try ws.store.storeStoryboardPlaceSketch(body, placeID: placeID)
        } catch {
            return SBHTTPResponse.error(500, "Failed to save place sketch: \(error.localizedDescription)")
        }
        await MainActor.run {
            StoryboardServerStatusModel.shared.recordIPadSave("Place reference sketch")
        }
        return SBHTTPResponse(status: 204, contentType: "application/json", body: Data())
    }

    private func getLandmarkSketchResponse(landmarkIDStr: String?) -> SBHTTPResponse {
        guard let landmarkIDStr, let landmarkID = UUID(uuidString: landmarkIDStr) else {
            return .badRequest("Invalid landmarkId")
        }
        guard let ws = workspace, projectRoot(ws) != nil else {
            return .serviceUnavailable("no project open")
        }
        guard let data = ws.store.readStoryboardLandmarkSketch(landmarkID: landmarkID) else {
            return .notFound("No sketch for landmark \(landmarkIDStr)")
        }
        return SBHTTPResponse(status: 200, contentType: "image/png", body: data)
    }

    private func putLandmarkSketchResponse(landmarkIDStr: String?, request: SBHTTPRequest) async -> SBHTTPResponse {
        guard let landmarkIDStr, let landmarkID = UUID(uuidString: landmarkIDStr) else {
            return .badRequest("Invalid landmarkId")
        }
        guard let ws = workspace, projectRoot(ws) != nil else {
            return .serviceUnavailable("no project open")
        }
        guard let body = request.body, !body.isEmpty else {
            return .badRequest("Empty request body")
        }
        do {
            _ = try ws.store.storeStoryboardLandmarkSketch(body, landmarkID: landmarkID)
        } catch {
            return SBHTTPResponse.error(500, "Failed to save landmark sketch: \(error.localizedDescription)")
        }
        await MainActor.run {
            StoryboardServerStatusModel.shared.recordIPadSave("Landmark reference sketch")
        }
        return SBHTTPResponse(status: 204, contentType: "application/json", body: Data())
    }

    private func getStoryboardResponse(
        sceneIDStr: String? = nil,
        shotIDStr: String,
        frameStr: String
    ) -> SBHTTPResponse {
        guard let frame = StoryboardFrame(rawValue: frameStr) else {
            return .badRequest("Invalid frame: \(frameStr). Must be begin, middle, or end.")
        }
        guard let shotID = UUID(uuidString: shotIDStr) else {
            return .badRequest("Invalid shotId")
        }
        let requestedSceneID: UUID?
        if let sceneIDStr {
            guard let parsed = UUID(uuidString: sceneIDStr) else {
                return .badRequest("Invalid sceneId")
            }
            requestedSceneID = parsed
        } else {
            requestedSceneID = nil
        }
        guard let ws = workspace, let root = projectRoot(ws) else {
            return .serviceUnavailable("no project open")
        }
        guard let (sceneID, _) = findStoryboardShot(in: ws.store, sceneID: requestedSceneID, shotID: shotID) else {
            return .notFound("Shot not found: \(shotIDStr)")
        }
        guard let data = diskStore.read(projectRoot: root, sceneID: sceneID, shotID: shotID, frame: frame) else {
            return .notFound("No \(frameStr) frame for shot \(shotIDStr)")
        }
        return SBHTTPResponse(status: 200, contentType: "image/png", body: data)
    }

    private func putStoryboardResponse(
        sceneIDStr: String? = nil,
        shotIDStr: String,
        frameStr: String,
        request: SBHTTPRequest
    ) async -> SBHTTPResponse {
        guard let frame = StoryboardFrame(rawValue: frameStr) else {
            return .badRequest("Invalid frame: \(frameStr). Must be begin, middle, or end.")
        }
        guard let shotID = UUID(uuidString: shotIDStr) else {
            return .badRequest("Invalid shotId")
        }
        let requestedSceneID: UUID?
        if let sceneIDStr {
            guard let parsed = UUID(uuidString: sceneIDStr) else {
                return .badRequest("Invalid sceneId")
            }
            requestedSceneID = parsed
        } else {
            requestedSceneID = nil
        }
        guard let ws = workspace, let root = projectRoot(ws) else {
            return .serviceUnavailable("no project open")
        }
        guard let (sceneID, shot) = findStoryboardShot(in: ws.store, sceneID: requestedSceneID, shotID: shotID) else {
            return .notFound("Shot not found: \(shotIDStr)")
        }
        guard let body = request.body, !body.isEmpty else {
            return .badRequest("Empty request body")
        }
        do {
            try diskStore.write(data: body, projectRoot: root, sceneID: sceneID, shotID: shotID, frame: frame)
        } catch {
            return SBHTTPResponse.error(500, "Failed to save image: \(error.localizedDescription)")
        }
        do {
            try registerSavedStoryboardFrame(
                workspace: ws,
                projectRoot: root,
                sceneID: sceneID,
                shot: shot,
                frame: frame
            )
        } catch {
            return SBHTTPResponse.error(500, "Saved image but failed to create durable analysis record: \(error.localizedDescription)")
        }
        await MainActor.run {
            StoryboardServerStatusModel.shared.recordIPadSave("\(frameStr.capitalized) storyboard frame")
        }
        return SBHTTPResponse(status: 204, contentType: "application/json", body: Data())
    }

    // MARK: - Helpers

    private func projectRoot(_ ws: AnimateWorkspaceController) -> URL? {
        guard let path = ws.activeProjectPath else { return nil }
        return URL(fileURLWithPath: path)
    }

    private func registerSavedStoryboardFrame(
        workspace ws: AnimateWorkspaceController,
        projectRoot root: URL,
        sceneID: UUID,
        shot: AnimationSceneShot,
        frame: StoryboardFrame
    ) throws {
        let imageURL = diskStore.imageURL(projectRoot: root, sceneID: sceneID, shotID: shot.id, frame: frame)
        let scene = ws.store.scenes.first { $0.id == sceneID }
        let sceneOrder = ws.store.scenes.firstIndex { $0.id == sceneID }
        let shotOrder = scene?.shots.firstIndex { $0.id == shot.id }
        let sceneName = scene?.name ?? "Scene"

        let context: [String: String] = [
            "source": "ipad_storyboard",
            "sceneID": sceneID.uuidString,
            "sceneName": sceneName,
            "sceneOrder": sceneOrder.map { String($0) } ?? "",
            "shotID": shot.id.uuidString,
            "shotName": shot.name,
            "shotOrder": shotOrder.map { String($0) } ?? "",
            "frame": frame.rawValue
        ]

        ws.store.registerImageAsset(
            path: imageURL.path,
            linkKind: .storyboardFrame,
            ownerID: shot.id.uuidString,
            ownerParentID: sceneID.uuidString,
            moment: frame.rawValue,
            workflow: "storyboard",
            context: context,
            enqueueForAnalysis: true
        )

        // This is the durable queue boundary for iPad storyboard saves.
        // Asset registration/analysis enqueue can remain background work, but
        // the sidecar must exist before we acknowledge the PUT. If the app quits
        // after returning 204, startup recovery can rehydrate jobs from this
        // hash-stamped record.
        try StoryboardFrameAnalysisSidecarStore.writePendingAnalysis(
            projectRoot: root,
            imageURL: imageURL,
            context: StoryboardFrameAnalysisSidecarStore.Context(
                sceneID: sceneID,
                sceneName: sceneName,
                shotID: shot.id,
                shotName: shot.name,
                frame: frame,
                promptContext: storyboardAnalysisPromptContext(
                    workspace: ws,
                    scene: scene,
                    sceneID: sceneID,
                    shot: shot,
                    frame: frame
                )
            )
        )
    }

    private func storyboardAnalysisPromptContext(
        workspace ws: AnimateWorkspaceController,
        scene: AnimationScene?,
        sceneID: UUID,
        shot: AnimationSceneShot,
        frame: StoryboardFrame
    ) -> StoryboardAnalysisPromptContext {
        let sceneCharacters = ws.store.characters
            .filter { character in
                scene?.characterIDs.contains(character.id) == true ||
                    scene?.characterSlugs.contains(character.owpSlug) == true ||
                    character.id == shot.focusCharacterID ||
                    character.owpSlug == shot.focusCharacterSlug
            }
            .map { character in
                StoryboardAnalysisKnownEntity(
                    identifier: character.owpSlug.isEmpty ? character.id.uuidString : character.owpSlug,
                    name: character.name,
                    notes: [
                        character.description,
                        character.defaultWardrobeType.rawValue,
                        character.genderType.rawValue
                    ]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " • ")
                )
            }

        let scenePlaces = knownPlaces(for: scene, store: ws.store)
        let knownLandmarks = ws.store.placesWorkflowLibrary.landmarkProfiles
            .prefix(40)
            .map { landmark in
                StoryboardAnalysisKnownEntity(
                    identifier: landmark.id.uuidString,
                    name: landmark.title,
                    notes: [
                        landmark.kind.displayName,
                        landmark.notes,
                        landmark.tags.joined(separator: ", ")
                    ]
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                    .joined(separator: " • ")
                )
            }

        let cameraParts = [
            shot.cameraShot?.rawValue,
            shot.shotIntent?.rawValue
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }

        return StoryboardAnalysisPromptContext(
            sceneID: sceneID.uuidString,
            shotID: shot.id.uuidString,
            frame: frame.rawValue,
            directionText: scene?.directionTemplate?.notes,
            actionText: shot.notes,
            cameraText: cameraParts.joined(separator: " • "),
            shotSummary: [
                shot.name,
                shot.sourceLyricExcerpt ?? ""
            ]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " • "),
            knownCharacters: sceneCharacters,
            knownPlaces: scenePlaces,
            knownLandmarks: Array(knownLandmarks),
            timeOfDay: scenePlaces.first?.notes,
            orientationNotes: ws.store.placesWorldContextBlocks.environmental
        )
    }

    private func knownPlaces(
        for scene: AnimationScene?,
        store: AnimateStore
    ) -> [StoryboardAnalysisKnownEntity] {
        let relevantBackgrounds = store.backgrounds.filter { background in
            scene?.backgroundID == background.id ||
                background.sceneUsage.contains(scene?.name ?? "")
        }
        let backgrounds = relevantBackgrounds.isEmpty
            ? store.backgrounds.prefix(12)
            : relevantBackgrounds.prefix(12)

        return backgrounds.map { background in
            StoryboardAnalysisKnownEntity(
                identifier: background.id.uuidString,
                name: background.name,
                notes: [
                    background.visualBrief,
                    background.timeOfDay,
                    background.geographicPosition,
                    background.sideOfRiver,
                    background.visualContinuityAnchors
                ]
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " • ")
            )
        }
    }

    private func extractPathComponent(from path: String, prefix: String, suffix: String) -> String? {
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let start = path.index(path.startIndex, offsetBy: prefix.count)
        let end = path.index(path.endIndex, offsetBy: -suffix.count)
        guard start <= end else { return nil }
        return String(path[start..<end])
    }

    private func parseSceneScopedStoryboardPath(_ path: String) -> (sceneID: String, shotID: String, frame: String)? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 7,
              parts[0] == "api",
              parts[1] == "scenes",
              parts[3] == "shots",
              parts[5] == "storyboard" else {
            return nil
        }
        return (sceneID: parts[2], shotID: parts[4], frame: parts[6])
    }

    private func findStoryboardShot(
        in store: AnimateStore,
        sceneID: UUID?,
        shotID: UUID
    ) -> (sceneID: UUID, shot: AnimationSceneShot)? {
        if let sceneID {
            guard let scene = store.scenes.first(where: { $0.id == sceneID }),
                  let shot = scene.shots.first(where: { $0.id == shotID }) else {
                return nil
            }
            return (scene.id, shot)
        }
        return store.findShot(by: shotID)
    }
}

// MARK: - SBHTTPRequest

struct SBHTTPRequest: Sendable {
    var method: String
    var path: String
    var headers: [String: String]
    var body: Data?

    static func parse(_ data: Data) -> SBHTTPRequest? {
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
        let path = rawPath.split(separator: "?", maxSplits: 1).first.map(String.init) ?? rawPath

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 {
                headers[String(parts[0]).trimmingCharacters(in: .whitespaces).lowercased()] =
                    String(parts[1]).trimmingCharacters(in: .whitespaces)
            }
        }

        let bodyStart = separatorRange.upperBound
        let available = data[bodyStart...]

        let body: Data?
        if let cl = headers["content-length"], let len = Int(cl), len > 0 {
            guard available.count >= len else { return nil }
            body = Data(available.prefix(len))
        } else {
            body = available.isEmpty ? nil : Data(available)
        }

        return SBHTTPRequest(method: method, path: path, headers: headers, body: body)
    }

    func jsonBody() -> [String: Any]? {
        guard let body else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }
}

// MARK: - SBHTTPResponse

struct SBHTTPResponse: Sendable {
    var status: Int
    var contentType: String
    var body: Data

    static func okJSON(_ dict: [String: Any]) -> SBHTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]) else {
            return error(500, "encode error")
        }
        return SBHTTPResponse(status: 200, contentType: "application/json; charset=utf-8", body: data)
    }

    static func okJSONArray(_ array: [[String: Any]]) -> SBHTTPResponse {
        guard let data = try? JSONSerialization.data(withJSONObject: array, options: []) else {
            return error(500, "encode error")
        }
        return SBHTTPResponse(status: 200, contentType: "application/json; charset=utf-8", body: data)
    }

    static func notFound(_ message: String) -> SBHTTPResponse { error(404, message) }
    static func badRequest(_ message: String) -> SBHTTPResponse { error(400, message) }
    static func serviceUnavailable(_ message: String) -> SBHTTPResponse { error(503, message) }

    static func error(_ status: Int, _ message: String) -> SBHTTPResponse {
        let dict = ["error": message]
        let data = (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
        return SBHTTPResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    func serialize() -> Data {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 204: statusText = "No Content"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 405: statusText = "Method Not Allowed"
        case 413: statusText = "Payload Too Large"
        case 500: statusText = "Internal Server Error"
        case 503: statusText = "Service Unavailable"
        default:  statusText = "Error"
        }

        var headers = [
            "Content-Type": contentType,
            "Content-Length": "\(body.count)",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, POST, PUT, OPTIONS",
            "Access-Control-Allow-Headers": "Content-Type",
            "Connection": "close"
        ]
        if status == 204 {
            headers.removeValue(forKey: "Content-Type")
            headers["Content-Length"] = "0"
        }

        var response = "HTTP/1.1 \(status) \(statusText)\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            response += "\(key): \(value)\r\n"
        }
        response += "\r\n"

        var data = response.data(using: .utf8) ?? Data()
        data.append(body)
        return data
    }
}
