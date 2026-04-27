import Foundation

/// Search and retrieval service for image intelligence data.
@available(macOS 26.0, *)
public actor ImageSearchService {

    public struct SearchResult: Sendable {
        public let assetID: String
        public let resolvedPath: String
        public let score: Double
        public let matchType: MatchType
        public let metadata: ImageAssetRecord?

        public enum MatchType: String, Sendable {
            case tag
            case text
            case visual
            case semantic
        }
    }

    public struct SelectorInput: Sendable {
        public let sceneID: String?
        public let shotID: String?
        public let moment: String?
        public let characterIDs: [String]
        public let placeID: String?
        public let queryText: String?

        public init(
            sceneID: String? = nil,
            shotID: String? = nil,
            moment: String? = nil,
            characterIDs: [String] = [],
            placeID: String? = nil,
            queryText: String? = nil
        ) {
            self.sceneID = sceneID
            self.shotID = shotID
            self.moment = moment
            self.characterIDs = characterIDs
            self.placeID = placeID
            self.queryText = queryText
        }
    }

    public struct ReferenceSelection: Sendable {
        public let assetID: String
        public let resolvedPath: String
        public let role: String
        public let score: Double
        public let reason: String
    }

    private let store: ImageIntelligenceStore

    public init(store: ImageIntelligenceStore) {
        self.store = store
    }

    // MARK: - Tag Search

    public func searchByTags(
        tags: [String],
        excludeRejected: Bool = true,
        limit: Int = 50
    ) async throws -> [SearchResult] {
        let placeholders = tags.map { _ in "?" }.joined(separator: ",")
        let sql = """
            SELECT a.id, a.resolved_path, COUNT(ta.tag_id) as tag_count
            FROM image_assets a
            JOIN image_tag_assignments ta ON a.id = ta.image_asset_id
            JOIN image_tags t ON ta.tag_id = t.id
            WHERE t.slug IN (\(placeholders))
            \(excludeRejected ? "AND a.is_missing = 0" : "")
            GROUP BY a.id
            ORDER BY tag_count DESC
            LIMIT ?
        """

        let params: [Any] = tags + [limit]
        let rows = try await store.query(sql, params)

        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let path = row["resolved_path"] as? String else { return nil }
            return SearchResult(
                assetID: id,
                resolvedPath: path,
                score: Double(row["tag_count"] as? Int ?? 0),
                matchType: .tag,
                metadata: nil
            )
        }
    }

    // MARK: - Text Search (Basic)

    public func searchByText(
        _ text: String,
        excludeRejected: Bool = true,
        limit: Int = 50
    ) async throws -> [SearchResult] {
        let pattern = "%\(text.lowercased())%"
        let sql = """
            SELECT DISTINCT a.id, a.resolved_path
            FROM image_assets a
            LEFT JOIN image_visual_metadata vm ON a.id = vm.image_asset_id
            WHERE (
                LOWER(vm.summary) LIKE ? OR
                LOWER(vm.short_caption) LIKE ? OR
                LOWER(vm.long_caption) LIKE ? OR
                LOWER(vm.retrieval_json) LIKE ?
            )
            \(excludeRejected ? "AND a.is_missing = 0" : "")
            LIMIT ?
        """

        let params: [Any] = [pattern, pattern, pattern, pattern, limit]
        let rows = try await store.query(sql, params)

        return rows.compactMap { row in
            guard let id = row["id"] as? String,
                  let path = row["resolved_path"] as? String else { return nil }
            return SearchResult(
                assetID: id,
                resolvedPath: path,
                score: 1.0,
                matchType: .text,
                metadata: nil
            )
        }
    }

    // MARK: - Similarity Search (Vector)

    public func findSimilarImages(
        toAssetID: String,
        embeddingKind: String = "image_visual",
        limit: Int = 10
    ) async throws -> [SearchResult] {
        // Get the query vector
        guard let queryVector = try await getEmbeddingVector(assetID: toAssetID, kind: embeddingKind) else {
            return []
        }

        // Get all vectors of the same kind
        let sql = """
            SELECT e.image_asset_id, a.resolved_path, e.vector_blob, e.vector_norm
            FROM image_embeddings e
            JOIN image_assets a ON e.image_asset_id = a.id
            WHERE e.embedding_kind = ? AND e.image_asset_id != ? AND a.is_missing = 0
        """

        let rows = try await store.query(sql, [embeddingKind, toAssetID])

        var results: [SearchResult] = []
        for row in rows {
            guard let assetID = row["image_asset_id"] as? String,
                  let path = row["resolved_path"] as? String,
                  let vectorData = row["vector_blob"] as? Data,
                  let norm = row["vector_norm"] as? Double else { continue }

            let vector = vectorData.withUnsafeBytes { buffer in
                Array(buffer.bindMemory(to: Float.self))
            }

            let similarity = cosineSimilarity(queryVector.vector, vector, queryVector.norm, Float(norm))

            results.append(SearchResult(
                assetID: assetID,
                resolvedPath: path,
                score: Double(similarity),
                matchType: .visual,
                metadata: nil
            ))
        }

        return results.sorted { $0.score > $1.score }.prefix(limit).map { $0 }
    }

    // MARK: - Reference Image Selector

    public func selectForShot(
        input: SelectorInput,
        maxImages: Int = 5
    ) async throws -> [ReferenceSelection] {
        var candidatesByAssetID: [String: ShotReferenceCandidate] = [:]
        let queryTokens = Self.referenceQueryTokens(from: input.queryText)

        // Build query based on the script/storyboard reference contract.
        // This is intentionally link-driven first: exact owner links are cheap,
        // deterministic, and prevent the selector from inventing references when
        // the project already knows the shot/character/place attachment.
        var conditions: [String] = []
        var params: [Any] = []

        // Filter by place
        if let placeID = input.placeID {
            conditions.append("""
                (l.owner_id = ? AND l.link_kind IN (
                    'place_generated',
                    'place_reference',
                    'place_landmark_reference',
                    'place_angle_image',
                    'place_master_map',
                    'map3d_capture'
                ))
                """)
            params.append(placeID)
        }

        // Filter by character
        for charID in input.characterIDs {
            conditions.append("""
                (
                    (l.owner_id = ? AND l.link_kind LIKE 'character_%')
                    OR EXISTS (
                        SELECT 1
                        FROM image_character_regions cr
                        WHERE cr.image_asset_id = a.id
                          AND cr.character_id = ?
                    )
                )
                """)
            params.append(contentsOf: [charID, charID])
        }

        // Filter by scene shot
        if let shotID = input.shotID {
            conditions.append("(l.owner_id = ? AND l.link_kind IN ('scene_shot_image', 'storyboard_frame'))")
            params.append(shotID)
        }

        if let sceneID = input.sceneID {
            conditions.append("(l.owner_parent_id = ? AND l.link_kind IN ('scene_shot_image', 'storyboard_frame'))")
            params.append(sceneID)
        }

        let queryFilterTokens = Self.referenceQueryFilterTokens(from: queryTokens, limit: 10)
        if !queryFilterTokens.isEmpty {
            conditions.append(Self.queryFilterSQL(tokenCount: queryFilterTokens.count))
            for token in queryFilterTokens {
                let pattern = "%\(token)%"
                params.append(contentsOf: Array(repeating: pattern, count: 8))
            }
        }

        guard !conditions.isEmpty else { return [] }

        let whereClause = conditions.isEmpty ? "" : "AND (" + conditions.joined(separator: " OR ") + ")"

        let sql = """
            SELECT
                a.id,
                a.resolved_path,
                a.content_hash_sha256,
                l.link_kind,
                l.owner_id,
                l.owner_parent_id,
                l.moment,
                l.workflow,
                (
                    SELECT vm.summary
                    FROM image_visual_metadata vm
                    WHERE vm.image_asset_id = a.id
                    ORDER BY vm.created_at DESC
                    LIMIT 1
                ) AS visual_summary,
                (
                    SELECT vm.short_caption
                    FROM image_visual_metadata vm
                    WHERE vm.image_asset_id = a.id
                    ORDER BY vm.created_at DESC
                    LIMIT 1
                ) AS visual_short_caption,
                (
                    SELECT vm.long_caption
                    FROM image_visual_metadata vm
                    WHERE vm.image_asset_id = a.id
                    ORDER BY vm.created_at DESC
                    LIMIT 1
                ) AS visual_long_caption,
                (
                    SELECT vm.retrieval_json
                    FROM image_visual_metadata vm
                    WHERE vm.image_asset_id = a.id
                    ORDER BY vm.created_at DESC
                    LIMIT 1
                ) AS visual_retrieval_json,
                (
                    SELECT GROUP_CONCAT(t.slug || ' ' || COALESCE(t.display_name, ''), ' ')
                    FROM image_tag_assignments ta
                    JOIN image_tags t ON ta.tag_id = t.id
                    WHERE ta.image_asset_id = a.id
                      AND ta.is_negative = 0
                ) AS tag_text,
                (
                    SELECT GROUP_CONCAT(cr.character_id || ' ' || COALESCE(cr.character_name, ''), ' ')
                    FROM image_character_regions cr
                    WHERE cr.image_asset_id = a.id
                ) AS character_region_text,
                EXISTS(
                    SELECT 1
                    FROM image_visual_metadata vm
                    WHERE vm.image_asset_id = a.id
                    LIMIT 1
                ) AS has_visual_metadata
            FROM image_assets a
            LEFT JOIN image_asset_links l ON a.id = l.image_asset_id
            WHERE a.is_missing = 0
            \(whereClause)
            ORDER BY has_visual_metadata DESC, a.updated_at DESC, a.resolved_path ASC
            LIMIT ?
        """

        params.append(max(50, maxImages * 12)) // Get more candidates for scoring

        let rows = try await store.query(sql, params)

        for row in rows {
            guard let id = row["id"] as? String,
                  let path = row["resolved_path"] as? String else { continue }
            guard ImagePreferenceProfileService.isPositiveReferenceEligible(path) else { continue }
            let linkKind = row["link_kind"] as? String

            var candidate = candidatesByAssetID[id] ?? ShotReferenceCandidate(assetID: id, path: path)
            if let score = ImagePreferenceProfileService.referencePreferenceScore(forImagePath: path) {
                candidate.preferenceScore = max(candidate.preferenceScore, score)
            }
            if let updatedAt = ImagePreferenceProfileService.referenceUpdatedAt(forImagePath: path) {
                candidate.updatedAt = max(candidate.updatedAt ?? updatedAt, updatedAt)
            }
            candidate.hasContentHash = candidate.hasContentHash || ((row["content_hash_sha256"] as? String)?.isEmpty == false)
            candidate.hasVisualMetadata = candidate.hasVisualMetadata || boolValue(row["has_visual_metadata"])

            let ownerID = row["owner_id"] as? String
            let ownerParentID = row["owner_parent_id"] as? String
            let moment = row["moment"] as? String
            if let linkKind {
                candidate.addMatch(
                    scoredMatch(
                        linkKind: linkKind,
                        ownerID: ownerID,
                        ownerParentID: ownerParentID,
                        moment: moment,
                        input: input
                    )
                )
            }
            candidate.addMatch(
                spatialCharacterRegionMatch(
                    regionText: row["character_region_text"] as? String,
                    input: input
                )
            )
            if !queryTokens.isEmpty {
                candidate.considerQueryMatch(
                    Self.queryMatch(
                        queryTokens: queryTokens,
                        assetText: [
                            path,
                            row["visual_summary"] as? String,
                            row["visual_short_caption"] as? String,
                            row["visual_long_caption"] as? String,
                            row["visual_retrieval_json"] as? String,
                            row["tag_text"] as? String,
                            row["character_region_text"] as? String
                        ]
                        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .joined(separator: " ")
                    )
                )
            }
            candidatesByAssetID[id] = candidate
        }

        return candidatesByAssetID.values
            .map { $0.finalized() }
            .sorted {
                if $0.score == $1.score {
                    return $0.path < $1.path
                }
                return $0.score > $1.score
            }
            .prefix(maxImages)
            .map { candidate in
                ReferenceSelection(
                    assetID: candidate.assetID,
                    resolvedPath: candidate.path,
                    role: candidate.role,
                    score: candidate.score,
                    reason: candidate.reason
                )
            }
    }

    // MARK: - Helpers

    private struct ScoredShotReferenceMatch {
        var role: String
        var score: Double
        var reason: String
    }

    private struct ShotReferenceCandidate {
        var assetID: String
        var path: String
        var score: Double = 0.12
        var roleScores: [String: Double] = [:]
        var reasons: [String] = []
        var hasContentHash: Bool = false
        var hasVisualMetadata: Bool = false
        var preferenceScore: Double = 0
        var updatedAt: Date?
        var queryScore: Double = 0
        var queryReason: String?

        mutating func addMatch(_ match: ScoredShotReferenceMatch?) {
            guard let match else { return }
            score += match.score
            roleScores[match.role, default: 0] += match.score
            if !reasons.contains(match.reason) {
                reasons.append(match.reason)
            }
        }

        mutating func considerQueryMatch(_ match: ScoredShotReferenceMatch?) {
            guard let match,
                  match.score > queryScore else { return }
            queryScore = match.score
            queryReason = match.reason
            roleScores[match.role, default: 0] += match.score
        }

        func finalized() -> ShotReferenceCandidate {
            var copy = self
            if hasContentHash {
                copy.score += 0.03
            }
            if hasVisualMetadata {
                copy.score += 0.05
            }
            if preferenceScore > 0 {
                copy.score += preferenceScore * 0.08
                let label = preferenceScore >= 5.5 ? "Gary-liked reference" : "\(Int(preferenceScore.rounded()))★ Gary-rated reference"
                copy.reasons.append(label)
            }
            if let updatedAt {
                let ageDays = max(0, Date().timeIntervalSince(updatedAt) / 86_400)
                let recencyBoost = max(0, min(0.08, 0.08 * exp(-ageDays / 45.0)))
                if recencyBoost > 0 {
                    copy.score += recencyBoost
                    copy.reasons.append("recently reviewed/generated")
                }
            }
            if queryScore > 0 {
                copy.score += queryScore
                if let queryReason,
                   !copy.reasons.contains(queryReason) {
                    copy.reasons.append(queryReason)
                }
            }
            copy.score = min(copy.score, 1.0)
            return copy
        }

        var role: String {
            roleScores.max { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key > rhs.key
                }
                return lhs.value < rhs.value
            }?.key ?? "style_reference"
        }

        var reason: String {
            let prefix = reasons.prefix(3).joined(separator: "; ")
            return prefix.isEmpty ? "Matched based on project context" : prefix
        }
    }

    private func scoredMatch(
        linkKind: String,
        ownerID: String?,
        ownerParentID: String?,
        moment: String?,
        input: SelectorInput
    ) -> ScoredShotReferenceMatch? {
        let normalizedMoment = moment?.lowercased()
        let momentMatches: Bool = {
            guard let normalizedMoment,
                  let inputMoment = input.moment else { return false }
            return Self.momentAliases(for: inputMoment).contains(normalizedMoment)
        }()

        if linkKind == "storyboard_frame",
           ownerID == input.shotID {
            return ScoredShotReferenceMatch(
                role: "storyboard_layout_reference",
                score: momentMatches ? 0.62 : 0.48,
                reason: momentMatches ? "Storyboard frame for this moment" : "Storyboard frame for this shot"
            )
        }

        if linkKind == "scene_shot_image",
           ownerID == input.shotID {
            return ScoredShotReferenceMatch(
                role: "shot_reference",
                score: momentMatches ? 0.50 : 0.38,
                reason: momentMatches ? "Generated frame for this moment" : "Generated frame for this shot"
            )
        }

        if linkKind == "scene_shot_image",
           ownerParentID == input.sceneID {
            return ScoredShotReferenceMatch(
                role: "shot_reference",
                score: 0.20,
                reason: "Generated frame from the same scene"
            )
        }

        if let ownerID,
           input.characterIDs.contains(ownerID),
           linkKind.hasPrefix("character_") {
            let preferredCharacterKinds: Set<String> = [
                "character_animated",
                "character_master_source",
                "character_master_sheet_variant",
                "character_head_sheet_variant",
                "character_head_turn_variant",
                "character_costume_fullbody_variant",
                "character_costume_reference"
            ]
            return ScoredShotReferenceMatch(
                role: "character_reference",
                score: preferredCharacterKinds.contains(linkKind) ? 0.40 : 0.30,
                reason: preferredCharacterKinds.contains(linkKind)
                    ? "Character production reference"
                    : "Character reference"
            )
        }

        if let placeID = input.placeID,
           ownerID == placeID {
            switch linkKind {
            case "place_landmark_reference":
                return ScoredShotReferenceMatch(
                    role: "location_reference",
                    score: 0.40,
                    reason: "Landmark reference for the scene place"
                )
            case "place_generated", "place_reference", "place_angle_image":
                return ScoredShotReferenceMatch(
                    role: "location_reference",
                    score: 0.34,
                    reason: "Place reference for the scene"
                )
            case "place_master_map", "map3d_capture":
                return ScoredShotReferenceMatch(
                    role: "location_reference",
                    score: 0.26,
                    reason: "Spatial reference for the scene place"
                )
            default:
                break
            }
        }

        return nil
    }

    private func spatialCharacterRegionMatch(
        regionText: String?,
        input: SelectorInput
    ) -> ScoredShotReferenceMatch? {
        guard let regionText,
              !regionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let haystack = regionText.lowercased()
        let matchedCount = input.characterIDs.reduce(0) { count, characterID in
            haystack.contains(characterID.lowercased()) ? count + 1 : count
        }
        guard matchedCount > 0 else { return nil }
        return ScoredShotReferenceMatch(
            role: "character_reference",
            score: min(0.46, 0.30 + (Double(matchedCount - 1) * 0.08)),
            reason: matchedCount == 1
                ? "Manual spatial character tag"
                : "Manual spatial character tags for \(matchedCount) shot characters"
        )
    }

    private static func momentAliases(for rawMoment: String) -> Set<String> {
        switch rawMoment.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "begin", "beginning", "start":
            return ["begin", "beginning", "start"]
        case "middle", "mid":
            return ["middle", "mid"]
        case "end", "ending", "final":
            return ["end", "ending", "final"]
        default:
            return [rawMoment.lowercased()]
        }
    }

    private static func queryMatch(
        queryTokens: Set<String>,
        assetText: String
    ) -> ScoredShotReferenceMatch? {
        let assetTokens = referenceQueryTokens(from: assetText)
        let overlaps = queryTokens.intersection(assetTokens)
        guard !overlaps.isEmpty else { return nil }

        let rankedTerms = overlaps.sorted { lhs, rhs in
            if lhs.count == rhs.count {
                return lhs < rhs
            }
            return lhs.count > rhs.count
        }
        let visibleTerms = rankedTerms.prefix(5).joined(separator: ", ")
        let score = min(0.18, 0.035 + Double(min(overlaps.count, 6)) * 0.024)
        return ScoredShotReferenceMatch(
            role: "semantic_reference",
            score: score,
            reason: "Matched prompt terms in metadata/tags: \(visibleTerms)"
        )
    }

    private static func referenceQueryFilterTokens(
        from tokens: Set<String>,
        limit: Int
    ) -> [String] {
        tokens
            .sorted { lhs, rhs in
                if lhs.count == rhs.count {
                    return lhs < rhs
                }
                return lhs.count > rhs.count
            }
            .prefix(limit)
            .map { $0 }
    }

    private static func queryFilterSQL(tokenCount: Int) -> String {
        let perToken = """
            (
                LOWER(a.filename) LIKE ?
                OR LOWER(a.resolved_path) LIKE ?
                OR EXISTS(
                    SELECT 1
                    FROM image_visual_metadata vm
                    WHERE vm.image_asset_id = a.id
                      AND (
                          LOWER(COALESCE(vm.summary, '')) LIKE ?
                          OR LOWER(COALESCE(vm.short_caption, '')) LIKE ?
                          OR LOWER(COALESCE(vm.long_caption, '')) LIKE ?
                          OR LOWER(COALESCE(vm.retrieval_json, '')) LIKE ?
                      )
                )
                OR EXISTS(
                    SELECT 1
                    FROM image_tag_assignments ta
                    JOIN image_tags t ON ta.tag_id = t.id
                    WHERE ta.image_asset_id = a.id
                      AND ta.is_negative = 0
                      AND (
                          LOWER(t.slug) LIKE ?
                          OR LOWER(COALESCE(t.display_name, '')) LIKE ?
                      )
                )
            )
            """
        return "(" + Array(repeating: perToken, count: max(1, tokenCount)).joined(separator: " OR ") + ")"
    }

    private static let referenceQueryStopWords: Set<String> = [
        "about", "above", "across", "after", "again", "against", "also", "and", "angle",
        "another", "around", "because", "before", "behind", "being", "between", "camera",
        "close", "closer", "color", "colours", "colors", "down", "during", "each", "every",
        "frame", "from", "full", "into", "like", "look", "looks", "make", "middle", "more",
        "onto", "over", "plain", "prompt", "render", "scene", "shot", "show", "shows",
        "style", "that", "their", "there", "these", "this", "through", "toward", "towards",
        "under", "very", "with", "without"
    ]

    private static func referenceQueryTokens(from rawText: String?) -> Set<String> {
        guard let rawText else { return [] }
        let parts = rawText
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
        var tokens = Set<String>()
        for part in parts {
            let token = String(part)
            guard token.count >= 4,
                  !referenceQueryStopWords.contains(token) else { continue }
            tokens.insert(token)
            if token.hasSuffix("ing"), token.count > 6 {
                tokens.insert(String(token.dropLast(3)))
            } else if token.hasSuffix("ed"), token.count > 5 {
                tokens.insert(String(token.dropLast(2)))
            } else if token.hasSuffix("s"), token.count > 5 {
                tokens.insert(String(token.dropLast()))
            }
        }
        return tokens
    }

    private func boolValue(_ value: Any?) -> Bool {
        if let bool = value as? Bool { return bool }
        if let int = value as? Int { return int != 0 }
        if let int64 = value as? Int64 { return int64 != 0 }
        if let double = value as? Double { return double != 0 }
        return false
    }

    private func getEmbeddingVector(assetID: String, kind: String) async throws -> (vector: [Float], norm: Float)? {
        let sql = """
            SELECT vector_blob, vector_norm
            FROM image_embeddings
            WHERE image_asset_id = ? AND embedding_kind = ?
            LIMIT 1
        """

        guard let row = try await store.querySingle(sql, [assetID, kind]),
              let vectorData = row["vector_blob"] as? Data,
              let norm = row["vector_norm"] as? Double else {
            return nil
        }

        let vector = vectorData.withUnsafeBytes { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }

        return (vector: vector, norm: Float(norm))
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float], _ normA: Float, _ normB: Float) -> Float {
        guard a.count == b.count, normA > 0, normB > 0 else { return 0 }

        let dotProduct = zip(a, b).reduce(0.0) { $0 + $1.0 * $1.1 }
        return dotProduct / (normA * normB)
    }

    private func determineRole(for assetID: String) async throws -> String {
        let links = try await store.linksForAsset(assetID)
        if links.contains(where: { $0.linkKind == .storyboardFrame }) {
            return "storyboard_layout_reference"
        }
        if links.contains(where: { $0.linkKind == .sceneShotImage }) {
            return "shot_reference"
        }
        if links.contains(where: { $0.linkKind.rawValue.hasPrefix("character_") }) {
            return "character_reference"
        }
        if links.contains(where: {
            $0.linkKind == .placeGenerated ||
            $0.linkKind == .placeReference ||
            $0.linkKind == .placeLandmarkReference ||
            $0.linkKind == .placeMasterMap ||
            $0.linkKind == .map3DCapture
        }) {
            return "location_reference"
        }
        return "style_reference"
    }
}
