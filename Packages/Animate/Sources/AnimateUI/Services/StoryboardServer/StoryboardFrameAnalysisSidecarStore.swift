import Foundation
import ProjectKit

// MARK: - StoryboardFrameAnalysisSidecarStore
//
// Writes the lightweight analysis sidecar that makes a freshly saved iPad
// storyboard frame visible to the future storyboard-intelligence pipeline.
// This is deliberately local/deterministic: AI analysis can fill the same file
// later, but the save path should immediately leave a pending, hash-stamped
// record without blocking the iPad response.

@available(macOS 26.0, *)
enum StoryboardFrameAnalysisSidecarStore {

    struct Context: Sendable {
        var sceneID: UUID
        var sceneName: String
        var shotID: UUID
        var shotName: String
        var frame: StoryboardFrame
        var promptContext: StoryboardAnalysisPromptContext?
    }

    static func writePendingAnalysisAsync(
        projectRoot: URL,
        imageURL: URL,
        context: Context
    ) {
        Task.detached(priority: .utility) {
            do {
                try writePendingAnalysis(
                    projectRoot: projectRoot,
                    imageURL: imageURL,
                    context: context
                )
            } catch {
                NSLog("[StoryboardAnalysis] Failed to write pending sidecar for %@: %@",
                      imageURL.path,
                      error.localizedDescription)
            }
        }
    }

    static func writePendingAnalysis(
        projectRoot: URL,
        imageURL: URL,
        context: Context
    ) throws {
        let paths = ProjectPaths(root: projectRoot)
        let analysisURL = paths.shotStoryboardAnalysisJSON(
            sceneID: context.sceneID,
            shotID: context.shotID,
            frame: context.frame
        )
        try FileManager.default.createDirectory(
            at: analysisURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let existing = try? load(from: analysisURL)
        let inspection = ImageAssetInspector.inspect(path: imageURL.path)
        let now = Date()
        let relativePath = projectRelativePath(for: imageURL, projectRoot: projectRoot)
        let sameSourceImage = existing?.contentHash == inspection.contentHashSHA256

        let timestamps = StoryboardFrameAnalysisTimestamps(
            createdAt: existing?.timestamps.createdAt ?? now,
            updatedAt: now,
            analyzedAt: sameSourceImage ? existing?.timestamps.analyzedAt : nil,
            reviewedAt: sameSourceImage ? existing?.timestamps.reviewedAt : nil
        )
        let analysisPrompt = context.promptContext.map {
            StoryboardAnalysisPromptBuilder.buildPrompt(context: $0)
        }

        let analysis = StoryboardFrameAnalysis(
            sceneID: context.sceneID,
            shotID: context.shotID,
            frame: context.frame,
            imagePath: imageURL.path,
            projectRelativePath: relativePath,
            contentHash: inspection.contentHashSHA256,
            status: sameSourceImage ? (existing?.status ?? .pending) : .pending,
            summary: sameSourceImage
                ? existing?.summary
                : "Storyboard \(context.frame.rawValue) frame saved for \(context.sceneName) / \(context.shotName); analysis pending.",
            detectedEntities: sameSourceImage ? (existing?.detectedEntities ?? []) : [],
            compositionGrid: sameSourceImage ? existing?.compositionGrid : nil,
            cameraRead: sameSourceImage ? existing?.cameraRead : nil,
            conflicts: sameSourceImage ? (existing?.conflicts ?? []) : [],
            timestamps: timestamps,
            analysisPrompt: analysisPrompt ?? (sameSourceImage ? existing?.analysisPrompt : nil)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(analysis)
        try data.write(to: analysisURL, options: .atomic)
    }

    private static func load(from url: URL) throws -> StoryboardFrameAnalysis {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(StoryboardFrameAnalysis.self, from: Data(contentsOf: url))
    }

    private static func projectRelativePath(for url: URL, projectRoot: URL) -> String? {
        let path = url.standardizedFileURL.path
        var root = projectRoot.standardizedFileURL.path
        if !root.hasSuffix("/") { root += "/" }
        guard path.hasPrefix(root) else { return nil }
        return String(path.dropFirst(root.count))
    }
}
