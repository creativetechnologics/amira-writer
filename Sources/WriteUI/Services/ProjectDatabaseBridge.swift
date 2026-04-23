import Foundation

@available(macOS 26.0, *)
enum ProjectDatabaseBridge {
    static let metadataPaths = ["Metadata/project.json", "project.json"]
    static let charactersPaths = ["Characters/characters.json", "characters.json"]
    static let scratchpadPath = "Write/libretto-scratchpad.txt"

    static func loadWriterProject(url: URL) async throws -> ProjectLoadResult {
        let phase1 = try await OWPProjectIO.loadPhase1(from: url)
        let stubs = phase1.stubs
        let metadata = phase1.metadata
        let characters = (try? await OWPProjectIO.loadCharacterManifestAsync(from: url)) ?? []
        let assets = stubs.map { stub in
            OWSSongAsset(relativePath: stub.relativePath, document: makePlaceholderDocument(from: stub))
        }
        let librettoFiles = stubs.map { stub in
            ProjectTextFile(id: UUID(), relativePath: stub.relativePath, content: "")
        }

        return ProjectLoadResult(
            workingProjectURL: url,
            metadata: metadata,
            stubs: stubs,
            assets: assets,
            librettoFiles: librettoFiles,
            characters: characters,
            hydratedScenePaths: []
        )
    }

    static func decodeCharacters(from artifactData: Data?) throws -> [OPWCharacter] {
        guard let artifactData else { return [] }
        let decoded = try OWPProjectIO.configuredDecoder().decode(OPWCharactersFile.self, from: artifactData)
        return decoded.characters
    }

    static func makePlaceholderDocument(from stub: SongStub) -> OWSSongDocument {
        let now = Date()
        let versionID = UUID()
        var document = OWSSongDocument(
            songID: stub.id,
            title: stub.displayName.toTitleCase(),
            canonicalTitle: stub.displayName.lowercased(),
            notes: "",
            updatedAt: now,
            activeVersionID: versionID,
            versions: [
                OWSVersionPayload(
                    id: versionID,
                    label: "Current Draft",
                    createdAt: now,
                    updatedAt: now,
                    lyrics: "",
                    saveType: .manual,
                    userLabel: nil,
                    isBookmarked: false
                )
            ]
        )
        document.normalize()
        return document
    }

}

@available(macOS 26.0, *)
struct ProjectLoadResult {
    let workingProjectURL: URL
    let metadata: ProjectMetadata
    let stubs: [SongStub]
    let assets: [OWSSongAsset]
    let librettoFiles: [ProjectTextFile]
    let characters: [OPWCharacter]
    let hydratedScenePaths: Set<String>
}
