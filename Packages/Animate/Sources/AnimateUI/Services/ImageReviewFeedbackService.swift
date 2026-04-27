import CryptoKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
struct ImageReviewFeedbackAnalysisSnapshot: Codable, Sendable, Hashable {
    var isIndexed: Bool
    var modelID: String?
    var shortCaption: String?
    var summary: String?
    var entitiesJSON: String?
    var sceneJSON: String?
    var cameraJSON: String?
    var styleJSON: String?
    var retrievalJSON: String?
}

@available(macOS 26.0, *)
struct ImageReviewFeedbackArtifact: Codable, Sendable, Hashable, Identifiable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID
    var imageKey: String
    var imagePath: String
    var projectRelativePath: String?
    var source: String
    var originLabel: String
    var groupLabel: String
    var sceneID: UUID?
    var shotID: UUID?
    var rating: Int?
    var isRejected: Bool
    var notes: String
    var updatedAt: Date
    var analysis: ImageReviewFeedbackAnalysisSnapshot?
}

@available(macOS 26.0, *)
enum ImageReviewFeedbackService {
    @MainActor
    static func recordFeedback(
        store: AnimateStore,
        projectRoot: URL?,
        record: ProjectImageRecord,
        metadata: ImageLibraryReviewMetadata
    ) {
        guard let projectRoot else { return }
        let trimmedNotes = metadata.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard metadata.isRejected || metadata.rating != nil || !trimmedNotes.isEmpty else {
            removeFeedback(projectRoot: projectRoot, imagePath: record.resolvedPath)
            return
        }

        let imagePath = record.resolvedPath
        Task { @MainActor in
            let lookup = await store.imageIntelligenceRecordAndMetadata(for: imagePath)
            let snapshot = ImageReviewFeedbackAnalysisSnapshot(
                isIndexed: lookup.isIndexed,
                modelID: lookup.metadata?.modelID,
                shortCaption: lookup.metadata?.shortCaption,
                summary: lookup.metadata?.summary,
                entitiesJSON: lookup.metadata?.entitiesJSON,
                sceneJSON: lookup.metadata?.sceneJSON,
                cameraJSON: lookup.metadata?.cameraJSON,
                styleJSON: lookup.metadata?.styleJSON,
                retrievalJSON: lookup.metadata?.retrievalJSON
            )
            let artifact = ImageReviewFeedbackArtifact(
                id: UUID(),
                imageKey: imageKey(for: imagePath),
                imagePath: imagePath,
                projectRelativePath: relativePath(imagePath, projectRoot: projectRoot),
                source: record.source.rawValue,
                originLabel: record.originLabel,
                groupLabel: record.groupLabel,
                sceneID: record.sceneID,
                shotID: record.shotID,
                rating: metadata.rating,
                isRejected: metadata.isRejected,
                notes: metadata.notes,
                updatedAt: metadata.updatedAt ?? Date(),
                analysis: snapshot
            )
            writeFeedback(artifact, projectRoot: projectRoot)
        }
    }

    static func relevantFeedback(projectRoot: URL, query: String, limit: Int = 8) -> [ImageReviewFeedbackArtifact] {
        let terms = Set(query.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 2 })
        guard !terms.isEmpty else { return [] }
        let artifacts = loadAllFeedback(projectRoot: projectRoot)
        var scored: [(artifact: ImageReviewFeedbackArtifact, score: Int)] = []
        for artifact in artifacts {
            var parts: [String] = [artifact.notes, artifact.originLabel, artifact.groupLabel]
            if let analysis = artifact.analysis {
                parts.append(contentsOf: [
                    analysis.shortCaption ?? "",
                    analysis.summary ?? "",
                    analysis.entitiesJSON ?? "",
                    analysis.sceneJSON ?? "",
                    analysis.cameraJSON ?? "",
                    analysis.styleJSON ?? "",
                    analysis.retrievalJSON ?? ""
                ])
            }
            let haystack = parts.joined(separator: "\n").lowercased()
            var score = 0
            for term in terms where haystack.contains(term) {
                score += 1
            }
            if score > 0 {
                scored.append((artifact, score))
            }
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                return lhs.artifact.updatedAt > rhs.artifact.updatedAt
            }
            .prefix(max(1, limit))
            .map { $0.artifact }
    }

    static func promptClauses(from artifacts: [ImageReviewFeedbackArtifact]) -> [String] {
        artifacts.compactMap { artifact in
            let notes = artifact.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !notes.isEmpty else { return nil }
            let verdict = artifact.isRejected ? "Rejected image feedback" : "Review feedback"
            return "\(verdict) from \(artifact.originLabel): \(notes)"
        }
    }

    private static func writeFeedback(_ artifact: ImageReviewFeedbackArtifact, projectRoot: URL) {
        do {
            let dir = feedbackDirectory(projectRoot: projectRoot)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = feedbackURL(projectRoot: projectRoot, imagePath: artifact.imagePath)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(artifact).write(to: url, options: .atomic)
            try writeIndex(projectRoot: projectRoot)
        } catch {
            NSLog("ImageReviewFeedbackService write failed: \(error.localizedDescription)")
        }
    }

    private static func removeFeedback(projectRoot: URL, imagePath: String) {
        let url = feedbackURL(projectRoot: projectRoot, imagePath: imagePath)
        try? FileManager.default.removeItem(at: url)
        try? writeIndex(projectRoot: projectRoot)
    }

    private static func writeIndex(projectRoot: URL) throws {
        let artifacts = loadAllFeedback(projectRoot: projectRoot).sorted { $0.updatedAt > $1.updatedAt }
        let indexURL = feedbackDirectory(projectRoot: projectRoot).appendingPathComponent("feedback-index.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(artifacts).write(to: indexURL, options: .atomic)
    }

    static func loadAllFeedback(projectRoot: URL) -> [ImageReviewFeedbackArtifact] {
        let dir = feedbackDirectory(projectRoot: projectRoot)
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls
            .filter { $0.pathExtension == "json" && $0.lastPathComponent != "feedback-index.json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(ImageReviewFeedbackArtifact.self, from: data)
            }
    }

    private static func feedbackDirectory(projectRoot: URL) -> URL {
        ProjectPaths(root: projectRoot).metadata
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("image-feedback", isDirectory: true)
    }

    private static func feedbackURL(projectRoot: URL, imagePath: String) -> URL {
        feedbackDirectory(projectRoot: projectRoot).appendingPathComponent("\(imageKey(for: imagePath)).json")
    }

    private static func imageKey(for path: String) -> String {
        SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func relativePath(_ path: String, projectRoot: URL) -> String? {
        let root = projectRoot.standardizedFileURL.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasPrefix(root + "/") else { return nil }
        return String(standardized.dropFirst(root.count + 1))
    }
}
