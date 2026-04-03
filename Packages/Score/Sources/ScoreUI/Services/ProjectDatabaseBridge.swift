import Foundation
import ProjectKit

enum ProjectDatabaseBridge {
    static let scoreActorID = ProjectClientIdentity.actorID(for: "score")
    static let legacyScoreActorID = ProjectClientIdentity.actorID(for: "novotro-score")
    static let scoreActorIDs: Set<String> = [scoreActorID, legacyScoreActorID]
    static let metadataPath = OWPProjectIO.projectMetadataFile
    static let legacyMetadataPath = "project.json"
    static let projectInstrumentsPath = OWPProjectIO.projectInstrumentsFile

    struct ScoreProjectLoad {
        var workingProjectURL: URL
        var metadata: ProjectMetadata
        var projectInstrumentMappings: [String: InstrumentMapping]
        var stubs: [SongStub]
        var songAssets: [OWSSongAsset]
        var librettoFiles: [ProjectTextFile]
        var hydratedSongPaths: Set<String>
    }

    static func loadScoreProject(url: URL) async throws -> ScoreProjectLoad {
        let (metadata, stubs, _) = try await OWPProjectIO.loadPhase1(from: url)
        var songAssets: [OWSSongAsset] = []
        var librettoFiles: [ProjectTextFile] = []
        var hydratedPaths = Set<String>()
        for stub in stubs {
            let asset = try await OWPProjectIO.loadSongAsync(stub: stub)
            songAssets.append(asset)
            hydratedPaths.insert(asset.relativePath)
            if let version = asset.document.activeVersion() {
                librettoFiles.append(
                    ProjectTextFile(id: UUID(), relativePath: asset.relativePath, content: version.lyrics)
                )
            }
        }

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
    }

    static func hydratePlayback(projectURL: URL, relativePath: String) async -> OWSPlaybackSnapshot? {
        guard projectURL.pathExtension.lowercased() != "ows" else { return nil }
        let songsRoot = projectURL.appendingPathComponent(OWPProjectIO.songsDir)
        guard let stub = OWPProjectIO.enumerateSongStubs(in: songsRoot)
                .first(where: { $0.relativePath == relativePath }) else {
            return nil
        }
        guard let asset = try? await OWPProjectIO.loadSongAsync(stub: stub),
              let version = asset.document.activeVersion() else {
            return nil
        }
        return version.playback
    }

    // MARK: - Helpers

    static func configuredDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func configuredEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
