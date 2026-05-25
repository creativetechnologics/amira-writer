import CryptoKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
struct ImagePreferenceProfileArtifact: Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var generatedAt: Date
    var algorithm: ImagePreferenceAlgorithmDescription
    var sourceImageCount: Int
    var reviewedImageCount: Int
    var roleProfiles: [ImagePreferenceRoleProfile]
}

@available(macOS 26.0, *)
struct ImagePreferenceAlgorithmDescription: Codable, Sendable, Hashable {
    var name: String
    var version: Int
    var notes: [String]
}

@available(macOS 26.0, *)
struct ImagePreferenceRoleProfile: Codable, Sendable, Hashable {
    var role: ImageLibrarySemanticRole
    var reviewedCount: Int
    var acceptedCount: Int
    var rejectedCount: Int
    var notedCount: Int
    var averageAcceptedRating: Double?
    var promptMemory: [ImagePreferencePromptMemoryClause]
    var vectorProfiles: [ImagePreferenceVectorProfile]
    var topAcceptedExamples: [ImagePreferenceExample]
    var topRejectedExamples: [ImagePreferenceExample]
}

@available(macOS 26.0, *)
struct ImagePreferencePromptMemoryClause: Codable, Sendable, Hashable {
    enum Polarity: String, Codable, Sendable, Hashable {
        case prefer
        case avoid
        case mixed
    }

    var id: String
    var role: ImageLibrarySemanticRole
    var polarity: Polarity
    var weight: Double
    var text: String
    var tags: [String]
    var sourceImagePath: String
    var rating: Int?
    var isRejected: Bool
    var updatedAt: Date
}

@available(macOS 26.0, *)
struct ImagePreferenceVectorProfile: Codable, Sendable, Hashable {
    var embeddingKind: String
    var dimension: Int
    var acceptedCount: Int
    var rejectedCount: Int
    var acceptedCentroid: [Double]
    var rejectedCentroid: [Double]
    var preferenceDirection: [Double]
}

@available(macOS 26.0, *)
struct ImagePreferenceExample: Codable, Sendable, Hashable {
    var imagePath: String
    var projectRelativePath: String?
    var rating: Int?
    var isRejected: Bool
    var isLiked: Bool?
    var notes: String
    var analysisSummary: String?
    var linkKinds: [String]
}

@available(macOS 26.0, *)
enum ImagePreferenceProfileService {
    @MainActor private static var scheduledRebuildTask: Task<Void, Never>?

    @MainActor
    static func scheduleRebuild(store: AnimateStore, projectRoot: URL?) {
        guard let projectRoot else { return }
        scheduledRebuildTask?.cancel()
        scheduledRebuildTask = Task { [weak store] in
            try? await Task.sleep(for: .milliseconds(900))
            guard !Task.isCancelled, let store else { return }
            _ = try? await rebuildNow(store: store, projectRoot: projectRoot)
        }
    }

    @MainActor
    static func rebuildNow(store: AnimateStore, projectRoot: URL) async throws -> ImagePreferenceProfileArtifact {
        let discovery = ImageAssetDiscoveryService(store: store).discoverAll()
        let samples = await collectSamples(store: store, projectRoot: projectRoot, discoveredAssets: discovery.assets)
        let embeddings = await loadEmbeddingVectors(projectRoot: projectRoot, reviewedPaths: Set(samples.map(\.resolvedPath)))
        let artifact = buildArtifact(samples: samples, embeddingsByPath: embeddings)
        try write(artifact, projectRoot: projectRoot)
        return artifact
    }

    static func latestProfileURL(projectRoot: URL) -> URL {
        profileDirectory(projectRoot: projectRoot).appendingPathComponent("latest.json")
    }

    static func latestProfile(projectRoot: URL) -> ImagePreferenceProfileArtifact? {
        let url = latestProfileURL(projectRoot: projectRoot)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONCoders.makeDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ImagePreferenceProfileArtifact.self, from: data)
    }

    static func relevantPromptClauses(
        projectRoot: URL,
        query: String,
        semanticRoles: [ImageLibrarySemanticRole]? = nil,
        limit: Int = 8
    ) -> [String] {
        guard let profile = latestProfile(projectRoot: projectRoot) else { return [] }
        let queryTerms = terms(from: query)
        let allowedRoles = semanticRoles.map { Set($0) }
        let clauses = profile.roleProfiles
            .filter { profile in
                guard let allowedRoles else { return true }
                return allowedRoles.contains(profile.role)
            }
            .flatMap(\.promptMemory)

        let scored = clauses.map { clause -> (ImagePreferencePromptMemoryClause, Double) in
            let haystack = ([clause.text] + clause.tags).joined(separator: " ").lowercased()
            let matchScore = queryTerms.reduce(0.0) { partial, term in
                partial + (haystack.contains(term) ? 1.0 : 0.0)
            }
            return (clause, matchScore + (clause.weight * 0.10))
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0.updatedAt > rhs.0.updatedAt
        }

        return scored
            .prefix(max(1, limit))
            .compactMap { clause, _ in
                let prefix: String
                switch clause.polarity {
                case .prefer: prefix = "Prefer"
                case .avoid: prefix = "Avoid"
                case .mixed: prefix = "Use"
                }
                return ContinuityPromptMemoryCompiler.visualInstruction(
                    from: clause.text,
                    prefix: prefix,
                    maxCharacters: 180
                )
            }
    }

    static func isPositiveReferenceEligible(_ imagePath: String) -> Bool {
        referencePreferenceScore(forImagePath: imagePath) != nil
    }

    static func referenceRating(forImagePath imagePath: String) -> Int? {
        guard let metadata = ImageLibraryMetadataSidecarService.load(forImagePath: imagePath),
              metadata.isRejected == false,
              let rating = metadata.rating,
              rating > 0 else { return nil }
        return min(max(rating, 1), 5)
    }

    static func referencePreferenceScore(forImagePath imagePath: String) -> Double? {
        guard let metadata = ImageLibraryMetadataSidecarService.load(forImagePath: imagePath),
              metadata.isRejected == false,
              metadata.isLiked else { return nil }
        let rating = metadata.rating.map { Double(min(max($0, 1), 5)) } ?? 0
        return max(5.5, rating + 0.75)
    }

    static func referenceUpdatedAt(forImagePath imagePath: String) -> Date? {
        ImageLibraryMetadataSidecarService.load(forImagePath: imagePath)?.updatedAt
            ?? (try? FileManager.default.attributesOfItem(atPath: imagePath)[.modificationDate] as? Date)
    }

    private struct Sample: Sendable, Hashable {
        var resolvedPath: String
        var projectRelativePath: String?
        var role: ImageLibrarySemanticRole
        var rating: Int?
        var isRejected: Bool
        var isLiked: Bool
        var notes: String
        var updatedAt: Date
        var analysisSummary: String?
        var analysisText: String
        var linkKinds: [String]
    }

    private struct EmbeddingVector: Sendable, Hashable {
        var kind: String
        var dimension: Int
        var vector: [Float]
    }

    private struct PathAggregate {
        var resolvedPath: String
        var projectRelativePath: String?
        var linkKinds: Set<ImageAssetLinkKind> = []
        var inferredRoles: Set<ImageLibrarySemanticRole> = []
    }

    @MainActor
    private static func collectSamples(
        store: AnimateStore,
        projectRoot: URL,
        discoveredAssets: [ImageAssetDiscoveryService.DiscoveredAsset]
    ) async -> [Sample] {
        var aggregates: [String: PathAggregate] = [:]
        for asset in discoveredAssets {
            let path = URL(fileURLWithPath: asset.resolvedPath).standardizedFileURL.path
            var aggregate = aggregates[path] ?? PathAggregate(resolvedPath: path, projectRelativePath: asset.projectRelativePath)
            aggregate.projectRelativePath = aggregate.projectRelativePath ?? asset.projectRelativePath
            aggregate.linkKinds.insert(asset.linkKind)
            if let role = semanticRole(for: asset.linkKind) {
                aggregate.inferredRoles.insert(role)
            }
            aggregates[path] = aggregate
        }

        var samples: [Sample] = []
        for aggregate in aggregates.values.sorted(by: { $0.resolvedPath < $1.resolvedPath }) {
            guard let metadata = ImageLibraryMetadataSidecarService.load(forImagePath: aggregate.resolvedPath) else { continue }
            let notes = metadata.notes.trimmingCharacters(in: .whitespacesAndNewlines)
            let hasReviewSignal = metadata.rating != nil || metadata.isRejected || !notes.isEmpty
            guard hasReviewSignal else { continue }
            let role = metadata.semanticRole ?? aggregate.inferredRoles.sorted(by: { $0.rawValue < $1.rawValue }).first
            guard let role else { continue }

            let lookup = await store.imageIntelligenceRecordAndMetadata(for: aggregate.resolvedPath)
            let analysisParts = [
                lookup.metadata?.shortCaption,
                lookup.metadata?.summary,
                lookup.metadata?.longCaption,
                lookup.metadata?.entitiesJSON,
                lookup.metadata?.sceneJSON,
                lookup.metadata?.styleJSON,
                lookup.metadata?.retrievalJSON
            ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

            samples.append(Sample(
                resolvedPath: aggregate.resolvedPath,
                projectRelativePath: aggregate.projectRelativePath ?? relativePath(aggregate.resolvedPath, projectRoot: projectRoot),
                role: role,
                rating: metadata.rating,
                isRejected: metadata.isRejected,
                isLiked: metadata.isLiked,
                notes: notes,
                updatedAt: metadata.updatedAt ?? Date.distantPast,
                analysisSummary: lookup.metadata?.summary,
                analysisText: analysisParts.joined(separator: "\n"),
                linkKinds: aggregate.linkKinds.map(\.rawValue).sorted()
            ))
        }
        return samples
    }

    private static func buildArtifact(samples: [Sample], embeddingsByPath: [String: [EmbeddingVector]]) -> ImagePreferenceProfileArtifact {
        let roleProfiles = ImageLibrarySemanticRole.allCases.compactMap { role -> ImagePreferenceRoleProfile? in
            let roleSamples = samples.filter { $0.role == role }
            guard !roleSamples.isEmpty else { return nil }
            let accepted = roleSamples.filter { isAccepted($0) }
            let rejected = roleSamples.filter { isRejectedOrLowRated($0) }
            let acceptedRatings = accepted.compactMap(\.rating)
            let vectorProfiles = buildVectorProfiles(samples: roleSamples, embeddingsByPath: embeddingsByPath)
            let promptMemory = buildPromptMemory(samples: roleSamples, role: role)
            return ImagePreferenceRoleProfile(
                role: role,
                reviewedCount: roleSamples.count,
                acceptedCount: accepted.count,
                rejectedCount: rejected.count,
                notedCount: roleSamples.filter { !$0.notes.isEmpty }.count,
                averageAcceptedRating: acceptedRatings.isEmpty ? nil : Double(acceptedRatings.reduce(0, +)) / Double(acceptedRatings.count),
                promptMemory: promptMemory,
                vectorProfiles: vectorProfiles,
                topAcceptedExamples: examples(from: accepted, accepted: true),
                topRejectedExamples: examples(from: rejected, accepted: false)
            )
        }
        return ImagePreferenceProfileArtifact(
            generatedAt: Date(),
            algorithm: .init(
                name: "Amira Image Preference Profile Builder",
                version: ImagePreferenceProfileArtifact.currentSchemaVersion,
                notes: [
                    "Manual review scope wins over source folder: canvas images tagged P become place samples; canvas images tagged C become character/costume samples.",
                    "Accepted visual centroids use non-rejected liked images plus non-rejected images rated 3★ or higher; rejected or 1–2★ images build the avoid centroid.",
                    "Rejected image pixels are never positive references, but their notes still become prompt-memory clauses.",
                    "Prompt builders should combine relevant promptMemory clauses with the vector preferenceDirection when ranking future references."
                ]
            ),
            sourceImageCount: samples.count,
            reviewedImageCount: samples.count,
            roleProfiles: roleProfiles
        )
    }

    private static func buildPromptMemory(samples: [Sample], role: ImageLibrarySemanticRole) -> [ImagePreferencePromptMemoryClause] {
        samples.compactMap { sample -> ImagePreferencePromptMemoryClause? in
            guard !sample.notes.isEmpty else { return nil }
            // Propagated auto-reject notes are valuable negative training examples for the
            // vector profile, but they are duplicated machine annotations. Keep them out
            // of prompt text so one user note does not get injected dozens of times or
            // carry UI wording such as "selected candidate" into future image prompts.
            guard !isPropagatedAutoRejectNote(sample.notes) else { return nil }
            let polarity: ImagePreferencePromptMemoryClause.Polarity
            if sample.isRejected || (sample.rating ?? 3) <= 2 {
                polarity = sample.notes.localizedCaseInsensitiveContains("i like") ? .mixed : .avoid
            } else if sample.isLiked || (sample.rating ?? 0) >= 4 {
                polarity = sample.notes.localizedCaseInsensitiveContains("but") ? .mixed : .prefer
            } else {
                polarity = .mixed
            }
            let ratingWeight = sample.isLiked ? 5.5 : Double(sample.rating ?? 3)
            let rejectionWeight = sample.isRejected ? 3.0 : 0.0
            let noteWeight = min(3.0, Double(sample.notes.count) / 180.0)
            guard let text = ContinuityPromptMemoryCompiler.visualInstruction(from: sample.notes, maxCharacters: 180) else {
                return nil
            }
            let tags = Array(terms(from: [sample.notes, sample.analysisText, sample.linkKinds.joined(separator: " ")].joined(separator: "\n")).prefix(24))
            return ImagePreferencePromptMemoryClause(
                id: stableID(sample.resolvedPath + "|" + role.rawValue + "|" + sample.notes),
                role: role,
                polarity: polarity,
                weight: ratingWeight + rejectionWeight + noteWeight,
                text: text,
                tags: tags,
                sourceImagePath: sample.projectRelativePath ?? sample.resolvedPath,
                rating: sample.rating,
                isRejected: sample.isRejected,
                updatedAt: sample.updatedAt
            )
        }
        .sorted { lhs, rhs in
            if lhs.weight != rhs.weight { return lhs.weight > rhs.weight }
            return lhs.updatedAt > rhs.updatedAt
        }
        .prefix(80)
        .map { $0 }
    }

    private static func isPropagatedAutoRejectNote(_ note: String) -> Bool {
        note.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .hasPrefix("auto-rejected by continuity builder:")
    }

    private static func buildVectorProfiles(samples: [Sample], embeddingsByPath: [String: [EmbeddingVector]]) -> [ImagePreferenceVectorProfile] {
        var accumulators: [String: VectorAccumulator] = [:]
        for sample in samples {
            var vectors = embeddingsByPath[sample.resolvedPath] ?? []
            let localText = [sample.notes, sample.analysisText, sample.linkKinds.joined(separator: " ")]
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !localText.isEmpty {
                let vector = ContinuityTextVectorizer.vector(for: localText).map(Float.init)
                vectors.append(.init(kind: "local_review_text", dimension: vector.count, vector: vector))
            }
            guard !vectors.isEmpty else { continue }
            for vector in vectors {
                var accumulator = accumulators[vector.kind] ?? VectorAccumulator(kind: vector.kind, dimension: vector.dimension)
                if isAccepted(sample) {
                    let weight = Double(max((sample.rating ?? 3) - 2, 1))
                    accumulator.addAccepted(vector.vector, weight: weight)
                }
                if isRejectedOrLowRated(sample) {
                    let weight = sample.isRejected ? 3.0 : Double(max(3 - (sample.rating ?? 3), 1))
                    accumulator.addRejected(vector.vector, weight: weight)
                }
                accumulators[vector.kind] = accumulator
            }
        }
        return accumulators.values
            .sorted { $0.kind < $1.kind }
            .compactMap { $0.profile() }
    }

    private struct VectorAccumulator {
        var kind: String
        var dimension: Int
        var acceptedCount = 0
        var rejectedCount = 0
        var acceptedWeight = 0.0
        var rejectedWeight = 0.0
        var accepted: [Double]
        var rejected: [Double]

        init(kind: String, dimension: Int) {
            self.kind = kind
            self.dimension = dimension
            self.accepted = Array(repeating: 0, count: dimension)
            self.rejected = Array(repeating: 0, count: dimension)
        }

        mutating func addAccepted(_ vector: [Float], weight: Double) {
            guard vector.count == dimension else { return }
            acceptedCount += 1
            acceptedWeight += weight
            for index in vector.indices { accepted[index] += Double(vector[index]) * weight }
        }

        mutating func addRejected(_ vector: [Float], weight: Double) {
            guard vector.count == dimension else { return }
            rejectedCount += 1
            rejectedWeight += weight
            for index in vector.indices { rejected[index] += Double(vector[index]) * weight }
        }

        func profile() -> ImagePreferenceVectorProfile? {
            guard acceptedCount > 0 || rejectedCount > 0 else { return nil }
            let acceptedCentroid = acceptedWeight > 0 ? accepted.map { $0 / acceptedWeight } : Array(repeating: 0, count: dimension)
            let rejectedCentroid = rejectedWeight > 0 ? rejected.map { $0 / rejectedWeight } : Array(repeating: 0, count: dimension)
            let direction = ImagePreferenceProfileService.normalized(zip(acceptedCentroid, rejectedCentroid).map { $0 - $1 })
            return ImagePreferenceVectorProfile(
                embeddingKind: kind,
                dimension: dimension,
                acceptedCount: acceptedCount,
                rejectedCount: rejectedCount,
                acceptedCentroid: ImagePreferenceProfileService.rounded(acceptedCentroid),
                rejectedCentroid: ImagePreferenceProfileService.rounded(rejectedCentroid),
                preferenceDirection: ImagePreferenceProfileService.rounded(direction)
            )
        }
    }

    private static func examples(from samples: [Sample], accepted: Bool) -> [ImagePreferenceExample] {
        samples.sorted { lhs, rhs in
            let lhsScore = accepted ? ((lhs.isLiked ? 10 : 0) + (lhs.rating ?? 0)) : ((lhs.isRejected ? 10 : 0) + (5 - (lhs.rating ?? 3)))
            let rhsScore = accepted ? ((rhs.isLiked ? 10 : 0) + (rhs.rating ?? 0)) : ((rhs.isRejected ? 10 : 0) + (5 - (rhs.rating ?? 3)))
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return lhs.updatedAt > rhs.updatedAt
        }
        .prefix(24)
        .map { sample in
            ImagePreferenceExample(
                imagePath: sample.projectRelativePath ?? sample.resolvedPath,
                projectRelativePath: sample.projectRelativePath,
                rating: sample.rating,
                isRejected: sample.isRejected,
                isLiked: sample.isLiked,
                notes: sample.notes,
                analysisSummary: sample.analysisSummary,
                linkKinds: sample.linkKinds
            )
        }
    }

    private static func loadEmbeddingVectors(projectRoot: URL, reviewedPaths: Set<String>) async -> [String: [EmbeddingVector]] {
        guard !reviewedPaths.isEmpty else { return [:] }
        let intelligenceStore = ImageIntelligenceStore(projectURL: projectRoot)
        do {
            try await intelligenceStore.open()
            defer { Task { await intelligenceStore.close() } }
            let rows = try await intelligenceStore.query("""
                SELECT a.resolved_path, e.embedding_kind, e.embedding_dimension, e.vector_blob
                FROM image_embeddings e
                JOIN image_assets a ON e.image_asset_id = a.id
                WHERE a.is_missing = 0
            """)
            var result: [String: [EmbeddingVector]] = [:]
            for row in rows {
                guard let rawPath = row["resolved_path"] as? String,
                      let kind = row["embedding_kind"] as? String,
                      let dimension = row["embedding_dimension"] as? Int,
                      let data = row["vector_blob"] as? Data else { continue }
                let canonicalPath = canonicalImagePath(rawPath, projectRoot: projectRoot)
                guard reviewedPaths.contains(canonicalPath) else { continue }
                let vector = data.withUnsafeBytes { buffer in
                    Array(buffer.bindMemory(to: Float.self))
                }
                guard vector.count == dimension else { continue }
                result[canonicalPath, default: []].append(.init(kind: kind, dimension: dimension, vector: vector))
            }
            return result
        } catch {
            return [:]
        }
    }

    private static func write(_ artifact: ImagePreferenceProfileArtifact, projectRoot: URL) throws {
        let dir = profileDirectory(projectRoot: projectRoot)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONCoders.makeEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(artifact)
        try data.write(to: dir.appendingPathComponent("latest.json"), options: .atomic)
        let stamp = AmiraDateFormatter.compact(artifact.generatedAt)
        try data.write(to: dir.appendingPathComponent("profile-\(stamp).json"), options: .atomic)
    }

    private static func profileDirectory(projectRoot: URL) -> URL {
        ProjectPaths(root: projectRoot).metadata
            .appendingPathComponent("automation", isDirectory: true)
            .appendingPathComponent("image-preference-profiles", isDirectory: true)
    }

    private static func semanticRole(for linkKind: ImageAssetLinkKind) -> ImageLibrarySemanticRole? {
        switch linkKind {
        case .placeGenerated, .placeReference, .placeLandmarkReference, .placeAngleImage, .placeMasterMap, .map3DCapture:
            return .place
        case .characterProfile, .characterInspiration, .characterReference, .characterAnimated,
             .characterMasterSource, .characterMasterSheetVariant, .characterHeadSheetVariant,
             .characterLookdevVariant, .characterHeadTurnVariant, .characterCostumeSheetVariant,
             .characterCostumeFullbodyVariant, .characterCostumeAccessoryVariant,
             .characterCostumeReference, .characterCostumeVariation, .characterShotReference:
            return .character
        case .storyboardFrame, .sceneShotImage, .canvasGeneration:
            return nil
        }
    }

    private static func isAccepted(_ sample: Sample) -> Bool {
        !sample.isRejected && (sample.isLiked || (sample.rating ?? 0) >= 3)
    }

    private static func isRejectedOrLowRated(_ sample: Sample) -> Bool {
        sample.isRejected || (sample.rating != nil && (sample.rating ?? 0) <= 2)
    }

    private static func normalized(_ vector: [Double]) -> [Double] {
        let norm = sqrt(vector.reduce(0.0) { $0 + ($1 * $1) })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    private static func rounded(_ vector: [Double]) -> [Double] {
        vector.map { value in
            (value * 1_000_000).rounded() / 1_000_000
        }
    }

    private static func terms(from text: String) -> [String] {
        let stopwords: Set<String> = [
            "this", "that", "with", "from", "there", "their", "image", "picture", "needs", "need", "should", "would", "could", "like", "looks", "look", "wrong", "right", "also", "very", "more", "less", "than", "then", "them", "they", "into", "onto", "have", "has", "but", "and", "the", "for", "not", "too"
        ]
        var seen = Set<String>()
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) }
            .filter { seen.insert($0).inserted }
    }

    private static func stableID(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func relativePath(_ path: String, projectRoot: URL) -> String? {
        let root = projectRoot.standardizedFileURL.path
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized.hasPrefix(root + "/") else { return nil }
        return String(standardized.dropFirst(root.count + 1))
    }

    private static func canonicalImagePath(_ rawPath: String, projectRoot: URL) -> String {
        let standardized = URL(fileURLWithPath: rawPath).standardizedFileURL.path
        let projectPath = projectRoot.standardizedFileURL.path
        if standardized == projectPath || standardized.hasPrefix(projectPath + "/") {
            return standardized
        }
        if let range = standardized.range(of: "/\(projectRoot.lastPathComponent)/") {
            return projectRoot.appendingPathComponent(String(standardized[range.upperBound...])).standardizedFileURL.path
        }
        if let animateRange = standardized.range(of: "/Animate/") {
            return projectRoot.appendingPathComponent("Animate").appendingPathComponent(String(standardized[animateRange.upperBound...])).standardizedFileURL.path
        }
        if let canvasRange = standardized.range(of: "/Canvas/") {
            return projectRoot.appendingPathComponent("Canvas").appendingPathComponent(String(standardized[canvasRange.upperBound...])).standardizedFileURL.path
        }
        if let charactersRange = standardized.range(of: "/Characters/") {
            return projectRoot.appendingPathComponent("Characters").appendingPathComponent(String(standardized[charactersRange.upperBound...])).standardizedFileURL.path
        }
        if let scenesRange = standardized.range(of: "/Scenes/") {
            return projectRoot.appendingPathComponent("Scenes").appendingPathComponent(String(standardized[scenesRange.upperBound...])).standardizedFileURL.path
        }
        return standardized
    }
}
