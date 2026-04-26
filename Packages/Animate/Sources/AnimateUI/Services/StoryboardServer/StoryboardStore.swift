import Foundation
import ProjectKit

// MARK: - StoryboardStore
//
// Disk read/write for storyboard panel images. All writes are atomic:
// data is written to a `.tmp` sibling, then renamed into place so a
// crashed mid-write never leaves a corrupt PNG.

@available(macOS 26.0, *)
final class StoryboardStore: Sendable {

    func imageURL(projectRoot: URL, sceneID: UUID, shotID: UUID, frame: StoryboardFrame) -> URL {
        let paths = ProjectPaths(root: projectRoot)
        return paths.shotStoryboardImage(sceneID: sceneID, shotID: shotID, frame: frame)
    }

    func exists(projectRoot: URL, sceneID: UUID, shotID: UUID, frame: StoryboardFrame) -> Bool {
        let url = imageURL(projectRoot: projectRoot, sceneID: sceneID, shotID: shotID, frame: frame)
        return FileManager.default.fileExists(atPath: url.path)
    }

    func read(projectRoot: URL, sceneID: UUID, shotID: UUID, frame: StoryboardFrame) -> Data? {
        let url = imageURL(projectRoot: projectRoot, sceneID: sceneID, shotID: shotID, frame: frame)
        return try? Data(contentsOf: url)
    }

    func write(data: Data, projectRoot: URL, sceneID: UUID, shotID: UUID, frame: StoryboardFrame) throws {
        let paths = ProjectPaths(root: projectRoot)
        let dir = paths.shotStoryboardDir(sceneID: sceneID, shotID: shotID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = paths.shotStoryboardImage(sceneID: sceneID, shotID: shotID, frame: frame)
        let tmp = dest.deletingLastPathComponent()
            .appendingPathComponent("\(dest.lastPathComponent).tmp")
        try data.write(to: tmp, options: .atomic)
        _ = try FileManager.default.replaceItemAt(dest, withItemAt: tmp)
    }

    func hasFrames(projectRoot: URL, sceneID: UUID, shotID: UUID) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for frame in StoryboardFrame.allCases {
            result[frame.rawValue] = exists(projectRoot: projectRoot, sceneID: sceneID, shotID: shotID, frame: frame)
        }
        return result
    }

    func hasAnalysisSidecars(projectRoot: URL, sceneID: UUID, shotID: UUID) -> [String: Bool] {
        let paths = ProjectPaths(root: projectRoot)
        var result: [String: Bool] = [:]
        for frame in StoryboardFrame.allCases {
            let url = paths.shotStoryboardAnalysisJSON(sceneID: sceneID, shotID: shotID, frame: frame)
            result[frame.rawValue] = FileManager.default.fileExists(atPath: url.path)
        }
        return result
    }
}
