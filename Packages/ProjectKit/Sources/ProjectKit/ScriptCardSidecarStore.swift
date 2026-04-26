import Foundation

// MARK: - Script Card Sidecar Store
//
// Disk I/O helpers for `<project>/Metadata/script-cards.json`. Pure
// Foundation; no UI or actor isolation, so unit tests and the Write
// workspace can both call it.

public enum ScriptCardSidecarStore {

    // MARK: Errors

    public enum LoadError: Error, Equatable {
        case unsupportedSchemaVersion(found: Int, expected: Int)
    }

    // MARK: Load

    /// Load the sidecar from `Metadata/script-cards.json`. Returns an
    /// empty document if the file does not exist (a new project, or one
    /// that has not yet been migrated). Throws on JSON corruption or
    /// future schema versions we do not understand.
    public static func load(projectURL: URL) throws -> ScriptDocumentCards {
        let url = ProjectPaths(root: projectURL).scriptCardsJSON
        guard FileManager.default.fileExists(atPath: url.path) else {
            return ScriptDocumentCards()
        }
        let data = try Data(contentsOf: url)
        let decoder = makeDecoder()
        let document = try decoder.decode(ScriptDocumentCards.self, from: data)
        guard document.schemaVersion <= ScriptDocumentCards.currentSchemaVersion else {
            throw LoadError.unsupportedSchemaVersion(
                found: document.schemaVersion,
                expected: ScriptDocumentCards.currentSchemaVersion
            )
        }
        return document
    }

    // MARK: Save

    /// Atomically write the sidecar. Creates `Metadata/` if missing.
    public static func save(_ document: ScriptDocumentCards, projectURL: URL) throws {
        let paths = ProjectPaths(root: projectURL)
        let metadataDir = paths.metadata
        if !FileManager.default.fileExists(atPath: metadataDir.path) {
            try FileManager.default.createDirectory(
                at: metadataDir,
                withIntermediateDirectories: true
            )
        }

        var stamped = document
        stamped.schemaVersion = ScriptDocumentCards.currentSchemaVersion
        stamped.updatedAt = Date()

        let encoder = makeEncoder()
        let data = try encoder.encode(stamped)
        try data.write(to: paths.scriptCardsJSON, options: [.atomic])
    }

    // MARK: Coders

    /// ISO8601 formatter with fractional-second precision so dates round
    /// trip exactly through encode → decode (the default `.iso8601`
    /// strategy truncates to whole seconds, breaking equality).
    /// `ISO8601DateFormatter` is not `Sendable`; build a fresh one each
    /// call — they're cheap and the encode/decode hot paths are not.
    private static func makeISOFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }

    /// Stable JSON encoding so file diffs stay reviewable in git.
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(makeISOFormatter().string(from: date))
        }
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = makeISOFormatter().date(from: raw) { return date }
            // Fall back to plain ISO8601 (older sidecar files written
            // before fractional-seconds support landed).
            let fallback = ISO8601DateFormatter()
            fallback.formatOptions = [.withInternetDateTime]
            if let date = fallback.date(from: raw) { return date }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Cannot decode ISO8601 date: \(raw)"
            )
        }
        return decoder
    }
}
