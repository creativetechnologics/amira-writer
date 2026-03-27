import AVFoundation
import Foundation
import NovotroProjectKit
import XCTest
@testable import NovotroMixUI

@available(macOS 26.0, *)
@MainActor
final class MixStoreTests: XCTestCase {
    func testDefaultSessionStartsEmpty() {
        let scene = MixSceneSummary(
            id: UUID(),
            relativePath: "Songs/Act I/Open Sky.ows",
            title: "Open Sky",
            orderIndex: 0,
            updatedAt: Date.distantPast,
            lengthTicks: 9600,
            noteCount: 128
        )

        let session = MixSceneSession.default(for: scene)
        XCTAssertEqual(session.tracks.count, 0)
        XCTAssertNil(session.selectedTrackID)
        XCTAssertEqual(session.clips.count, 0)
    }

    func testAddingClipToEmptySessionCreatesFirstTrack() async throws {
        let store = MixStore()
        let scene = MixSceneSummary(
            id: UUID(),
            relativePath: "Songs/Act I/Open Sky.ows",
            title: "Open Sky",
            orderIndex: 0,
            updatedAt: Date.distantPast,
            lengthTicks: 9600,
            noteCount: 128
        )
        store.scenes = [scene]
        store.selectScene(scene.id)

        let clipURL = try makeSilentWAV(named: "mix-empty-drop")
        await store.addClipsAsync(from: [clipURL], to: UUID(), startingAt: 0)

        XCTAssertEqual(store.currentTracks.count, 1)
        XCTAssertEqual(store.currentClips.count, 1)
        XCTAssertEqual(store.currentTracks.first?.name, "Track 1")
    }

    func testSuggestedStartWouldStackAfterClipEnd() async throws {
        let store = makeStoreWithDefaultScene()
        let track = try XCTUnwrap(store.currentTracks.first)
        let clipURL = try makeSilentWAV(named: "mix-start-stack", durationSeconds: 2)

        await store.addClipsAsync(from: [clipURL], to: track.id, startingAt: 12)

        XCTAssertEqual(store.suggestedStartSeconds(for: track.id), 14.25, accuracy: 0.0001)
    }

    func testSelectingTrackCanClearSelectedClip() async throws {
        let store = makeStoreWithDefaultScene()
        let track = try XCTUnwrap(store.currentTracks.first)
        let clipURL = try makeSilentWAV(named: "mix-selection")
        await store.addClipsAsync(from: [clipURL], to: track.id, startingAt: 0)
        XCTAssertNotNil(store.selectedClip)

        let otherTrack = try XCTUnwrap(store.currentTracks.dropFirst().first)
        store.selectTrack(otherTrack.id, clearSelectedClip: true)

        XCTAssertEqual(store.selectedTrack?.id, otherTrack.id)
        XCTAssertNil(store.selectedClip)
    }

    func testSelectingTrackWithoutClearingClipDropsClipSelectionWhenTrackChanges() async throws {
        let store = makeStoreWithDefaultScene()
        let firstTrack = try XCTUnwrap(store.currentTracks.first)
        let otherTrack = try XCTUnwrap(store.currentTracks.dropFirst().first)
        let clipURL = try makeSilentWAV(named: "mix-track-focus")
        await store.addClipsAsync(from: [clipURL], to: firstTrack.id, startingAt: 0)

        store.selectTrack(otherTrack.id)

        XCTAssertEqual(store.selectedTrack?.id, otherTrack.id)
        XCTAssertNil(store.selectedClip)
    }

    func testTargetTrackIDClampsWithinAvailableTracks() throws {
        let store = makeStoreWithDefaultScene()
        let firstTrack = try XCTUnwrap(store.currentTracks.first)
        let thirdTrack = try XCTUnwrap(store.currentTracks.dropFirst(2).first)
        let lastTrack = try XCTUnwrap(store.currentTracks.last)

        XCTAssertEqual(store.targetTrackID(from: firstTrack.id, laneDelta: 2), thirdTrack.id)
        XCTAssertEqual(store.targetTrackID(from: firstTrack.id, laneDelta: -10), firstTrack.id)
        XCTAssertEqual(store.targetTrackID(from: firstTrack.id, laneDelta: 100), lastTrack.id)
    }

    func testFilteringScenesKeepsSelectedSceneVisible() {
        let store = makeStoreWithTwoScenes()
        let secondScene = store.filteredScenes[1]

        store.selectScene(secondScene.id)
        store.sceneSearchText = "open sky"

        XCTAssertEqual(store.filteredScenes.first?.id, secondScene.id)
        XCTAssertTrue(store.filteredScenes.contains(where: { $0.id == secondScene.id }))
    }

    func testTimelineZoomPersistsPerSceneAndClamps() {
        let store = makeStoreWithTwoScenes()
        let firstScene = store.filteredScenes[0]
        let secondScene = store.filteredScenes[1]

        store.updateTimelinePixelsPerSecond(60)
        XCTAssertEqual(store.currentTimelinePixelsPerSecond, 48, accuracy: 0.0001)

        store.selectScene(secondScene.id)
        XCTAssertEqual(store.currentTimelinePixelsPerSecond, 26, accuracy: 0.0001)

        store.updateTimelinePixelsPerSecond(8)
        XCTAssertEqual(store.currentTimelinePixelsPerSecond, 12, accuracy: 0.0001)

        store.selectScene(firstScene.id)
        XCTAssertEqual(store.currentTimelinePixelsPerSecond, 48, accuracy: 0.0001)

        store.selectScene(secondScene.id)
        XCTAssertEqual(store.currentTimelinePixelsPerSecond, 12, accuracy: 0.0001)
    }

    func testTrackEditingKeepsFallbackNameAndAllowsEmptySession() throws {
        let store = makeStoreWithDefaultScene()
        let track = try XCTUnwrap(store.currentTracks.first)

        store.updateTrackName(track.id, name: "  Lead Bus  ")
        XCTAssertEqual(store.selectedTrack?.name, "Lead Bus")

        store.updateTrackName(track.id, name: "   ")
        XCTAssertEqual(store.selectedTrack?.name, "Track 1")

        while store.currentTracks.count > 1, let trailingTrack = store.currentTracks.last {
            store.removeTrack(trailingTrack.id)
        }

        XCTAssertEqual(store.currentTracks.count, 1)
        let remainingTrackID = try XCTUnwrap(store.currentTracks.first?.id)
        store.removeTrack(remainingTrackID)
        XCTAssertEqual(store.currentTracks.count, 0)
        XCTAssertNil(store.selectedTrack)
    }

    func testAddingTrackClearsClipSelectionAndFocusesNewTrack() async throws {
        let store = makeStoreWithDefaultScene()
        let track = try XCTUnwrap(store.currentTracks.first)
        let clipURL = try makeSilentWAV(named: "mix-add-track-focus")
        await store.addClipsAsync(from: [clipURL], to: track.id, startingAt: 0)

        store.addTrack()

        XCTAssertNil(store.selectedClip)
        XCTAssertEqual(store.selectedTrack?.name, "Track 7")
    }

    func testRemovingTrackPreservesValidSelectionAndChoosesNeighbor() async throws {
        let store = makeStoreWithDefaultScene()
        let firstTrack = try XCTUnwrap(store.currentTracks.first)
        let secondTrack = try XCTUnwrap(store.currentTracks.dropFirst(1).first)
        let thirdTrack = try XCTUnwrap(store.currentTracks.dropFirst(2).first)
        let clipURL = try makeSilentWAV(named: "mix-remove-preserve")

        await store.addClipsAsync(from: [clipURL], to: thirdTrack.id, startingAt: 0)
        let selectedClipID = try XCTUnwrap(store.selectedClip?.id)

        store.removeTrack(firstTrack.id)
        XCTAssertEqual(store.selectedTrack?.id, thirdTrack.id)
        XCTAssertEqual(store.selectedClip?.id, selectedClipID)

        store.selectTrack(secondTrack.id)
        store.removeTrack(secondTrack.id)
        XCTAssertEqual(store.selectedTrack?.id, thirdTrack.id)
    }

    func testClipEditsClampStartAndGain() async throws {
        let store = makeStoreWithDefaultScene()
        let track = try XCTUnwrap(store.currentTracks.first)
        let clipURL = try makeSilentWAV(named: "mix-edit-controls")
        await store.addClipsAsync(from: [clipURL], to: track.id, startingAt: 0)
        let clipID = try XCTUnwrap(store.selectedClip?.id)

        store.updateClipStartSeconds(clipID, value: -8)
        store.updateClipGain(clipID, value: 40)

        let updatedClip = try XCTUnwrap(store.selectedClip)
        XCTAssertEqual(updatedClip.startSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(updatedClip.gainDB, 12, accuracy: 0.0001)
    }

    func testClipNameEditingTrimsAndFallsBackToFilename() async throws {
        let store = makeStoreWithDefaultScene()
        let track = try XCTUnwrap(store.currentTracks.first)
        let clipURL = try makeSilentWAV(named: "mix-name-controls")
        await store.addClipsAsync(from: [clipURL], to: track.id, startingAt: 0)
        let clipID = try XCTUnwrap(store.selectedClip?.id)

        store.updateClipName(clipID, name: "  Intro Stem  ")
        XCTAssertEqual(store.selectedClip?.name, "Intro Stem")

        store.updateClipName(clipID, name: "   ")
        XCTAssertEqual(store.selectedClip?.name, "mix-name-controls")
    }

    func testTrackNotesUpdateSelectedTrackSession() throws {
        let store = makeStoreWithDefaultScene()
        let track = try XCTUnwrap(store.currentTracks.first)

        store.updateTrackNotes(track.id, notes: "Blend with chorus print and leave room for VO.")

        XCTAssertEqual(store.selectedTrack?.notes, "Blend with chorus print and leave room for VO.")
    }

    func testClipFadeEditsRespectRemainingDuration() async throws {
        let store = makeStoreWithDefaultScene()
        let track = try XCTUnwrap(store.currentTracks.first)
        let clipURL = try makeSilentWAV(named: "mix-fade-controls", durationSeconds: 2)
        await store.addClipsAsync(from: [clipURL], to: track.id, startingAt: 0)
        let clipID = try XCTUnwrap(store.selectedClip?.id)

        store.updateClipFadeIn(clipID, value: 1.0)
        store.updateClipFadeOut(clipID, value: 1.5)

        let updatedClip = try XCTUnwrap(store.selectedClip)
        XCTAssertEqual(updatedClip.fadeInSeconds, 1.0, accuracy: 0.0001)
        XCTAssertEqual(updatedClip.fadeOutSeconds, 1.0, accuracy: 0.0001)
    }

    func testAddingMultipleClipsStacksThemInDropOrder() async throws {
        let store = makeStoreWithDefaultScene()
        let track = try XCTUnwrap(store.currentTracks.first)
        let firstURL = try makeSilentWAV(named: "mix-stack-a")
        let secondURL = try makeSilentWAV(named: "mix-stack-b")

        await store.addClipsAsync(from: [firstURL, secondURL], to: track.id, startingAt: 4)

        let clips = store.clips(for: track.id)
        XCTAssertEqual(clips.count, 2)
        XCTAssertEqual(clips[0].name, "mix-stack-a")
        XCTAssertEqual(clips[1].name, "mix-stack-b")
        XCTAssertEqual(clips[0].startSeconds, 4, accuracy: 0.0001)
        XCTAssertEqual(clips[1].startSeconds, clips[0].startSeconds + clips[0].durationSeconds + 0.25, accuracy: 0.0001)
    }

    func testInvalidTrackTargetsFallBackToExistingTrack() async throws {
        let store = makeStoreWithDefaultScene()
        let validTrack = try XCTUnwrap(store.currentTracks.first)
        let clipURL = try makeSilentWAV(named: "mix-invalid-track")

        await store.addClipsAsync(from: [clipURL], to: UUID(), startingAt: 3)

        var clip = try XCTUnwrap(store.selectedClip)
        XCTAssertEqual(clip.trackID, validTrack.id)
        XCTAssertEqual(clip.startSeconds, 3, accuracy: 0.0001)

        store.moveClip(clip.id, to: UUID(), startSeconds: 6)

        clip = try XCTUnwrap(store.selectedClip)
        XCTAssertEqual(clip.trackID, validTrack.id)
        XCTAssertEqual(clip.startSeconds, 6, accuracy: 0.0001)
    }

    func testBrowserRefreshDoesNotOverwriteNewerStatusMessage() async throws {
        let store = makeStoreWithDefaultScene()
        let projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let audioDirectory = projectDirectory.appendingPathComponent("Audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDirectory, withIntermediateDirectories: true)

        store.workingProjectURL = projectDirectory
        store.statusMessage = "Initial status"
        store.refreshBrowser()
        store.statusMessage = "Saved mix session."

        let deadline = Date().addingTimeInterval(5)
        while store.isRefreshingBrowser, deadline.timeIntervalSinceNow > 0 {
            try await Task.sleep(for: .milliseconds(20))
        }

        XCTAssertFalse(store.isRefreshingBrowser)
        XCTAssertEqual(store.statusMessage, "Saved mix session.")
    }

    func testBrowserRefreshIncludesProjectSunoFolder() async throws {
        let store = makeStoreWithDefaultScene()
        let projectDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let sunoDirectory = projectDirectory.appendingPathComponent("suno", isDirectory: true)
        try FileManager.default.createDirectory(at: sunoDirectory, withIntermediateDirectories: true)

        store.workingProjectURL = projectDirectory
        store.refreshBrowser()

        try await waitUntil(timeout: 10) {
            store.isRefreshingBrowser == false
        }

        XCTAssertTrue(store.browserRoots.contains(where: { $0.path == sunoDirectory.path }))
    }

    func testProjectRoundTripPersistsMixSessionState() async throws {
        let project = try makeFixtureMixProject(sceneDefinitions: [
            ("Songs/Act I/Open Sky.ows", "Open Sky"),
            ("Songs/Act I/Night Drive.ows", "Night Drive"),
        ])
        defer { try? FileManager.default.removeItem(at: project.rootURL) }

        let store = MixStore()
        let loadError = await store.ensureProjectLoaded(project.projectURL)
        XCTAssertNil(loadError)

        let targetScene = try XCTUnwrap(store.scenes.last)
        store.selectScene(targetScene.id)
        store.addTrack()
        let track = try XCTUnwrap(store.currentTracks.first)
        let clipURL = try makeSilentWAV(named: "mix-roundtrip-persist")

        store.updateSessionNotes("Round-trip notes for the selected scene.")
        store.updateTrackNotes(track.id, notes: "Blend the Suno print under the pickup.")
        store.updateTimelinePixelsPerSecond(41)
        await store.addClipsAsync(from: [clipURL], to: track.id, startingAt: 2)

        XCTAssertEqual(store.saveIndicator, .unsavedChanges)

        let savedDocument = try await waitForMixDocument(
            in: project.projectURL,
            where: { document in
                guard let session = document.sceneSessions[targetScene.relativePath] else { return false }
                return document.lastSelectedScenePath == targetScene.relativePath
                    && session.notes == "Round-trip notes for the selected scene."
                    && abs(session.zoomSecondsPerScreen - 41) < 0.0001
                    && session.tracks.first?.notes == "Blend the Suno print under the pickup."
                    && session.clips.count == 1
            }
        )

        XCTAssertEqual(savedDocument.lastSelectedScenePath, targetScene.relativePath)

        let reloadedStore = MixStore()
        let reloadError = await reloadedStore.ensureProjectLoaded(project.projectURL)
        XCTAssertNil(reloadError)
        XCTAssertEqual(reloadedStore.selectedScene?.relativePath, targetScene.relativePath)
        XCTAssertEqual(reloadedStore.currentSession?.notes, "Round-trip notes for the selected scene.")
        XCTAssertEqual(reloadedStore.currentTimelinePixelsPerSecond, 41, accuracy: 0.0001)
        XCTAssertEqual(reloadedStore.currentTracks.first?.notes, "Blend the Suno print under the pickup.")
        XCTAssertEqual(reloadedStore.currentClips.count, 1)
        // selectedClipID is intentionally cleared on load (clips should not appear selected at project open)
        XCTAssertNil(reloadedStore.selectedClip)
        XCTAssertEqual(reloadedStore.currentClips.first?.name, "mix-roundtrip-persist")
    }

    func testSceneTitlesRefreshFromDatabaseChanges() async throws {
        let project = try makeFixtureMixProject(sceneDefinitions: [
            ("Songs/Act I/Open Sky.ows", "Open Sky"),
        ])
        defer { try? FileManager.default.removeItem(at: project.rootURL) }

        let store = MixStore()
        let loadError = await store.ensureProjectLoaded(project.projectURL)
        XCTAssertNil(loadError)

        let scenePath = try XCTUnwrap(project.scenePaths.first)
        let connection = try await NovotroProjectConnection.open(projectURL: project.projectURL, preferService: false)
        try await connection.ensureCurrentIndex()

        guard var scene = try await connection.loadScene(relativePath: scenePath) else {
            XCTFail("Expected scene in project database")
            return
        }

        scene.title = "Open Sky Reprise"
        scene.canonicalTitle = "open sky reprise"
        scene.updatedAt = Date()
        try await connection.upsertScene(scene, actorID: "write-tests")

        try await waitUntil(timeout: 3) {
            store.scenes.first(where: { $0.relativePath == scenePath })?.displayTitle == "Open Sky Reprise"
        }

        XCTAssertEqual(store.selectedScene?.displayTitle, "Open Sky Reprise")
    }

    func testLoadRepairsInvalidPersistedSelectionIdentifiers() async throws {
        let project = try makeFixtureMixProject(sceneDefinitions: [
            ("Songs/Act I/Open Sky.ows", "Open Sky"),
        ])
        defer { try? FileManager.default.removeItem(at: project.rootURL) }

        let scenePath = try XCTUnwrap(project.scenePaths.first)
        let sceneSummary = MixSceneSummary(
            id: UUID(),
            relativePath: scenePath,
            title: "Open Sky",
            orderIndex: 0,
            updatedAt: Date.distantPast,
            lengthTicks: 9600,
            noteCount: 128
        )
        var session = MixSceneSession.default(for: sceneSummary)
        session.selectedTrackID = UUID()
        session.selectedClipID = UUID()
        let document = MixProjectDocument(
            lastSelectedScenePath: scenePath,
            sceneSessions: [scenePath: session]
        )

        let connection = try await NovotroProjectConnection.open(projectURL: project.projectURL, preferService: false)
        try await connection.ensureCurrentIndex()
        try await connection.upsertProjectFile(
            path: MixStore.mixProjectFile,
            jsonData: try makeMixDecoderEncoder().encode(document),
            actorID: "mix-tests"
        )

        let store = MixStore()
        let loadError = await store.ensureProjectLoaded(project.projectURL)
        XCTAssertNil(loadError)
        XCTAssertNil(store.selectedTrack)
        XCTAssertNil(store.selectedClip)
    }

    func testCorruptSessionRecoveryWarningClearsAfterSuccessfulSave() async throws {
        let project = try makeFixtureMixProject(sceneDefinitions: [
            ("Songs/Act I/Open Sky.ows", "Open Sky"),
        ])
        defer { try? FileManager.default.removeItem(at: project.rootURL) }

        let connection = try await NovotroProjectConnection.open(projectURL: project.projectURL, preferService: false)
        try await connection.ensureCurrentIndex()
        try await connection.upsertProjectFile(
            path: MixStore.mixProjectFile,
            jsonData: Data("{\"broken\":".utf8),
            actorID: "mix-tests"
        )

        let store = MixStore()
        let loadError = await store.ensureProjectLoaded(project.projectURL)
        XCTAssertNil(loadError)
        XCTAssertTrue(store.statusMessage.contains("Recovered from an unreadable mix session file."))

        store.updateSessionNotes("Recovered and resaved cleanly.")
        store.save()

        _ = try await waitForMixDocument(
            in: project.projectURL,
            where: { document in
                document.sceneSessions.values.contains(where: { $0.notes == "Recovered and resaved cleanly." })
            }
        )

        // Cancel any in-flight background startup (which also runs refreshBrowser after 150ms)
        // so the explicit refreshBrowser() below is the only browser scan in flight.
        store.suspendBackgroundWork()
        store.refreshBrowser()
        try await waitUntil(timeout: 10) {
            store.isRefreshingBrowser == false
        }
        XCTAssertFalse(store.statusMessage.contains("Recovered from an unreadable mix session file."))
    }

    func testUpdatingClipGainAndFadesClampsToBounds() async throws {
        let store = makeStoreWithDefaultScene()
        let track = try XCTUnwrap(store.currentTracks.first)
        let clipURL = try makeSilentWAV(named: "mix-clip-controls")
        await store.addClipsAsync(from: [clipURL], to: track.id, startingAt: 0)
        let clipID = try XCTUnwrap(store.selectedClip?.id)

        store.updateClipGain(clipID, value: 48)
        store.updateClipFadeIn(clipID, value: 99)
        store.updateClipFadeOut(clipID, value: 99)

        var clip = try XCTUnwrap(store.selectedClip)
        XCTAssertEqual(clip.gainDB, 12, accuracy: 0.0001)
        XCTAssertEqual(clip.fadeInSeconds, clip.durationSeconds * 0.5, accuracy: 0.0001)
        XCTAssertEqual(clip.fadeOutSeconds, clip.durationSeconds * 0.5, accuracy: 0.0001)

        store.updateClipGain(clipID, value: -100)
        store.updateClipFadeIn(clipID, value: -10)
        store.updateClipFadeOut(clipID, value: -10)

        clip = try XCTUnwrap(store.selectedClip)
        XCTAssertEqual(clip.gainDB, -24, accuracy: 0.0001)
        XCTAssertEqual(clip.fadeInSeconds, 0, accuracy: 0.0001)
        XCTAssertEqual(clip.fadeOutSeconds, 0, accuracy: 0.0001)
    }

    private func makeStoreWithDefaultScene() -> MixStore {
        let store = MixStore()
        let scene = MixSceneSummary(
            id: UUID(),
            relativePath: "Songs/Act I/Open Sky.ows",
            title: "Open Sky",
            orderIndex: 0,
            updatedAt: Date.distantPast,
            lengthTicks: 9600,
            noteCount: 128
        )
        store.scenes = [scene]
        store.selectScene(scene.id)
        // Cancel background tasks (browser refresh, plugin scan) that selectScene starts
        // so slow filesystem scans don't bleed into unrelated tests or leave isRefreshingBrowser
        // stuck true when browser-specific tests issue their own explicit refreshBrowser() calls.
        store.suspendBackgroundWork()
        for _ in 0..<6 {
            store.addTrack()
        }
        if let firstTrackID = store.currentTracks.first?.id {
            store.selectTrack(firstTrackID)
        }
        return store
    }

    private func makeStoreWithTwoScenes() -> MixStore {
        let store = MixStore()
        let scenes = [
            MixSceneSummary(
                id: UUID(),
                relativePath: "Songs/Act I/Open Sky.ows",
                title: "Open Sky",
                orderIndex: 0,
                updatedAt: Date.distantPast,
                lengthTicks: 9600,
                noteCount: 128
            ),
            MixSceneSummary(
                id: UUID(),
                relativePath: "Songs/Act I/Night Drive.ows",
                title: "Night Drive",
                orderIndex: 1,
                updatedAt: Date.distantPast,
                lengthTicks: 6400,
                noteCount: 84
            ),
        ]
        store.scenes = scenes
        store.selectScene(scenes[0].id)
        return store
    }

    private func makeFixtureMixProject(sceneDefinitions: [(String, String)]) throws -> FixtureMixProject {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("NovotroMixTests-\(UUID().uuidString)", isDirectory: true)
        let projectURL = rootURL.appendingPathComponent("Fixture.owp", isDirectory: true)
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("Songs"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("Metadata"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projectURL.appendingPathComponent("Audio"), withIntermediateDirectories: true)

        let metadata: [String: Any] = [
            "name": "Mix Fixture Project",
            "notes": "fixture",
            "createdAt": isoString(Date().addingTimeInterval(-120)),
            "updatedAt": isoString(Date().addingTimeInterval(-60)),
        ]
        try writeFixtureFile(
            in: projectURL,
            relativePath: "Metadata/project.json",
            data: try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
        )

        for (index, sceneDefinition) in sceneDefinitions.enumerated() {
            try writeFixtureSong(
                in: projectURL,
                relativePath: sceneDefinition.0,
                title: sceneDefinition.1,
                orderIndex: index
            )
        }

        return FixtureMixProject(
            rootURL: rootURL,
            projectURL: projectURL,
            scenePaths: sceneDefinitions.map(\.0)
        )
    }

    private func writeFixtureSong(
        in projectURL: URL,
        relativePath: String,
        title: String,
        orderIndex: Int
    ) throws {
        let versionID = UUID()
        let timestamp = isoString(Date().addingTimeInterval(TimeInterval(orderIndex * 10)))
        let root: [String: Any] = [
            "songID": UUID().uuidString,
            "title": title,
            "canonicalTitle": title.lowercased(),
            "notes": "",
            "updatedAt": timestamp,
            "activeVersionID": versionID.uuidString,
            "versions": [[
                "id": versionID.uuidString,
                "label": "Version 1",
                "createdAt": timestamp,
                "updatedAt": timestamp,
                "lyrics": "Lyrics for \(title)",
                "saveType": "manual",
                "isBookmarked": false,
                "playback": [
                    "tracks": [],
                    "noteCount": 128,
                    "lengthTicks": 9600,
                ],
            ]],
        ]

        try writeFixtureFile(
            in: projectURL,
            relativePath: relativePath,
            data: try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        )
    }

    private func writeFixtureFile(in projectURL: URL, relativePath: String, data: Data) throws {
        let url = projectURL.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    private func waitForMixDocument(
        in projectURL: URL,
        where predicate: @escaping (MixProjectDocument) -> Bool
    ) async throws -> MixProjectDocument {
        let connection = try await NovotroProjectConnection.open(projectURL: projectURL, preferService: false)
        try await connection.ensureCurrentIndex()
        let decoder = makeMixDecoderEncoder()
        let deadline = Date().addingTimeInterval(5)

        while deadline.timeIntervalSinceNow > 0 {
            if let record = try await connection.loadProjectFile(path: MixStore.mixProjectFile),
               let document = try? decoder.decode(MixProjectDocument.self, from: record.jsonData),
               predicate(document) {
                return document
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        XCTFail("Timed out waiting for persisted mix document")
        throw CancellationError()
    }

    private func waitUntil(
        timeout: TimeInterval,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while deadline.timeIntervalSinceNow > 0 {
            if condition() {
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTFail("Timed out waiting for condition")
        throw CancellationError()
    }

    private func makeMixDecoderEncoder() -> JSONCoder {
        JSONCoder()
    }

    private func makeSilentWAV(named stem: String, durationSeconds: Double = 1.0) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(stem).wav")
        let sampleRate = 44_100.0
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw XCTestError(.failureWhileWaiting, userInfo: [NSLocalizedDescriptionKey: "Could not create AVAudioFormat for silent WAV fixture"])
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let frameCount = AVAudioFrameCount(sampleRate * max(durationSeconds, 0.001))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
            throw XCTestError(.failureWhileWaiting, userInfo: [NSLocalizedDescriptionKey: "Could not create AVAudioPCMBuffer for silent WAV fixture"])
        }
        buffer.frameLength = frameCount
        if let channel = buffer.floatChannelData?[0] {
            for index in 0..<Int(frameCount) {
                channel[index] = 0
            }
        }
        try file.write(from: buffer)
        return url
    }

    private struct FixtureMixProject {
        let rootURL: URL
        let projectURL: URL
        let scenePaths: [String]
    }

    private final class JSONCoder {
        let decoder: JSONDecoder
        let encoder: JSONEncoder

        init() {
            decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
        }

        func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
            try decoder.decode(type, from: data)
        }

        func encode<T: Encodable>(_ value: T) throws -> Data {
            try encoder.encode(value)
        }
    }

    private func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
