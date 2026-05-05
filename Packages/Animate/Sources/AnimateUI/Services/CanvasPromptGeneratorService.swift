import Foundation
import ProjectKit

@available(macOS 26.0, *)
struct CanvasPromptGeneratorResult: Sendable, Hashable {
    var prompt: String
    var referencePaths: [String]
    var referenceSummaries: [String]
    var usedProvider: String
    var warning: String?
}

@available(macOS 26.0, *)
struct CanvasPromptGeneratorService: Sendable {
    struct Request: Sendable {
        var userBrief: String
        var projectRoot: URL
        var worldContext: PlacesWorldContextBlocks
        var animatedLookPrompt: String
        var records: [ProjectImageRecord]
        var masterMapPath: String?
        var apiKey: String
        var provider: SupplementalLLMProvider = .deepSeek
        var model: String = SupplementalLLMProvider.deepSeek.defaultModel
        var maxReferences: Int = 8
    }

    private struct ReferenceCandidate: Sendable, Hashable, Identifiable {
        var id: String
        var path: String
        var role: ImageLibrarySemanticRole?
        var source: AllProjectImagesSource?
        var label: String
        var groupLabel: String
        var rating: Int?
        var isLiked: Bool
        var updatedAt: Date?
        var notes: String
        var searchText: String
        var isMasterMap: Bool = false
        var baseScore: Double
    }

    private struct PromptGeneratorResponse: Decodable {
        var prompt: String?
        var reference_ids: [String]?
        var referenceIDs: [String]?
        var notes: String?
    }

    func generate(_ request: Request) async throws -> CanvasPromptGeneratorResult {
        let brief = request.userBrief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !brief.isEmpty else { throw CanvasPromptGeneratorError.emptyBrief }
        guard !request.apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CanvasPromptGeneratorError.noAPIKey
        }

        let roles = Self.semanticRoles(for: brief, records: request.records)
        let deterministicCandidates = Self.referenceCandidates(
            for: brief,
            roles: roles,
            records: request.records,
            projectRoot: request.projectRoot,
            explicitMasterMapPath: request.masterMapPath,
            maxReferences: request.maxReferences
        )
        let candidateByID = Dictionary(uniqueKeysWithValues: deterministicCandidates.map { ($0.id, $0) })
        let memoryClauses = await Self.memoryClauses(
            for: brief,
            roles: roles,
            projectRoot: request.projectRoot
        )
        let raw = try await SupplementalLLMClient(
            configuration: SupplementalLLMConfiguration(
                provider: request.provider,
                apiKey: request.apiKey,
                model: request.model
            )
        ).complete(
            systemPrompt: Self.systemPrompt(),
            userPrompt: Self.userPrompt(
                brief: brief,
                worldContext: request.worldContext,
                animatedLookPrompt: request.animatedLookPrompt,
                candidates: deterministicCandidates,
                memoryClauses: memoryClauses
            )
        )
        let decoded = try Self.decodeResponse(raw)
        let prompt = Self.cleanPrompt(decoded.prompt ?? raw)
        guard !prompt.isEmpty else { throw CanvasPromptGeneratorError.invalidResponse }

        let requestedIDs = decoded.reference_ids ?? decoded.referenceIDs ?? []
        let selectedFromProvider = requestedIDs.compactMap { candidateByID[$0] }
        let selected = Self.finalReferenceSelection(
            selectedFromProvider: selectedFromProvider,
            deterministicCandidates: deterministicCandidates,
            maxReferences: request.maxReferences
        )
        return CanvasPromptGeneratorResult(
            prompt: prompt,
            referencePaths: selected.map(\.path),
            referenceSummaries: selected.map(Self.referenceSummary),
            usedProvider: request.provider.displayName,
            warning: selectedFromProvider.count < requestedIDs.count ? "Some \(request.provider.displayName) reference IDs were unavailable and were ignored." : nil
        )
    }

    private static func semanticRoles(for brief: String, records: [ProjectImageRecord]) -> [ImageLibrarySemanticRole] {
        let lower = brief.lowercased()
        var roles: [ImageLibrarySemanticRole] = []
        let characterNames = records
            .filter { $0.semanticRole == .character || $0.source == .characters || $0.source == .costumes }
            .map { $0.groupLabel.lowercased() }
            .filter { !$0.isEmpty }
        let briefTerms = Set(terms(from: lower))
        let mentionsCharacterName = characterNames.contains { name in
            let nameTerms = Set(terms(from: name))
            return !nameTerms.isEmpty && nameTerms.isSubset(of: briefTerms)
        }
        let characterTerms = [
            "character", "person", "people", "man", "woman", "boy", "girl", "soldier", "uniform", "costume", "face", "portrait", "body", "pose", "johnny", "mario", "rachel"
        ]
        let placeTerms = [
            "place", "town", "village", "city", "landscape", "terrain", "river", "bridge", "map", "valley", "ravine", "hill", "road", "street", "building", "architecture", "mountain", "background", "location", "sky", "exterior", "interior"
        ]
        if mentionsCharacterName || characterTerms.contains(where: { briefTerms.contains($0) }) {
            roles.append(.character)
        }
        if roles.isEmpty || placeTerms.contains(where: { briefTerms.contains($0) }) {
            roles.append(.place)
        }
        return roles
    }

    private static func referenceCandidates(
        for brief: String,
        roles: [ImageLibrarySemanticRole],
        records: [ProjectImageRecord],
        projectRoot: URL,
        explicitMasterMapPath: String?,
        maxReferences: Int
    ) -> [ReferenceCandidate] {
        let wantsPlace = roles.contains(.place)
        let wantsCharacter = roles.contains(.character)
        let queryTerms = Set(terms(from: brief))
        let lowerBrief = brief.lowercased()
        let needsMasterMap = wantsPlace && Self.needsMasterMap(lowerBrief)
        var candidates: [ReferenceCandidate] = []

        if needsMasterMap,
           let masterMap = resolvedMasterMapPath(projectRoot: projectRoot, explicitPath: explicitMasterMapPath),
           FileManager.default.fileExists(atPath: masterMap),
           !isRejectedImagePath(masterMap) {
            candidates.append(ReferenceCandidate(
                id: "master_map",
                path: masterMap,
                role: .place,
                source: nil,
                label: "Canonical master map",
                groupLabel: "Master map",
                rating: nil,
                isLiked: false,
                updatedAt: ImagePreferenceProfileService.referenceUpdatedAt(forImagePath: masterMap),
                notes: "Strict geography anchor for river direction, north-bank settlement, bridge/ravine placement, road relationships, and terrain.",
                searchText: "master map valley river bridge ravine town road terrain topography geography",
                isMasterMap: true,
                baseScore: 100
            ))
        }

        for record in records {
            let path = record.resolvedPath.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !path.isEmpty,
                  FileManager.default.fileExists(atPath: path),
                  !record.isRejected,
                  !isRejectedImagePath(path),
                  let preferenceScore = ImagePreferenceProfileService.referencePreferenceScore(forImagePath: path) ?? recordPreferenceScore(record) else {
                continue
            }
            let role = record.semanticRole ?? inferredRole(for: record.source)
            guard let role else { continue }
            guard (role == .place && wantsPlace) || (role == .character && wantsCharacter && !wantsPlace) else { continue }

            let haystack = [record.searchHaystack, record.originLabel, record.groupLabel, record.notes, record.source.displayName]
                .joined(separator: "\n")
                .lowercased()
            let matchScore = queryTerms.reduce(0.0) { partial, term in
                partial + (haystack.contains(term) ? 2.0 : 0.0)
            }
            let roleBoost = role == .character ? characterReferenceBoost(record: record, brief: lowerBrief) : placeReferenceBoost(record: record, brief: lowerBrief)
            let recencyBoost = recencyScore(record.createdAt ?? ImagePreferenceProfileService.referenceUpdatedAt(forImagePath: path))
            let notes = ContinuityPromptMemoryCompiler.visualInstruction(from: record.notes, maxCharacters: 140) ?? ""
            candidates.append(ReferenceCandidate(
                id: "ref_\(candidates.count + 1)",
                path: path,
                role: role,
                source: record.source,
                label: record.originLabel,
                groupLabel: record.groupLabel,
                rating: record.rating,
                isLiked: record.isLiked,
                updatedAt: record.createdAt ?? ImagePreferenceProfileService.referenceUpdatedAt(forImagePath: path),
                notes: notes,
                searchText: haystack,
                baseScore: preferenceScore + matchScore + roleBoost + recencyBoost
            ))
        }

        let masterMaps = candidates.filter(\.isMasterMap)
        let nonMaster = candidates.filter { !$0.isMasterMap }
        let rankedPlaces = nonMaster
            .filter { $0.role == .place }
            .sorted(by: rankCandidates)
            .prefix(wantsCharacter ? 3 : max(0, maxReferences - masterMaps.count))
        let rankedCharacters = nonMaster
            .filter { $0.role == .character }
            .sorted(by: rankCandidates)
            .prefix(wantsPlace ? 4 : maxReferences)

        var selected = Array(masterMaps) + Array(rankedPlaces) + Array(rankedCharacters)
        selected = dedupedByPath(selected)
        if selected.count > maxReferences {
            let pinned = selected.filter(\.isMasterMap)
            let rest = selected.filter { !$0.isMasterMap }.sorted(by: rankCandidates)
            selected = Array((pinned + rest).prefix(maxReferences))
        }
        return selected.enumerated().map { index, candidate in
            var mutable = candidate
            if !mutable.isMasterMap { mutable.id = "ref_\(index + 1)" }
            return mutable
        }
    }

    private static func recordPreferenceScore(_ record: ProjectImageRecord) -> Double? {
        guard !record.isRejected else { return nil }
        let rating = record.rating.map { Double(min(max($0, 1), 5)) }
        if record.isLiked { return max(5.5, (rating ?? 0) + 0.75) }
        return rating
    }

    private static func finalReferenceSelection(
        selectedFromProvider: [ReferenceCandidate],
        deterministicCandidates: [ReferenceCandidate],
        maxReferences: Int
    ) -> [ReferenceCandidate] {
        let mustKeep = deterministicCandidates.filter(\.isMasterMap)
        let providerSelected = dedupedByPath(selectedFromProvider)
        let fallback = deterministicCandidates.filter { candidate in
            !mustKeep.contains(where: { $0.path == candidate.path })
        }
        let selected = dedupedByPath(mustKeep + providerSelected + fallback)
        return Array(selected.prefix(maxReferences))
    }

    private static func rankCandidates(_ lhs: ReferenceCandidate, _ rhs: ReferenceCandidate) -> Bool {
        if lhs.baseScore != rhs.baseScore { return lhs.baseScore > rhs.baseScore }
        if lhs.rating != rhs.rating { return (lhs.rating ?? 0) > (rhs.rating ?? 0) }
        if lhs.updatedAt != rhs.updatedAt { return (lhs.updatedAt ?? .distantPast) > (rhs.updatedAt ?? .distantPast) }
        return lhs.label.localizedCaseInsensitiveCompare(rhs.label) == .orderedAscending
    }

    private static func dedupedByPath(_ candidates: [ReferenceCandidate]) -> [ReferenceCandidate] {
        var seen = Set<String>()
        var output: [ReferenceCandidate] = []
        for candidate in candidates {
            let key = URL(fileURLWithPath: candidate.path).standardizedFileURL.path
            guard seen.insert(key).inserted else { continue }
            output.append(candidate)
        }
        return output
    }

    private static func characterReferenceBoost(record: ProjectImageRecord, brief: String) -> Double {
        let text = [record.originLabel, record.groupLabel, record.searchHaystack].joined(separator: " ").lowercased()
        var score = 0.0
        if brief.contains(record.groupLabel.lowercased()), !record.groupLabel.isEmpty { score += 6 }
        if text.contains("costume") || text.contains("uniform") || text.contains("fullbody") || text.contains("full body") { score += 4 }
        if text.contains("animated") || text.contains("master sheet") || text.contains("reference") { score += 1.5 }
        if text.contains("head") || text.contains("profile") || text.contains("source") { score -= 2 }
        if brief.contains("portrait") || brief.contains("face") || brief.contains("close") {
            if text.contains("head") || text.contains("portrait") || text.contains("face") { score += 3 }
        }
        return score
    }

    private static func placeReferenceBoost(record: ProjectImageRecord, brief: String) -> Double {
        let text = [record.originLabel, record.groupLabel, record.searchHaystack].joined(separator: " ").lowercased()
        var score = 0.0
        if text.contains("map") { score += brief.contains("map") || brief.contains("terrain") ? 3 : 1 }
        if text.contains("bridge") { score += brief.contains("bridge") || brief.contains("ravine") ? 4 : 0 }
        if text.contains("animated") { score += 1 }
        if text.contains("3d") || text.contains("capture") { score += brief.contains("map") || brief.contains("terrain") ? 2 : -1 }
        return score
    }

    private static func needsMasterMap(_ lowerBrief: String) -> Bool {
        ["map", "town", "village", "river", "bridge", "ravine", "valley", "terrain", "topography", "hill", "road", "landscape", "exterior", "geography", "location"].contains { lowerBrief.contains($0) }
    }

    private static func inferredRole(for source: AllProjectImagesSource) -> ImageLibrarySemanticRole? {
        switch source {
        case .places, .landmarks, .map3dCaptures: return .place
        case .characters, .costumes: return .character
        case .props, .vehicles, .sceneShots, .canvas: return nil
        }
    }

    private static func memoryClauses(
        for brief: String,
        roles: [ImageLibrarySemanticRole],
        projectRoot: URL
    ) async -> [String] {
        let preference = ImagePreferenceProfileService.relevantPromptClauses(
            projectRoot: projectRoot,
            query: brief,
            semanticRoles: roles,
            limit: 8
        )
        let rules = await MainActor.run {
            ContinuityRuleExtractionService.relevantPromptClauses(
                projectRoot: projectRoot,
                query: brief,
                limit: 6
            )
        }
        return Array((preference + rules).prefix(12))
    }

    private static func systemPrompt() -> String {
        """
        You are a precise prompt generator for Amira Writer's Canvas.

        Output JSON only, with this schema:
        {"prompt":"final Gemini image prompt","reference_ids":["ref_1"]}

        Rules:
        - The prompt is for Gemini image generation; write clean visual instructions only.
        - Never include app/process words such as image review status, prompt seed, category, rating, rejected, liked, reference ID, metadata, vector, or training.
        - Never rely on the project title as visual shorthand.
        - Translate Gary's plain English into visible details: era, regional/world cues, architecture/materials, lighting, camera/framing, action, and visual tone.
        - Use early-2000s, Persian-Afghan highland valley continuity when relevant.
        - If this is a landscape/place/geography prompt, keep the town/rivers/bridges/geography consistent with attached references; preserve north-bank settlement logic and avoid invented extra bridges unless explicitly requested.
        - If this is a character prompt, keep the character clothed and in the correct costume/uniform. Never request nude/underclothed reference-pose character output unless Gary explicitly asks for anatomy-only reference work.
        - Reference images are selected separately by ID. Choose only IDs that help the prompt. If master_map is present for geography, include it.
        - You may say "use the attached reference images" or "use the attached master map" in the prompt, but never mention IDs or ratings.
        - Keep the final prompt compact: generally 120-260 words.
        """
    }

    private static func userPrompt(
        brief: String,
        worldContext: PlacesWorldContextBlocks,
        animatedLookPrompt: String,
        candidates: [ReferenceCandidate],
        memoryClauses: [String]
    ) -> String {
        let candidateText = candidates.isEmpty
            ? "No eligible rated/liked reference candidates were found."
            : candidates.map { candidate in
                let role = candidate.role?.rawValue ?? "support"
                let rating = candidate.rating.map { "\($0)★" } ?? (candidate.isMasterMap ? "canonical" : "liked")
                let notes = candidate.notes.isEmpty ? "" : "\n  visual notes: \(candidate.notes)"
                return "- \(candidate.id): role=\(role); label=\(candidate.label); group=\(candidate.groupLabel); score=\(rating); source=\(candidate.source?.rawValue ?? "canonical")\(notes)"
            }.joined(separator: "\n")
        let memoryText = memoryClauses.isEmpty
            ? "No compact preference memory matched this request."
            : memoryClauses.map { "- \($0)" }.joined(separator: "\n")
        let style = animatedLookPrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return """
        Gary's plain-English request:
        \(brief)

        Canonical world period:
        \(worldContext.timePeriod)

        Canonical environment/geography:
        \(worldContext.environmental)

        Canonical visual tone:
        \(worldContext.aesthetic)

        Master animated-look setting, used as hidden style context. Do not paste this wholesale into the output prompt; distill it into visual tone only if useful:
        \(style.isEmpty ? "Not configured." : style)

        Compact preference/continuity memory. Use this to make the prompt smarter, but do not quote process labels or review wording:
        \(memoryText)

        Eligible reference candidates. Only choose from these IDs:
        \(candidateText)

        Return JSON now.
        """
    }

    private static func decodeResponse(_ raw: String) throws -> PromptGeneratorResponse {
        let cleaned = raw
            .replacingOccurrences(of: "```json", with: "```")
            .replacingOccurrences(of: "```JSON", with: "```")
        if let first = cleaned.firstIndex(of: "{"), let last = cleaned.lastIndex(of: "}"), first <= last {
            let jsonText = String(cleaned[first...last])
            guard let data = jsonText.data(using: .utf8) else { throw CanvasPromptGeneratorError.invalidResponse }
            do {
                return try JSONDecoder().decode(PromptGeneratorResponse.self, from: data)
            } catch {
                return PromptGeneratorResponse(prompt: raw, reference_ids: nil, referenceIDs: nil, notes: nil)
            }
        }
        return PromptGeneratorResponse(prompt: raw, reference_ids: nil, referenceIDs: nil, notes: nil)
    }

    private static func cleanPrompt(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("```") {
            text = text.replacingOccurrences(of: "```json", with: "")
                .replacingOccurrences(of: "```JSON", with: "")
                .replacingOccurrences(of: "```", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        text = ContinuityPromptMemoryCompiler.cleaned(text)
        let bannedPatterns = [
            #"(?i)\bimage review status\b"#,
            #"(?i)\bcontinuity builder\b"#,
            #"(?i)\bprompt seed\b"#,
            #"(?i)\breference_ids?\b"#,
            #"(?i)\bref_\d+\b"#,
            #"(?i)\bmetadata\b"#,
            #"(?i)\btraining category\b"#,
            #"(?i)\brated\s*\d+\b"#,
            #"(?i)\brejected image feedback\b"#,
            #"(?i)\bliked image feedback\b"#
        ]
        for pattern in bannedPatterns {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+([,.!?;:])"#, with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text
    }

    private static func referenceSummary(_ candidate: ReferenceCandidate) -> String {
        let role = candidate.role?.displayName ?? "Reference"
        if candidate.isMasterMap { return "Master map" }
        let rating = candidate.rating.map { " · \($0)★" } ?? (candidate.isLiked ? " · liked" : "")
        return "\(role): \(candidate.label)\(rating)"
    }

    private static func terms(from text: String) -> [String] {
        let stopwords: Set<String> = [
            "this", "that", "with", "from", "there", "their", "image", "picture", "needs", "need", "should", "would", "could", "like", "looks", "look", "wrong", "right", "also", "very", "more", "less", "than", "then", "them", "they", "into", "onto", "have", "has", "but", "and", "the", "for", "not", "too", "make", "show", "want"
        ]
        var seen = Set<String>()
        return text.lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter { $0.count > 2 && !stopwords.contains($0) }
            .filter { seen.insert($0).inserted }
    }

    private static func recencyScore(_ date: Date?) -> Double {
        guard let date else { return 0 }
        let daysOld = max(0, -date.timeIntervalSinceNow / 86_400)
        return max(0, min(1.5, 1.5 - (daysOld / 120.0)))
    }


    private static func isRejectedImagePath(_ path: String) -> Bool {
        ImageLibraryMetadataSidecarService.load(forImagePath: path)?.isRejected == true
    }

    private static func runtimePath(_ rawPath: String?, projectRoot: URL) -> String? {
        guard let rawPath = rawPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawPath.isEmpty else {
            return nil
        }
        if !rawPath.hasPrefix("/") {
            return projectRoot.appendingPathComponent(rawPath).path
        }
        let projectPath = projectRoot.standardizedFileURL.path
        if rawPath == projectPath || rawPath.hasPrefix(projectPath + "/") {
            return rawPath
        }
        let projectFolderMarker = "/\(projectRoot.lastPathComponent)/"
        if let range = rawPath.range(of: projectFolderMarker) {
            return projectRoot.appendingPathComponent(String(rawPath[range.upperBound...])).path
        }
        if let range = rawPath.range(of: "/Animate/") {
            return ProjectPaths(root: projectRoot).animate.appendingPathComponent(String(rawPath[range.upperBound...])).path
        }
        return rawPath
    }

    private static func resolvedMasterMapPath(projectRoot: URL, explicitPath: String?) -> String? {
        if let explicit = runtimePath(explicitPath, projectRoot: projectRoot),
           FileManager.default.fileExists(atPath: explicit) {
            return explicit
        }

        let directCandidates = [
            "Animate/backgrounds/chosen-references/map/05-master_valley_topdown_map_2026-04-22.png",
            "Animate/backgrounds/chosen-references/map/01-master_valley_topdown_map_4k_v5.png"
        ]
            .map { projectRoot.appendingPathComponent($0).path }
        if let direct = directCandidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
            return direct
        }

        let registryURL = ProjectPaths(root: projectRoot).animate.appendingPathComponent("reference-registry.json")
        guard let data = try? Data(contentsOf: registryURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let backgrounds = object["backgrounds"] as? [[String: Any]] else { return nil }
        for entry in backgrounds {
            let name = (entry["name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard name == "map" || name.contains("master map") else { continue }
            let entryBase = (entry["absolute_path"] as? String).flatMap { runtimePath($0, projectRoot: projectRoot) }
            for file in (entry["files"] as? [[String: Any]] ?? []) {
                var candidates: [String] = []
                if let rawPath = file["absolute_path"] as? String ?? file["path"] as? String,
                   let resolved = runtimePath(rawPath, projectRoot: projectRoot) {
                    candidates.append(resolved)
                }
                if let relative = file["relative_to_root"] as? String {
                    if let entryBase { candidates.append(URL(fileURLWithPath: entryBase).appendingPathComponent(relative).path) }
                    candidates.append(ProjectPaths(root: projectRoot).animate.appendingPathComponent(relative).path)
                }
                if let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                    return found
                }
            }
        }
        return nil
    }
}

@available(macOS 26.0, *)
private struct CanvasMiniMaxTextClient: Sendable {
    let apiKey: String
    let model: String

    private struct Response: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message?
        }
        let choices: [Choice]?
    }

    func complete(systemPrompt: String, userPrompt: String) async throws -> String {
        let endpoints = [
            URL(string: "https://api.minimaxi.chat/v1/text/chatcompletion_v2")!,
            URL(string: "https://api.minimax.io/v1/chat/completions")!
        ]
        var lastError: Error?
        for endpoint in endpoints {
            do {
                return try await complete(endpoint: endpoint, systemPrompt: systemPrompt, userPrompt: userPrompt)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? CanvasPromptGeneratorError.invalidResponse
    }

    private func complete(endpoint: URL, systemPrompt: String, userPrompt: String) async throws -> String {
        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": systemPrompt],
                ["role": "user", "content": userPrompt]
            ],
            "temperature": 0.25,
            "max_tokens": 1400,
            "stream": false
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw CanvasPromptGeneratorError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw CanvasPromptGeneratorError.requestFailed(statusCode: http.statusCode, body: String(data: data, encoding: .utf8) ?? "")
        }
        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let content = decoded.choices?.first?.message?.content?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            throw CanvasPromptGeneratorError.invalidResponse
        }
        return content
    }
}

@available(macOS 26.0, *)
enum CanvasPromptGeneratorError: LocalizedError {
    case emptyBrief
    case noAPIKey
    case invalidResponse
    case requestFailed(statusCode: Int, body: String)

    var errorDescription: String? {
        switch self {
        case .emptyBrief:
            return "Enter a plain-English prompt generator request first."
        case .noAPIKey:
            return "Supplemental LLM API key is not configured. Add it in Settings before using Prompt Generator."
        case .invalidResponse:
            return "Supplemental LLM returned an invalid prompt-generator response."
        case .requestFailed(let statusCode, let body):
            return "Supplemental LLM request failed (HTTP \(statusCode)): \(body.prefix(300))"
        }
    }
}
