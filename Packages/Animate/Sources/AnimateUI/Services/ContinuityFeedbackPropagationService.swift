import Foundation
import ProjectKit

@available(macOS 26.0, *)
struct ContinuityAutoRejectCandidate: Identifiable, Codable, Sendable, Hashable {
    var id: UUID = UUID()
    var imagePath: String
    var projectRelativePath: String?
    var score: Double
    var matchedTerms: [String]
    var reason: String
    var action: String
}

@available(macOS 26.0, *)
struct ContinuityFeedbackPropagationReport: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID
    var createdAt: Date
    var feedbackID: UUID
    var sessionID: UUID
    var turnID: UUID
    var notes: String
    var extractedTerms: [String]
    var autoRejectedCount: Int
    var reviewCandidateCount: Int
    var candidates: [ContinuityAutoRejectCandidate]
    var reportPath: String?
}

@available(macOS 26.0, *)
@MainActor
struct ContinuityFeedbackPropagationService {
    var store: AnimateStore

    func propagate(
        feedback: ContinuityBuilderFeedback,
        turn: ContinuityBuilderTurn,
        selectedCandidate: ContinuityBuilderCandidate?,
        projectRoot: URL
    ) async -> ContinuityFeedbackPropagationReport {
        let terms = Self.extractedTerms(from: feedback.notes, contextTags: turn.contextTags)
        var report = ContinuityFeedbackPropagationReport(
            id: UUID(),
            createdAt: Date(),
            feedbackID: feedback.id,
            sessionID: feedback.sessionID,
            turnID: feedback.turnID,
            notes: feedback.notes,
            extractedTerms: terms,
            autoRejectedCount: 0,
            reviewCandidateCount: 0,
            candidates: [],
            reportPath: nil
        )

        guard Self.shouldPropagateRejection(feedback: feedback), terms.count >= 2 else {
            try? write(report, projectRoot: projectRoot)
            return report
        }

        var seen = Set<String>()
        if let selectedPath = selectedCandidate?.imagePath {
            let resolved = ContinuityBuilderService.runtimePath(selectedPath, projectRoot: projectRoot) ?? selectedPath
            if FileManager.default.fileExists(atPath: resolved) {
                markRejected(path: resolved, feedback: feedback, reason: "Direct Continuity Builder feedback on selected candidate.")
                seen.insert(URL(fileURLWithPath: resolved).standardizedFileURL.path)
                report.candidates.append(.init(
                    imagePath: resolved,
                    projectRelativePath: Self.relativePath(resolved, projectRoot: projectRoot),
                    score: 1.0,
                    matchedTerms: terms,
                    reason: "Direct Continuity Builder feedback on selected candidate.",
                    action: "auto_rejected"
                ))
                report.autoRejectedCount += 1
            }
        }

        let queryCandidates = await store.imageIntelligenceContinuityCandidates(matchingTerms: terms, limit: 120)
        let feedbackVector = ContinuityTextVectorizer.vector(for: ([feedback.notes] + turn.contextTags).joined(separator: " "))
        for candidate in queryCandidates {
            let normalizedPath = URL(fileURLWithPath: candidate.resolvedPath).standardizedFileURL.path
            guard !seen.contains(normalizedPath) else { continue }
            let text = candidate.searchableText.lowercased()
            let matched = terms.filter { text.contains($0.lowercased()) }
            let coverage = Double(matched.count) / Double(max(terms.count, 1))
            let vectorScore = ContinuityTextVectorizer.cosine(feedbackVector, ContinuityTextVectorizer.vector(for: candidate.searchableText))
            let score = min(1.0, (coverage * 0.72) + (vectorScore * 0.28))
            let highConfidence = matched.count >= 4 && coverage >= 0.72 && score >= 0.76
            let reviewWorthy = matched.count >= 2 && score >= 0.45
            guard highConfidence || reviewWorthy else { continue }

            let reason = highConfidence
                ? "High-confidence match to Continuity Builder mistake feedback."
                : "Possible match to Continuity Builder mistake feedback; held for manual review."
            if highConfidence {
                markRejected(path: candidate.resolvedPath, feedback: feedback, reason: reason)
                report.autoRejectedCount += 1
            } else {
                report.reviewCandidateCount += 1
            }
            report.candidates.append(.init(
                imagePath: candidate.resolvedPath,
                projectRelativePath: candidate.projectRelativePath ?? Self.relativePath(candidate.resolvedPath, projectRoot: projectRoot),
                score: score,
                matchedTerms: matched,
                reason: reason,
                action: highConfidence ? "auto_rejected" : "needs_manual_review"
            ))
            seen.insert(normalizedPath)
            if report.autoRejectedCount >= 20 { break }
        }

        try? write(report, projectRoot: projectRoot)
        return report
    }

    private func markRejected(path: String, feedback: ContinuityBuilderFeedback, reason: String) {
        store.setImageLibraryRejected(true, for: path)
        let existing = ImageLibraryMetadataSidecarService.load(forImagePath: path)
            ?? ImageLibraryReviewMetadata(rating: nil, isRejected: false, notes: "", updatedAt: nil)
        let noteLine = "Auto-rejected by Continuity Builder: \(reason) Feedback: \(feedback.notes)"
        let notes = [existing.notes, noteLine]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        let metadata = ImageLibraryReviewMetadata(
            rating: existing.rating,
            isRejected: true,
            notes: notes,
            updatedAt: Date(),
            characterTags: existing.characterTags,
            visualStyle: existing.visualStyle
        )
        ImageLibraryMetadataSidecarService.save(metadata, forImagePath: path)
    }

    private func write(_ report: ContinuityFeedbackPropagationReport, projectRoot: URL) throws {
        let dir = ContinuityBuilderService.continuityDirectory(projectRoot: projectRoot)
            .appendingPathComponent("auto-rejections", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(report.id.uuidString).json")
        var copy = report
        copy.reportPath = url.path
        try writeCodable(copy, to: url)
    }

    private static func shouldPropagateRejection(feedback: ContinuityBuilderFeedback) -> Bool {
        let lower = feedback.notes.lowercased()
        let negativeMarkers = [
            "wrong", "bad", "reject", "rejected", "incorrect", "mistake", "problem",
            "too close", "too many", "should not", "doesn't", "does not", "not supposed",
            "off", "drift", "fix", "missing"
        ]
        return feedback.closenessPercent <= 45 || negativeMarkers.contains(where: lower.contains)
    }

    private static func extractedTerms(from notes: String, contextTags: [String]) -> [String] {
        _ = contextTags
        let stop: Set<String> = [
            "this", "that", "with", "from", "have", "there", "their", "image", "picture",
            "looks", "look", "should", "would", "could", "because", "really", "wrong",
            "good", "bad", "very", "much", "more", "less", "thing", "things", "same"
        ]
        let noteTerms = notes.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 3 && !stop.contains($0) }
        return Array(Set(noteTerms)).sorted()
    }

    private static func relativePath(_ path: String, projectRoot: URL) -> String? {
        let root = projectRoot.standardizedFileURL.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasPrefix(root + "/") else { return nil }
        return String(standardized.dropFirst(root.count + 1))
    }
}
