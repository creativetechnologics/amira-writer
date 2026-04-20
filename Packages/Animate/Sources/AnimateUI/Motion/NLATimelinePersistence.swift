import Foundation
import ProjectKit

/// Handles reading and writing NLATimeline JSON files.
/// Storage path: `<project>.owp/Animate/motion-timeline-<sceneID>.json`
@available(macOS 26.0, *)
struct NLATimelinePersistence: Sendable {

    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }()

    private static let decoder = JSONDecoder()

    /// Build the file URL for a scene's NLA timeline.
    static func fileURL(animateDir: URL, sceneID: UUID) -> URL {
        ProjectPaths(root: animateDir.deletingLastPathComponent()).animateMotionTimelineJSON(sceneID: sceneID.uuidString)
    }

    /// Load an NLA timeline from disk. Returns nil if the file does not exist.
    static func load(animateDir: URL, sceneID: UUID) throws -> NLATimeline? {
        let url = fileURL(animateDir: animateDir, sceneID: sceneID)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(NLATimeline.self, from: data)
    }

    /// Save an NLA timeline to disk. Creates the file if it does not exist.
    static func save(timeline: NLATimeline, animateDir: URL, sceneID: UUID) throws {
        let url = fileURL(animateDir: animateDir, sceneID: sceneID)
        let data = try encoder.encode(timeline)
        try data.write(to: url, options: .atomic)
    }

    /// Delete the NLA timeline file for a scene.
    static func delete(animateDir: URL, sceneID: UUID) throws {
        let url = fileURL(animateDir: animateDir, sceneID: sceneID)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
