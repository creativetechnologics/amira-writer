import Foundation
import ProjectKit

// MARK: - AnimateStore + Storyboard helpers

@available(macOS 26.0, *)
extension AnimateStore {

    struct StoryboardCreatedShot: Sendable {
        let sceneID: UUID
        let sceneName: String
        let shot: AnimationSceneShot
        let shotOrder: Int
    }

    struct StoryboardCreatedPlace: Sendable {
        let id: UUID
        let name: String
    }

    struct StoryboardCreatedLandmark: Sendable {
        let id: UUID
        let title: String
    }

    /// Finds the scene ID and shot for the given shot UUID.
    /// Returns `(sceneID, shot)` or `nil` if not found.
    func findShot(by shotID: UUID?) -> (sceneID: UUID, shot: AnimationSceneShot)? {
        guard let shotID else { return nil }
        for scene in scenes {
            if let shot = scene.shots.first(where: { $0.id == shotID }) {
                return (scene.id, shot)
            }
        }
        return nil
    }

    /// Reorders the shots in `sceneID` to match the supplied UUID order.
    /// `shotIDs` must be a permutation of the existing shot IDs in the scene
    /// (same set, same count). Returns `true` on success, `false` if the
    /// scene is missing or the supplied IDs don't match the current set.
    /// Frame ranges (`startFrame` / `endFrame`) are preserved unchanged —
    /// only the array order changes, which is what the iPad sidebar reads.
    @discardableResult
    func reorderSceneShots(sceneID: UUID, shotIDs: [UUID]) -> Bool {
        guard let sceneIndex = scenes.firstIndex(where: { $0.id == sceneID }) else {
            return false
        }
        let existing = scenes[sceneIndex].shots
        guard existing.count == shotIDs.count,
              Set(existing.map(\.id)) == Set(shotIDs) else {
            return false
        }
        let lookup: [UUID: AnimationSceneShot] = Dictionary(
            uniqueKeysWithValues: existing.map { ($0.id, $0) }
        )
        // The set-equality + count guard above guarantees every UUID in
        // `shotIDs` is a key in `lookup`. Force-unwrap rather than
        // `compactMap` so we crash loudly if that invariant ever weakens —
        // silently dropping shots would corrupt the project.
        scenes[sceneIndex].shots = shotIDs.map { lookup[$0]! }
        save()
        return true
    }

    /// Updates `notes` on the shot with the given ID. Returns `true` if the shot was found.
    @discardableResult
    func updateShotNotes(shotID: UUID, notes: String) -> Bool {
        for sceneIndex in scenes.indices {
            if let shotIndex = scenes[sceneIndex].shots.firstIndex(where: { $0.id == shotID }) {
                scenes[sceneIndex].shots[shotIndex].notes = notes
                save()
                return true
            }
        }
        return false
    }

    /// Appends a new storyboard shot to the selected scene, or to the explicit scene ID if provided.
    /// Returns the normalized created shot and its final order within the scene.
    @discardableResult
    func appendStoryboardShot(
        sceneID explicitSceneID: UUID? = nil,
        title rawTitle: String? = nil
    ) -> StoryboardCreatedShot? {
        guard let sceneIndex = resolvedStoryboardSceneIndex(explicitSceneID: explicitSceneID) else {
            return nil
        }

        let scene = scenes[sceneIndex]
        if selectedSceneID != scene.id {
            selectedSceneID = scene.id
        }
        let trimmedTitle = rawTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let shotName = (trimmedTitle?.isEmpty == false) ? trimmedTitle! : "Shot \(scene.shots.count + 1)"
        let startFrame = max((scene.shots.map(\.endFrame).max() ?? -1) + 1, 0)
        let endFrame = startFrame + 47

        var shot = AnimationSceneShot(
            name: shotName,
            startFrame: startFrame,
            endFrame: endFrame,
            source: .manual,
            lockedBoundaries: true
        )
        shot.name = shot.name.trimmingCharacters(in: .whitespacesAndNewlines)

        scenes[sceneIndex].shots.append(shot)
        scenes[sceneIndex].shots = scenes[sceneIndex].shots
            .map { current in
                var current = current
                current.name = current.name.trimmingCharacters(in: .whitespacesAndNewlines)
                current.startFrame = max(0, current.startFrame)
                current.endFrame = max(current.startFrame, current.endFrame)
                current.notes = current.notes.trimmingCharacters(in: .whitespacesAndNewlines)
                return current
            }
            .sorted {
                if $0.startFrame == $1.startFrame {
                    if $0.endFrame == $1.endFrame {
                        return $0.name < $1.name
                    }
                    return $0.endFrame < $1.endFrame
                }
                return $0.startFrame < $1.startFrame
            }

        save()

        guard let finalIndex = scenes[sceneIndex].shots.firstIndex(where: { $0.id == shot.id }) else {
            return nil
        }

        statusMessage = "Added shot \(scenes[sceneIndex].shots[finalIndex].name)"
        return StoryboardCreatedShot(
            sceneID: scene.id,
            sceneName: scene.name,
            shot: scenes[sceneIndex].shots[finalIndex],
            shotOrder: finalIndex
        )
    }

    private func resolvedStoryboardSceneIndex(explicitSceneID: UUID?) -> Int? {
        if let explicitSceneID,
           let sceneIndex = scenes.firstIndex(where: { $0.id == explicitSceneID }) {
            return sceneIndex
        }

        if let selectedSceneID,
           let sceneIndex = scenes.firstIndex(where: { $0.id == selectedSceneID }) {
            return sceneIndex
        }

        return scenes.indices.first
    }

    func storyboardPlaceEntries() -> [[String: Any]] {
        backgrounds
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .map { place in
                [
                    "id": place.id.uuidString,
                    "name": place.name,
                    "notes": place.notes,
                    // Only the iPad-drawn storyboard sketch is exposed here. The
                    // macOS reference-image gallery is intentionally NOT surfaced
                    // through the iPad pipeline (the user wants Places mode to
                    // open blank instead of pulling existing place images).
                    "hasSketch": storyboardResolvedURL(for: place.storyboardSketchPath) != nil,
                    "imageCount": place.storyboardSketchPath == nil ? 0 : 1
                ]
            }
    }

    func storyboardLandmarkEntries() -> [[String: Any]] {
        placesWorkflowLibrary.landmarkProfiles
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            .map { landmark in
                [
                    "id": landmark.id.uuidString,
                    "title": landmark.title,
                    "kind": landmark.kind.displayName,
                    "notes": landmark.notes,
                    // iPad-drawn storyboard sketch only — see comment above.
                    "hasSketch": storyboardResolvedURL(for: landmark.storyboardSketchPath) != nil,
                    "imageCount": landmark.storyboardSketchPath == nil ? 0 : 1
                ]
            }
    }

    @discardableResult
    func createStoryboardPlace(name rawName: String) -> StoryboardCreatedPlace {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "New Place" : trimmed
        let place = BackgroundPlate(
            name: name,
            filename: "",
            notes: "",
            imagePaths: [],
            approvedImagePath: nil,
            sourceURL: nil
        )
        backgrounds.append(place)
        backgrounds.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        selectedBackgroundID = place.id
        save(writePlaces: true)
        return StoryboardCreatedPlace(id: place.id, name: place.name)
    }

    @discardableResult
    func createStoryboardLandmark(title rawTitle: String) -> StoryboardCreatedLandmark {
        let id = createLandmarkProfile(title: rawTitle)
        let title = placesWorkflowLibrary.landmarkProfiles.first { $0.id == id }?.title ?? rawTitle
        return StoryboardCreatedLandmark(id: id, title: title)
    }

    func readStoryboardPlaceSketch(placeID: UUID) -> Data? {
        // Reads ONLY the isolated iPad sketch path. Falls back to nil
        // (blank canvas) when the user has never drawn on this place — the
        // macOS reference-image gallery is intentionally never surfaced here.
        guard let place = backgrounds.first(where: { $0.id == placeID }) else { return nil }
        guard let url = storyboardResolvedURL(for: place.storyboardSketchPath) else { return nil }
        return try? Data(contentsOf: url)
    }

    func readStoryboardLandmarkSketch(landmarkID: UUID) -> Data? {
        // Reads ONLY the isolated iPad sketch path. See note on places.
        guard let landmark = placesWorkflowLibrary.landmarkProfiles.first(where: { $0.id == landmarkID }) else { return nil }
        guard let url = storyboardResolvedURL(for: landmark.storyboardSketchPath) else { return nil }
        return try? Data(contentsOf: url)
    }

    @discardableResult
    func storeStoryboardPlaceSketch(_ data: Data, placeID: UUID) throws -> String {
        // Writes the latest iPad sketch to a single fixed-name file. Never
        // mutates `imagePaths`, `referenceImages`, or `approvedImagePath` —
        // the iPad pipeline is fully isolated from the macOS Places gallery.
        guard let projectRoot = fileOWPURL,
              let placeIndex = backgrounds.firstIndex(where: { $0.id == placeID }) else {
            throw NSError(domain: "StoryboardPlaces", code: 1, userInfo: [NSLocalizedDescriptionKey: "Place not found."])
        }
        let placeSlug = PlacesScriptIndexService.fileStem(for: backgrounds[placeIndex].name)
        let url = try writeStoryboardSketchAtomic(
            data,
            projectRoot: projectRoot,
            components: ["places", placeSlug]
        )
        let storedPath = storyboardProjectRelativePath(for: url, projectRoot: projectRoot)
        backgrounds[placeIndex].storyboardSketchPath = storedPath
        save(writePlaces: true)
        registerImageAsset(
            path: url.path,
            linkKind: .placeReference,
            ownerID: placeID.uuidString,
            workflow: "ipad_storyboard_sketch",
            context: [
                "source": "ipad_storyboard",
                "placeID": placeID.uuidString,
                "placeName": backgrounds[placeIndex].name
            ],
            enqueueForAnalysis: true
        )
        return storedPath
    }

    @discardableResult
    func storeStoryboardLandmarkSketch(_ data: Data, landmarkID: UUID) throws -> String {
        // See notes on `storeStoryboardPlaceSketch` — same isolation contract
        // applies to landmarks. `galleryImagePaths` is never appended to.
        guard let projectRoot = fileOWPURL,
              let landmarkIndex = placesWorkflowLibrary.landmarkProfiles.firstIndex(where: { $0.id == landmarkID }) else {
            throw NSError(domain: "StoryboardPlaces", code: 2, userInfo: [NSLocalizedDescriptionKey: "Landmark not found."])
        }
        let landmark = placesWorkflowLibrary.landmarkProfiles[landmarkIndex]
        let landmarkSlug = PlacesScriptIndexService.fileStem(for: landmark.title)
        let url = try writeStoryboardSketchAtomic(
            data,
            projectRoot: projectRoot,
            components: ["landmarks", landmarkSlug]
        )
        let storedPath = storyboardProjectRelativePath(for: url, projectRoot: projectRoot)
        placesWorkflowLibrary.landmarkProfiles[landmarkIndex].storyboardSketchPath = storedPath
        placesWorkflowLibrary.landmarkProfiles[landmarkIndex].updatedAt = Date()
        save(writePlaces: true)
        registerImageAsset(
            path: url.path,
            linkKind: .placeLandmarkReference,
            ownerID: landmarkID.uuidString,
            workflow: "ipad_storyboard_sketch",
            context: [
                "source": "ipad_storyboard",
                "landmarkID": landmarkID.uuidString,
                "landmarkTitle": landmark.title
            ],
            enqueueForAnalysis: true
        )
        return storedPath
    }

    /// Writes the latest iPad sketch atomically to a fixed-name file. Each
    /// save overwrites the previous file — no history is retained, by user
    /// preference. Lives under
    /// `Animate/backgrounds/ipad-storyboard-sketches/<components>/ipad-sketch.png`.
    private func writeStoryboardSketchAtomic(
        _ data: Data,
        projectRoot: URL,
        components: [String]
    ) throws -> URL {
        var dir = ProjectPaths(root: projectRoot).animateBackgrounds
            .appendingPathComponent("ipad-storyboard-sketches")
        for component in components {
            dir.appendPathComponent(component)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("ipad-sketch.png")
        try data.write(to: url, options: .atomic)
        return url
    }

    private func storyboardProjectRelativePath(for url: URL, projectRoot: URL) -> String {
        let rootPath = projectRoot.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path.hasPrefix(rootPath + "/") {
            return String(path.dropFirst(rootPath.count + 1))
        }
        return path
    }

    private func storyboardResolvedURL(for path: String?) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return nil
        }
        if let resolved = resolvedCharacterAssetURL(for: path) {
            return resolved
        }
        if path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        if let root = fileOWPURL {
            let url = root.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        return nil
    }
}
