import CryptoKit
import Foundation
import ProjectKit

@available(macOS 26.0, *)
struct ContinuityFeedbackSource: Identifiable, Codable, Sendable, Hashable {
    var id: String
    var sourceKind: String
    var category: String?
    var imagePath: String?
    var label: String
    var notes: String
    var reviewStatus: String? = nil
    var rating: Int? = nil
    var isRejected: Bool? = nil
    var reviewScope: String? = nil
    var analysisSummary: String?
    var tags: [String]
    var vector: [Double]
    var updatedAt: Date
}

@available(macOS 26.0, *)
struct ContinuityRuleFingerprint: Identifiable, Codable, Sendable, Hashable {
    var id: UUID
    var category: String
    var title: String
    var canonicalRule: String
    var promptClause: String
    var positiveSignals: [String]
    var negativeSignals: [String]
    var requiredTags: [String]
    var sourceFeedbackIDs: [String]
    var supportCount: Int
    var confidence: Double
    var vector: [Double]

    init(
        id: UUID = UUID(),
        category: String,
        title: String,
        canonicalRule: String,
        promptClause: String,
        positiveSignals: [String] = [],
        negativeSignals: [String] = [],
        requiredTags: [String] = [],
        sourceFeedbackIDs: [String] = [],
        supportCount: Int,
        confidence: Double,
        vector: [Double]
    ) {
        self.id = id
        self.category = category
        self.title = title
        self.canonicalRule = canonicalRule
        self.promptClause = promptClause
        self.positiveSignals = positiveSignals
        self.negativeSignals = negativeSignals
        self.requiredTags = requiredTags
        self.sourceFeedbackIDs = sourceFeedbackIDs
        self.supportCount = supportCount
        self.confidence = confidence
        self.vector = vector
    }
}

@available(macOS 26.0, *)
struct ContinuityRuleExtractionArtifact: Identifiable, Codable, Sendable, Hashable {
    static let currentSchemaVersion = 1
    var schemaVersion: Int = Self.currentSchemaVersion
    var id: UUID
    var createdAt: Date
    var provider: String
    var model: String
    var mode: String
    var isDryRun: Bool
    var sourceFeedbackCount: Int
    var sources: [ContinuityFeedbackSource]
    var fingerprints: [ContinuityRuleFingerprint]
    var promptPath: String?
    var responsePath: String?
    var artifactPath: String?
    var rawModelResponse: String?
    var errorMessage: String?
    var blockers: [AutomationBlocker]
}

@available(macOS 26.0, *)
@MainActor
struct ContinuityRuleExtractionService {
    var store: AnimateStore

    struct Request: Sendable {
        var projectRoot: URL
        var mode: String
        var provider: SupplementalLLMProvider
        var model: String
        var writeSidecars: Bool
        var apiKey: String
        var maxSources: Int
    }

    func build(_ request: Request) async throws -> ContinuityRuleExtractionArtifact {
        let normalizedMode = request.mode.lowercased() == "execute" ? "execute" : "dry_run"
        let sources = await collectSources(projectRoot: request.projectRoot, limit: max(1, request.maxSources))
        let heuristicRules = Self.heuristicFingerprints(from: sources)
        let prompts = Self.prompts(sources: sources, heuristicRules: heuristicRules)
        var artifact = ContinuityRuleExtractionArtifact(
            id: UUID(),
            createdAt: Date(),
            provider: normalizedMode == "execute" ? request.provider.rawValue : "local_heuristic",
            model: request.model,
            mode: normalizedMode,
            isDryRun: normalizedMode != "execute",
            sourceFeedbackCount: sources.count,
            sources: sources,
            fingerprints: heuristicRules,
            promptPath: nil,
            responsePath: nil,
            artifactPath: nil,
            rawModelResponse: nil,
            errorMessage: nil,
            blockers: sources.isEmpty ? [.init(code: .needsManualReview, message: "No image/continuity feedback has been recorded yet.", field: "feedback", severity: "warning")] : []
        )

        if request.writeSidecars {
            artifact.promptPath = try writePromptSidecar(prompts, artifactID: artifact.id, projectRoot: request.projectRoot).path
        }

        if normalizedMode == "execute" {
            guard !request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                artifact.errorMessage = "\(request.provider.displayName) API key is not configured."
                artifact.blockers.append(.init(code: .failedProviderError, message: "\(request.provider.displayName) API key is not configured.", field: request.provider.apiKeyFieldName))
                if request.writeSidecars { artifact.artifactPath = try writeArtifact(artifact, projectRoot: request.projectRoot).path }
                return artifact
            }
            do {
                let raw = try await SupplementalLLMClient(
                    configuration: .init(provider: request.provider, apiKey: request.apiKey, model: request.model)
                )
                .complete(systemPrompt: prompts.system, userPrompt: prompts.user)
                artifact.rawModelResponse = raw
                artifact.fingerprints = try Self.decodeFingerprints(raw, fallbackSources: sources)
                if request.writeSidecars {
                    artifact.responsePath = try writeResponseSidecar(raw, artifactID: artifact.id, projectRoot: request.projectRoot).path
                }
            } catch {
                artifact.errorMessage = error.localizedDescription
                artifact.blockers.append(.init(code: .failedProviderError, message: "\(request.provider.displayName) rule extraction failed: \(error.localizedDescription)", field: request.provider.rawValue))
            }
        }

        if request.writeSidecars {
            artifact.artifactPath = try writeArtifact(artifact, projectRoot: request.projectRoot).path
            if !artifact.fingerprints.isEmpty {
                try writeLatest(artifact, projectRoot: request.projectRoot)
            }
        }
        return artifact
    }

    static func latest(projectRoot: URL) -> ContinuityRuleExtractionArtifact? {
        let url = rulesDirectory(projectRoot: projectRoot).appendingPathComponent("latest-rules.json")
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ContinuityRuleExtractionArtifact.self, from: data)
    }

    static func relevantPromptClauses(
        projectRoot: URL,
        query: String,
        categories: Set<String>? = nil,
        limit: Int = 8
    ) -> [String] {
        guard let artifact = latest(projectRoot: projectRoot) else { return [] }
        let queryVector = ContinuityTextVectorizer.vector(for: query)
        let scored = artifact.fingerprints
            .filter { rule in
                guard let categories else { return true }
                return categories.contains(rule.category.lowercased())
            }
            .map { rule -> (ContinuityRuleFingerprint, Double) in
                let tagScore = rule.requiredTags.reduce(0.0) { partial, tag in
                    partial + (query.localizedCaseInsensitiveContains(tag) ? 0.15 : 0)
                }
                return (rule, ContinuityTextVectorizer.cosine(queryVector, rule.vector) + tagScore)
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
                return lhs.0.confidence > rhs.0.confidence
            }
        let relevant = scored.filter { $0.1 > 0.04 }
        return (relevant.isEmpty ? scored : relevant)
            .prefix(max(1, limit))
            .compactMap { ContinuityPromptMemoryCompiler.sanitizedPromptClause($0.0.promptClause) }
    }

    private func collectSources(projectRoot: URL, limit: Int) async -> [ContinuityFeedbackSource] {
        var sources: [ContinuityFeedbackSource] = []
        for artifact in ImageReviewFeedbackService.loadAllFeedback(projectRoot: projectRoot) {
            let reviewStatus = artifact.isRejected ? "rejected" : artifact.rating.map { "rated_\($0)" } ?? "unrated"
            let reviewScope = artifact.semanticRole?.rawValue
            let notes = ContinuityPromptMemoryCompiler.cleaned(artifact.notes)
            let text = [artifact.notes, artifact.originLabel, artifact.groupLabel, artifact.semanticRole?.rawValue, artifact.analysis?.summary, artifact.analysis?.retrievalJSON]
                .compactMap { $0 }
                .joined(separator: "\n")
            let tags = Array(Set(Self.tags(from: text) + [reviewStatus, reviewScope].compactMap { $0 })).sorted()
            sources.append(.init(
                id: "image-feedback:\(artifact.id.uuidString)",
                sourceKind: "image_feedback",
                category: artifact.semanticRole?.rawValue ?? artifact.source,
                imagePath: artifact.imagePath,
                label: artifact.originLabel,
                notes: notes,
                reviewStatus: reviewStatus,
                rating: artifact.rating,
                isRejected: artifact.isRejected,
                reviewScope: reviewScope,
                analysisSummary: artifact.analysis?.summary ?? artifact.analysis?.shortCaption,
                tags: tags,
                vector: ContinuityTextVectorizer.vector(for: text),
                updatedAt: artifact.updatedAt
            ))
        }
        return Array(sources.sorted { $0.updatedAt > $1.updatedAt }.prefix(limit))
    }

    private static func heuristicFingerprints(from sources: [ContinuityFeedbackSource]) -> [ContinuityRuleFingerprint] {
        let buckets = Dictionary(grouping: sources) { source in category(for: source.notes + " " + source.tags.joined(separator: " ")) }
        return buckets.compactMap { category, grouped in
            let notes = grouped
                .map(\.notes)
                .compactMap { ContinuityPromptMemoryCompiler.visualInstruction(from: $0, maxCharacters: 180) }
            guard !notes.isEmpty else { return nil }
            let tags = Array(Set(grouped.flatMap(\.tags))).sorted()
            guard let ruleText = heuristicRuleText(category: category, notes: Array(notes.prefix(6)), tags: tags) else { return nil }
            return ContinuityRuleFingerprint(
                category: category,
                title: title(for: category, tags: tags),
                canonicalRule: ruleText,
                promptClause: ruleText,
                positiveSignals: [],
                negativeSignals: notes,
                requiredTags: tags,
                sourceFeedbackIDs: grouped.map(\.id),
                supportCount: grouped.count,
                confidence: min(0.95, 0.45 + Double(grouped.count) * 0.12),
                vector: ContinuityTextVectorizer.average(grouped.map(\.vector))
            )
        }
        .sorted { $0.supportCount > $1.supportCount }
    }

    private static func prompts(sources: [ContinuityFeedbackSource], heuristicRules: [ContinuityRuleFingerprint]) -> (system: String, user: String) {
        let system = """
        You are a script-supervisor continuity compiler for Amira Writer.
        Convert noisy user feedback and image-analysis snippets into durable canonical visual rules.
        Output JSON only. Do not include markdown. Be conservative: rules must trace to source feedback.
        Prefer concrete geography/costume/prop/style constraints over generic advice.
        """
        let sourcePayloadItems: [String] = sources.prefix(80).map { source in
            let rows: [String] = [
                "id: \(source.id)",
                "kind: \(source.sourceKind)",
                "label: \(source.label)",
                "reviewStatus: \(source.reviewStatus ?? "")",
                "reviewScope: \(source.reviewScope ?? "")",
                "rating: \(source.rating.map(String.init) ?? "")",
                "notes: \(source.notes)",
                "analysis: \(source.analysisSummary ?? "")",
                "tags: \(source.tags.joined(separator: ", "))"
            ]
            return rows.joined(separator: "\n")
        }
        let sourcePayload = sourcePayloadItems.joined(separator: "\n---\n")
        let user = """
        Produce this exact JSON shape:
        {
          "fingerprints": [
            {
              "category": "geography|costume|character_identity|vehicle_prop|style|scene_continuity|other",
              "title": "short title",
              "canonicalRule": "one durable rule",
              "promptClause": "prompt-ready instruction",
              "positiveSignals": ["what good images should show"],
              "negativeSignals": ["what wrong images showed"],
              "requiredTags": ["lowercase tags"],
              "sourceFeedbackIDs": ["ids from input"],
              "confidence": 0.0
            }
          ]
        }

        Seed heuristic rules to improve, merge, or replace:
        \(heuristicRules.map { "- [\($0.category)] \($0.canonicalRule)" }.joined(separator: "\n"))

        Feedback sources:
        \(sourcePayload)
        """
        return (system, user)
    }

    private static func decodeFingerprints(_ raw: String, fallbackSources: [ContinuityFeedbackSource]) throws -> [ContinuityRuleFingerprint] {
        struct Output: Decodable { var fingerprints: [Item] }
        struct Item: Decodable {
            var category: String
            var title: String
            var canonicalRule: String
            var promptClause: String
            var positiveSignals: [String]?
            var negativeSignals: [String]?
            var requiredTags: [String]?
            var sourceFeedbackIDs: [String]?
            var confidence: Double?
        }
        let json = extractJSONObject(from: raw) ?? raw
        let data = Data(json.utf8)
        let output = try JSONDecoder().decode(Output.self, from: data)
        let vectorsByID = Dictionary(uniqueKeysWithValues: fallbackSources.map { ($0.id, $0.vector) })
        return output.fingerprints.map { item in
            let sourceIDs = item.sourceFeedbackIDs ?? []
            let vectors = sourceIDs.compactMap { vectorsByID[$0] }
            let vector = vectors.isEmpty ? ContinuityTextVectorizer.vector(for: item.canonicalRule + " " + item.promptClause) : ContinuityTextVectorizer.average(vectors)
            return ContinuityRuleFingerprint(
                category: item.category,
                title: item.title,
                canonicalRule: item.canonicalRule,
                promptClause: item.promptClause,
                positiveSignals: item.positiveSignals ?? [],
                negativeSignals: item.negativeSignals ?? [],
                requiredTags: item.requiredTags ?? [],
                sourceFeedbackIDs: sourceIDs,
                supportCount: max(1, sourceIDs.count),
                confidence: min(max(item.confidence ?? 0.7, 0), 1),
                vector: vector
            )
        }
    }

    private static func extractJSONObject(from raw: String) -> String? {
        if let fenceStart = raw.range(of: "```") {
            let afterFence = raw[fenceStart.upperBound...]
            let contentStart = afterFence.range(of: "\n")?.upperBound ?? afterFence.startIndex
            if let fenceEnd = afterFence[contentStart...].range(of: "```") {
                return String(afterFence[contentStart..<fenceEnd.lowerBound])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        guard let start = raw.firstIndex(of: "{"),
              let end = raw.lastIndex(of: "}"),
              start <= end else { return nil }
        return String(raw[start...end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func writePromptSidecar(_ prompts: (system: String, user: String), artifactID: UUID, projectRoot: URL) throws -> URL {
        let dir = Self.artifactDirectory(projectRoot: projectRoot, artifactID: artifactID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("prompt.txt")
        try ["SYSTEM:\n\(prompts.system)", "USER:\n\(prompts.user)"].joined(separator: "\n\n---\n\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeResponseSidecar(_ raw: String, artifactID: UUID, projectRoot: URL) throws -> URL {
        let dir = Self.artifactDirectory(projectRoot: projectRoot, artifactID: artifactID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("response.txt")
        try raw.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func writeArtifact(_ artifact: ContinuityRuleExtractionArtifact, projectRoot: URL) throws -> URL {
        let dir = Self.artifactDirectory(projectRoot: projectRoot, artifactID: artifact.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("rules.json")
        var copy = artifact; copy.artifactPath = url.path
        try writeCodable(copy, to: url)
        return url
    }

    private func writeLatest(_ artifact: ContinuityRuleExtractionArtifact, projectRoot: URL) throws {
        var copy = artifact
        copy.artifactPath = artifact.artifactPath
        try FileManager.default.createDirectory(at: Self.rulesDirectory(projectRoot: projectRoot), withIntermediateDirectories: true)
        try writeCodable(copy, to: Self.rulesDirectory(projectRoot: projectRoot).appendingPathComponent("latest-rules.json"))
    }

    private static func rulesDirectory(projectRoot: URL) -> URL {
        ProjectPaths(root: projectRoot).metadata.appendingPathComponent("automation", isDirectory: true).appendingPathComponent("continuity-rules", isDirectory: true)
    }

    private static func artifactDirectory(projectRoot: URL, artifactID: UUID) -> URL {
        rulesDirectory(projectRoot: projectRoot).appendingPathComponent(artifactID.uuidString, isDirectory: true)
    }

    private static func tags(from text: String) -> [String] {
        let lower = text.lowercased()
        let known = ["river", "bridge", "ravine", "town", "hill", "sun", "lighting", "vehicle", "humvee", "soldier", "camouflage", "satchel", "polaroid", "camera", "costume", "face", "head", "map", "style", "grain", "palette", "crop", "4:3", "building", "north", "south"]
        return known.filter { lower.contains($0) }
    }

    private static func category(for text: String) -> String {
        let lower = text.lowercased()
        if ["bridge", "river", "ravine", "town", "hill", "map", "north", "south"].contains(where: lower.contains) { return "geography" }
        if ["costume", "camouflage", "satchel", "belt", "polaroid", "wardrobe"].contains(where: lower.contains) { return "costume" }
        if ["face", "head", "character", "johnny", "identity"].contains(where: lower.contains) { return "character_identity" }
        if ["vehicle", "humvee", "truck", "prop"].contains(where: lower.contains) { return "vehicle_prop" }
        if ["style", "grain", "palette", "cgi", "hdr", "lens"].contains(where: lower.contains) { return "style" }
        return "scene_continuity"
    }

    private static func title(for category: String, tags: [String]) -> String {
        let suffix = tags.prefix(3).joined(separator: ", ")
        return suffix.isEmpty ? category.replacingOccurrences(of: "_", with: " ").capitalized : "\(category.replacingOccurrences(of: "_", with: " ").capitalized): \(suffix)"
    }

    private static func heuristicRuleText(category: String, notes: [String], tags: [String]) -> String? {
        ContinuityPromptMemoryCompiler.visualRule(category: category, notes: notes, tags: tags)
    }
}

@available(macOS 26.0, *)
enum ContinuityTextVectorizer {
    static let dimension = 96

    static func vector(for text: String) -> [Double] {
        var vector = Array(repeating: 0.0, count: dimension)
        for token in tokens(text) {
            let idx = Int(stableHash(token) % UInt64(dimension))
            vector[idx] += 1.0
        }
        let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return vector }
        return vector.map { $0 / norm }
    }

    static func average(_ vectors: [[Double]]) -> [Double] {
        guard let first = vectors.first else { return Array(repeating: 0, count: dimension) }
        var result = Array(repeating: 0.0, count: first.count)
        for vector in vectors {
            for index in result.indices where vector.indices.contains(index) { result[index] += vector[index] }
        }
        let scale = Double(max(1, vectors.count))
        result = result.map { $0 / scale }
        let norm = sqrt(result.reduce(0) { $0 + $1 * $1 })
        return norm > 0 ? result.map { $0 / norm } : result
    }

    static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        let count = min(lhs.count, rhs.count)
        return (0..<count).reduce(0.0) { $0 + lhs[$1] * rhs[$1] }
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 }
    }

    private static func stableHash(_ value: String) -> UInt64 {
        SHA256.hash(data: Data(value.utf8)).prefix(8).reduce(UInt64(0)) { ($0 << 8) ^ UInt64($1) }
    }
}

@available(macOS 26.0, *)
struct MiniMaxJSONClient {
    let apiKey: String
    let model: String
    var endpoint: URL = URL(string: "https://api.minimax.io/v1/chat/completions")!

    func completeJSON(systemPrompt: String, userPrompt: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.1,
            "max_tokens": 12000,
            "stream": false
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ContinuityMiniMaxError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw ContinuityMiniMaxError.requestFailed(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(ContinuityMiniMaxChatCompletionResponse.self, from: data)
        guard let content = decoded.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw ContinuityMiniMaxError.invalidResponse
        }
        return content
    }
}


@available(macOS 26.0, *)
private struct ContinuityMiniMaxChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable { let content: String? }
        let message: Message?
    }
    let choices: [Choice]?
}

@available(macOS 26.0, *)
private enum ContinuityMiniMaxError: LocalizedError {
    case invalidResponse
    case requestFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "Invalid response from supplemental LLM."
        case .requestFailed(let statusCode, let body):
            return "Supplemental LLM request failed (HTTP \(statusCode)): \(body.prefix(500))"
        }
    }
}
