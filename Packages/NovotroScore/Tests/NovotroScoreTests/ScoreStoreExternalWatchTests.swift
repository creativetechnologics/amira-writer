import Foundation
import Testing
@testable import NovotroScoreUI

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
}

private func makeScoreProjectPackage() throws -> URL {
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
        updatedAt: Date(timeIntervalSince1970: 5)
    )

    return projectURL
}

private func writeScoreSong(at url: URL, title: String, lyrics: String, updatedAt: Date) throws {
    let formatter = scoreISOFormatter()
    let versionID = UUID()
    let json: [String: Any] = [
        "songID": UUID().uuidString,
        "title": title,
        "canonicalTitle": title.lowercased(),
        "notes": "",
        "updatedAt": formatter.string(from: updatedAt),
        "activeVersionID": versionID.uuidString,
        "versions": [[
            "id": versionID.uuidString,
            "label": "Version 1",
            "createdAt": formatter.string(from: updatedAt),
            "updatedAt": formatter.string(from: updatedAt),
            "lyrics": lyrics,
            "saveType": "manual",
            "isBookmarked": false,
        ]],
    ]

    let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
    try data.write(to: url, options: .atomic)
    try FileManager.default.setAttributes([.modificationDate: updatedAt], ofItemAtPath: url.path)
}

private func waitUntil(
    timeout: TimeInterval = 3,
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
