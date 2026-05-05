import Foundation
import ProjectKit

@available(macOS 26.0, *)
enum ActiveShotCardSource {
    static func activeLyricsText(for scene: AnimationScene, projectRoot: URL) -> String? {
        guard let songPath = sceneSongPath(scene) else { return nil }
        let songURL = projectRoot.appendingPathComponent(songPath)
        guard let data = try? Data(contentsOf: songURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let versions = root["versions"] as? [[String: Any]],
              !versions.isEmpty else {
            return nil
        }

        let activeID = (root["activeVersionID"] as? String)?.uppercased()
        let selectedVersion: [String: Any] = activeID.flatMap { id in
            versions.first { (($0["id"] as? String) ?? "").uppercased() == id }
        } ?? versions[versions.count - 1]

        if let lyrics = selectedVersion["lyrics"] as? String, !lyrics.isEmpty {
            return lyrics
        }
        if let lyrics = selectedVersion["librettoText"] as? String, !lyrics.isEmpty {
            return lyrics
        }
        if let snapshot = selectedVersion["playbackSnapshot"] as? [String: Any] {
            if let lyrics = snapshot["lyrics"] as? String, !lyrics.isEmpty {
                return lyrics
            }
            if let lyrics = snapshot["librettoText"] as? String, !lyrics.isEmpty {
                return lyrics
            }
            if let lines = snapshot["lyricsLines"] as? [String], !lines.isEmpty {
                return lines.joined(separator: "\n")
            }
        }
        return nil
    }

    static func cameraDirections(for scene: AnimationScene, projectRoot: URL) -> [SceneDirection] {
        guard let lyrics = activeLyricsText(for: scene, projectRoot: projectRoot),
              !lyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        return SceneDirectionParser.parse(lyrics).directions.filter { $0.tag == .camera }
    }

    static func sceneSongPath(_ scene: AnimationScene) -> String? {
        let direct = scene.owpSongPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !direct.isEmpty {
            return direct
        }
        if let legacy = Mirror(reflecting: scene).children.first(where: { $0.label == "owsSongPath" })?.value as? String {
            let trimmed = legacy.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }
        return nil
    }

    static func normalizedLabel(_ value: String?) -> String {
        (value ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

@available(macOS 26.0, *)
@MainActor
struct ShotCardProjectionAuditService {
    var store: AnimateStore

    func audit(projectRoot: URL, sceneFilter: Set<UUID>? = nil) -> ShotCardProjectionAuditReport {
        let scenes = store.scenes.filter { sceneFilter?.contains($0.id) ?? true }
        let issues = scenes.compactMap { auditIssue(scene: $0, projectRoot: projectRoot) }
        let activeCount = scenes.reduce(0) {
            $0 + ActiveShotCardSource.cameraDirections(for: $1, projectRoot: projectRoot).count
        }
        let storedCount = scenes.reduce(0) { $0 + $1.shots.count }
        return ShotCardProjectionAuditReport(
            projectRoot: projectRoot.path,
            sceneCount: scenes.count,
            storedShotCount: storedCount,
            activeCameraCardCount: activeCount,
            issues: issues
        )
    }

    func auditIssue(scene: AnimationScene, projectRoot: URL) -> ShotCardProjectionIssue? {
        let directions = ActiveShotCardSource.cameraDirections(for: scene, projectRoot: projectRoot)
        guard !directions.isEmpty else { return nil }

        var mismatched: [Int] = []
        let sharedCount = min(scene.shots.count, directions.count)
        for index in 0..<sharedCount {
            let shot = scene.shots[index]
            let direction = directions[index]
            let storedLine = shot.sourceLineNumber
            let storedLabel = ActiveShotCardSource.normalizedLabel(shot.name)
            let activeLabel = ActiveShotCardSource.normalizedLabel(direction.parameters["label"] ?? "")
            let lineMatches = storedLine == direction.sourceLineNumber
            let labelMatches = !storedLabel.isEmpty && !activeLabel.isEmpty && storedLabel == activeLabel
            if !lineMatches && !labelMatches {
                mismatched.append(index)
            }
        }

        guard scene.shots.count != directions.count || !mismatched.isEmpty else { return nil }
        let songPath = ActiveShotCardSource.sceneSongPath(scene) ?? scene.owpSongPath
        let message = "Stored scene shot projection for \(scene.name) is stale: Scenes/scenes.json has \(scene.shots.count) shots, active .ows camera cards have \(directions.count). Sync shot projections before image generation."
        return ShotCardProjectionIssue(
            sceneID: scene.id,
            sceneName: scene.name,
            songPath: songPath,
            storedShotCount: scene.shots.count,
            activeCameraCardCount: directions.count,
            mismatchedIndices: mismatched,
            blocker: .init(
                code: .blockedStaleShotProjection,
                message: message,
                field: "Scenes/scenes.json"
            )
        )
    }
}

@available(macOS 26.0, *)
enum ShotDirectorInputStore {
    static func inputURL(projectRoot: URL, sceneID: UUID, shotID: UUID) -> URL {
        projectRoot
            .appendingPathComponent("Animate", isDirectory: true)
            .appendingPathComponent("director-inputs", isDirectory: true)
            .appendingPathComponent(sceneID.uuidString, isDirectory: true)
            .appendingPathComponent("\(shotID.uuidString).json")
    }

    static func read(projectRoot: URL, sceneID: UUID, shotID: UUID) -> ShotDirectorInputRecord? {
        let url = inputURL(projectRoot: projectRoot, sceneID: sceneID, shotID: shotID)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ShotDirectorInputRecord.self, from: data)
    }

    static func write(_ record: ShotDirectorInputRecord, projectRoot: URL) throws -> URL {
        let url = inputURL(projectRoot: projectRoot, sceneID: record.sceneID, shotID: record.shotID)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try writeCodable(record, to: url)
        return url
    }

    static func acceptedNotes(for record: ShotDirectorInputRecord?) -> String? {
        guard let record, record.isAccepted else { return nil }
        let note = joinedNonEmpty([
            record.proposedAction,
            record.proposedCamera,
            record.proposedBlocking,
            record.proposedNotes,
            record.transcriptText
        ], separator: " ")
        return note.isEmpty ? nil : note
    }
}
