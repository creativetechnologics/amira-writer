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
        var candidates: [(assetID: String, path: String, score: Double)] = []

        // Build query based on input
        var conditions: [String] = []
        var params: [Any] = []

        // Filter by place
        if let placeID = input.placeID {
            conditions.append("(l.owner_id = ? AND l.link_kind = 'place_generated')")
            params.append(placeID)
        }

        // Filter by character
        for charID in input.characterIDs {
            conditions.append("(l.owner_id = ? AND l.link_kind LIKE 'character_%')")
            params.append(charID)
        }

        // Filter by scene shot
        if let shotID = input.shotID {
            conditions.append("(l.owner_id = ? AND l.link_kind = 'scene_shot_image')")
            params.append(shotID)
        }

        let whereClause = conditions.isEmpty ? "" : "AND (" + conditions.joined(separator: " OR ") + ")"

        let sql = """
            SELECT DISTINCT a.id, a.resolved_path
            FROM image_assets a
            LEFT JOIN image_asset_links l ON a.id = l.image_asset_id
            WHERE a.is_missing = 0
            \(whereClause)
            LIMIT ?
        """

        params.append(maxImages * 3) // Get more candidates for scoring

        let rows = try await store.query(sql, params)

        for row in rows {
            guard let id = row["id"] as? String,
                  let path = row["resolved_path"] as? String else { continue }

            var score = 0.5 // Base score

            // Boost for matching place
            if input.placeID != nil {
                score += 0.15
            }

            // Boost for matching characters
            score += Double(input.characterIDs.count) * 0.1

            // Boost for having analysis metadata
            if let metadata = try await store.assetByID(id),
               metadata.contentHashSHA256 != nil {
                score += 0.05
            }

            candidates.append((assetID: id, path: path, score: min(score, 1.0)))
        }

        // Sort by score and take top N
        let sorted = candidates.sorted { $0.score > $1.score }.prefix(maxImages)

        var selections: [ReferenceSelection] = []
        for candidate in sorted {
            selections.append(
                ReferenceSelection(
                    assetID: candidate.assetID,
                    resolvedPath: candidate.path,
                    role: try await determineRole(for: candidate.assetID),
                    score: candidate.score,
                    reason: "Matched based on project context"
                )
            )
        }
        return selections
    }

    // MARK: - Helpers

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
