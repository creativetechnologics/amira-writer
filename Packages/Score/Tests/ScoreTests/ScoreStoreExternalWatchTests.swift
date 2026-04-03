import Foundation
import ProjectKit
import Testing
@testable import ScoreUI

@MainActor
@Suite("Score Store External Watch")
struct ScoreStoreExternalWatchTests {
    @Test func packageReloadsLyricsChangesWithoutReopen() async throws {
        guard #available(macOS 26.0, *) else { return }
        let projectURL = try makeScoreProjectPackage()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let store = ScoreStore()
        defer {
            store.stopPlayback()
            store.suspendBackgroundWork()
        }

        await store.loadProject(url: projectURL, preferService: false)

        try writeScoreSong(
            at: projectURL.appendingPathComponent("Songs/01 Opening.ows"),
            title: "Opening",
            lyrics: "Agent rewrite",
            updatedAt: Date(timeIntervalSinceNow: 120)
        )

        try await waitUntil {
            store.librettoFiles.first(where: { $0.relativePath == "Songs/01 Opening.ows" })?.content == "Agent rewrite"
        }

        #expect(store.librettoFiles.first?.content == "Agent rewrite")
    }

    @Test func packageReloadsSongMembershipChangesWithoutReopen() async throws {
        guard #available(macOS 26.0, *) else { return }
        let projectURL = try makeScoreProjectPackage()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let store = ScoreStore()
        defer {
            store.stopPlayback()
            store.suspendBackgroundWork()
        }

        await store.loadProject(url: projectURL, preferService: false)

        let songsURL = projectURL.appendingPathComponent("Songs", isDirectory: true)
        try writeScoreSong(
            at: songsURL.appendingPathComponent("02 Finale.ows"),
            title: "Finale",
            lyrics: "Finale lyrics",
            updatedAt: Date(timeIntervalSinceNow: 120)
        )

        try await waitUntil {
            store.songStubs.map(\.relativePath) == [
                "Songs/01 Opening.ows",
                "Songs/02 Finale.ows",
            ] && store.librettoFiles.first(where: { $0.relativePath == "Songs/02 Finale.ows" })?.content == "Finale lyrics"
        }

        try FileManager.default.removeItem(at: songsURL.appendingPathComponent("01 Opening.ows"))

        try await waitUntil {
            store.songStubs.map(\.relativePath) == ["Songs/02 Finale.ows"]
        }

        #expect(store.songAssets.map(\.relativePath) == ["Songs/02 Finale.ows"])
        #expect(store.librettoFiles.map(\.relativePath) == ["Songs/02 Finale.ows"])
    }

    @Test func selectedSongCanBeReloadedFromSourceToRefreshPlayback() async throws {
        guard #available(macOS 26.0, *) else { return }
        let projectURL = try makeScoreProjectPackage()
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let store = ScoreStore()
        defer {
            store.stopPlayback()
            store.suspendBackgroundWork()
        }

        await store.loadProject(url: projectURL, preferService: false)
        #expect(store.pianoRollNotes.isEmpty)

        try writeScoreSong(
            at: projectURL.appendingPathComponent("Songs/01 Opening.ows"),
            title: "Opening",
            lyrics: "Before",
            updatedAt: Date(timeIntervalSinceNow: 120),
            playback: testPlaybackSnapshot()
        )

        store.reloadSelectedSongFromSource(forceRebuildIndex: true)
        try await waitUntil {
            store.pianoRollNotes.count == 1
        }

        #expect(store.pianoRollNotes.count == 1)
        #expect(store.pianoRollTrackNames[0] == "Lead")
    }

    @Test func selectedSongHydrationPrefersDiskPlaybackOverStaleDatabasePlayback() async throws {
        guard #available(macOS 26.0, *) else { return }
        let projectURL = try makeScoreProjectPackage(
            playback: testPlaybackSnapshot()
        )
        defer { try? FileManager.default.removeItem(at: projectURL.deletingLastPathComponent()) }

        let database = ProjectDatabase(projectURL: projectURL)
        try await database.ensureCurrentIndex()
        guard var scene = try await database.loadScene(relativePath: "Songs/01 Opening.ows"),
              let activeVersionID = scene.activeVersionID,
              let versionIndex = scene.versions.firstIndex(where: { $0.id == activeVersionID }) else {
            Issue.record("Failed to load indexed scene")
            return
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        scene.versions[versionIndex].playbackJSON = try encoder.encode(OWSPlaybackSnapshot())
        scene.versions[versionIndex].noteCount = 0
        scene.versions[versionIndex].lengthTicks = 3840
        try await database.upsertScene(scene, actorID: "test")

        let store = ScoreStore()
        defer {
            store.stopPlayback()
            store.suspendBackgroundWork()
        }

        await store.loadProject(url: projectURL, preferService: false)
        try await waitUntil {
            store.pianoRollNotes.count == 1
        }

        #expect(store.pianoRollNotes.count == 1)
        #expect(store.pianoRollTrackNames[0] == "Lead")
    }
}

private func makeScoreProjectPackage(playback: [String: Any]? = nil) throws -> URL {
    let fm = FileManager.default
    let baseRoot = URL(fileURLWithPath: fm.currentDirectoryPath)
        .appendingPathComponent(".build/score-watch-tests", isDirectory: true)
    try fm.createDirectory(at: baseRoot, withIntermediateDirectories: true)
    let root = baseRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
    let projectURL = root.appendingPathComponent("ScoreWatchTest.owp", isDirectory: true)
    let songsURL = projectURL.appendingPathComponent("Songs", isDirectory: true)
    let metadataURL = projectURL.appendingPathComponent("Metadata", isDirectory: true)
    try fm.createDirectory(at: songsURL, withIntermediateDirectories: true)
    try fm.createDirectory(at: metadataURL, withIntermediateDirectories: true)

    let metadata = ProjectMetadata(
        name: "Score Watch Test",
        createdAt: Date(timeIntervalSince1970: 1),
        updatedAt: Date(timeIntervalSince1970: 2),
        notes: ""
    )
    try scoreMetadataEncoder().encode(metadata).write(
        to: projectURL.appendingPathComponent(OWPProjectIO.projectMetadataFile),
        options: .atomic
    )

    try writeScoreSong(
        at: songsURL.appendingPathComponent("01 Opening.ows"),
        title: "Opening",
        lyrics: "Before",
        updatedAt: Date(timeIntervalSince1970: 5),
        playback: playback
    )

    return projectURL
}

private func writeScoreSong(
    at url: URL,
    title: String,
    lyrics: String,
    updatedAt: Date,
    playback: [String: Any]? = nil
) throws {
    let formatter = scoreISOFormatter()
    let songID: String = {
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let existingSongID = root["songID"] as? String,
              !existingSongID.isEmpty else {
            return UUID().uuidString
        }
        return existingSongID
    }()
    let versionID = UUID()
    var version: [String: Any] = [
        "id": versionID.uuidString,
        "label": "Version 1",
        "createdAt": formatter.string(from: updatedAt),
        "updatedAt": formatter.string(from: updatedAt),
        "lyrics": lyrics,
        "saveType": "manual",
        "isBookmarked": false,
    ]
    if let playback {
        version["playback"] = playback
        version["playbackSnapshot"] = playback
    }

    let json: [String: Any] = [
        "songID": songID,
        "title": title,
        "canonicalTitle": title.lowercased(),
        "notes": "",
        "updatedAt": formatter.string(from: updatedAt),
        "activeVersionID": versionID.uuidString,
        "versions": [version],
    ]

    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: updatedAt], ofItemAtPath: url.path)
}

private func waitUntil(
    timeout: TimeInterval = 8,
    pollIntervalNanoseconds: UInt64 = 50_000_000,
    condition: @escaping @MainActor () -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await MainActor.run(body: condition) {
            return
        }
        try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
    }

    throw WatchTestTimeoutError()
}

private struct WatchTestTimeoutError: Error {}

private func scoreMetadataEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return encoder
}

private func scoreISOFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}

private func testPlaybackSnapshot() -> [String: Any] {
    [
        "notes": [[
            "id": UUID().uuidString,
            "trackIndex": 0,
            "channel": 0,
            "pitch": 60,
            "velocity": 100,
            "startTick": 0,
            "duration": 480,
            "muted": false,
        ]],
        "trackNames": ["0": "Lead"],
        "channelPrograms": ["0": 1],
        "trackChannelPrograms": ["0": ["0": 1]],
        "lyricCues": [],
        "audioClips": [],
        "tempoEvents": [],
        "ticksPerQuarter": 480,
        "lengthTicks": 960,
        "initialTempoBPM": 120,
    ]
}
