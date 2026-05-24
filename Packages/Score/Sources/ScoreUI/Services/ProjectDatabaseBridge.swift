import Foundation
import ProjectKit

enum ProjectDatabaseBridge {
    static let scoreActorID = ProjectClientIdentity.actorID(for: "score")
    static let legacyScoreActorID = ProjectClientIdentity.actorID(for: "amira-score")
    static let scoreActorIDs: Set<String> = [scoreActorID, legacyScoreActorID]
    static let metadataPath = OWPProjectIO.projectMetadataFile
    static let legacyMetadataPath = "project.json"
    static let projectInstrumentsPath = OWPProjectIO.projectInstrumentsFile
    static let legacyProjectInstrumentsPath = OWPProjectIO.legacyProjectInstrumentsFile

    struct ScoreProjectLoad: @unchecked Sendable {
        var workingProjectURL: URL
        var metadata: ProjectMetadata
        var projectInstrumentMappings: [String: InstrumentMapping]
        var stubs: [SongStub]
        var songAssets: [OWSSongAsset]
        var librettoFiles: [ProjectTextFile]
        var hydratedSongPaths: Set<String>
    }

    static func loadScoreProject(url: URL) async throws -> ScoreProjectLoad {
        try await Task.detached(priority: .userInitiated) {
            let (metadata, stubs, _) = try await OWPProjectIO.loadPhase1(from: url)
            let songAssets = stubs.map(placeholderSongAsset(for:))
            let librettoFiles = stubs.map { ProjectTextFile(id: UUID(), relativePath: $0.relativePath, content: "") }
            let hydratedPaths = Set<String>()

            let projectInstrumentMappings: [String: InstrumentMapping]
            if url.pathExtension.lowercased() != "ows" {
                projectInstrumentMappings = OWPProjectIO.loadProjectInstrumentMappings(from: url)
            } else {
                projectInstrumentMappings = [:]
            }

            return ScoreProjectLoad(
                workingProjectURL: url,
                metadata: metadata,
                projectInstrumentMappings: projectInstrumentMappings,
                stubs: stubs,
                songAssets: songAssets,
                librettoFiles: librettoFiles,
                hydratedSongPaths: hydratedPaths
            )
        }.value
    }

    private static func placeholderSongAsset(for stub: SongStub) -> OWSSongAsset {
        let trimmedTitle = stub.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = {
            guard let trimmedTitle, !trimmedTitle.isEmpty else {
                return stub.displayName.toTitleCase()
            }
            return trimmedTitle
        }()
        let trimmedCanonicalTitle = stub.canonicalTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        let canonicalTitle = {
            guard let trimmedCanonicalTitle, !trimmedCanonicalTitle.isEmpty else {
                return title.lowercased()
            }
            return trimmedCanonicalTitle
        }()
        return OWSSongAsset(
            relativePath: stub.relativePath,
            document: OWSSongDocument(
                songID: stub.id,
                title: title,
                canonicalTitle: canonicalTitle,
                notes: "",
                updatedAt: Date(),
                activeVersionID: nil,
                versions: [],
                instrumentMappings: [:]
            )
        )
    }

    static func hydratePlayback(projectURL: URL, relativePath: String) async -> OWSPlaybackSnapshot? {
        guard projectURL.pathExtension.lowercased() != "ows" else { return nil }
        guard let stub = OWPProjectIO.enumerateProjectSongStubs(in: projectURL)
            .first(where: { $0.relativePath == relativePath }) else {
            return nil
        }
        guard let asset = try? await OWPProjectIO.loadSongAsync(stub: stub),
              let version = asset.document.activeVersion() else {
            return nil
        }
        return version.playback
    }
}
