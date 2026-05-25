import Foundation
import ProjectKit

/// Manages saving and loading MotionClip files in the OWP project bundle.
///
/// Storage layout:
///   <project>.owp/Animate/motion-clips/clip-<uuid>.json
///
@available(macOS 26.0, *)
struct MotionClipPersistence: Sendable {

    // MARK: - Directory

    /// Returns the motion-clips directory, creating it if needed.
    static func clipsDirectory(animateURL: URL) throws -> URL {
        let dir = ProjectPaths(root: animateURL.deletingLastPathComponent()).animateMotionClips
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Filename for a clip on disk.
    static func filename(for clipID: UUID) -> String {
        "clip-\(clipID.uuidString).json"
    }

    // MARK: - Save

    /// Save a single clip to disk.
    static func save(_ clip: MotionClip, animateURL: URL) throws {
        let dir = try clipsDirectory(animateURL: animateURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(clip)
        let fileURL = dir.appendingPathComponent(filename(for: clip.id))
        try data.write(to: fileURL, options: .atomic)
    }

    /// Save multiple clips (batch).
    static func saveAll(_ clips: [MotionClip], animateURL: URL) throws {
        for clip in clips {
            try save(clip, animateURL: animateURL)
        }
    }

    // MARK: - Load

    /// Load all clips from the motion-clips directory.
    static func loadAll(animateURL: URL) throws -> [MotionClip] {
        let dir = ProjectPaths(root: animateURL.deletingLastPathComponent()).animateMotionClips
        let fm = FileManager.default
        guard fm.fileExists(atPath: dir.path) else { return [] }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let files = try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" && $0.lastPathComponent.hasPrefix("clip-") }

        var clips: [MotionClip] = []
        for fileURL in files {
            do {
                let data = try Data(contentsOf: fileURL)
                let clip = try decoder.decode(MotionClip.self, from: data)
                clips.append(clip)
            } catch {
                print("[MotionClipPersistence] Failed to load \(fileURL.lastPathComponent): \(error)")
            }
        }

        return clips.sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - Delete

    /// Delete a clip file from disk.
    static func delete(clipID: UUID, animateURL: URL) throws {
        let dir = ProjectPaths(root: animateURL.deletingLastPathComponent()).animateMotionClips
        let fileURL = dir.appendingPathComponent(filename(for: clipID))
        let fm = FileManager.default
        if fm.fileExists(atPath: fileURL.path) {
            try fm.removeItem(at: fileURL)
        }
    }
}
