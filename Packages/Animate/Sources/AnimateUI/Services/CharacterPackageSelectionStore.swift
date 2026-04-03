import Foundation

struct CharacterPackageSelectionManifest: Codable, Sendable {
    var schemaVersion: Int
    var activePackageIDsByCharacterSlug: [String: UUID]

    init(
        schemaVersion: Int = 1,
        activePackageIDsByCharacterSlug: [String: UUID] = [:]
    ) {
        self.schemaVersion = schemaVersion
        self.activePackageIDsByCharacterSlug = activePackageIDsByCharacterSlug
    }
}

struct CharacterPackageSelectionStore: Sendable {
    private static let selectionsFilename = "character-package-selections.json"

    func load(from animateURL: URL) -> CharacterPackageSelectionManifest {
        let fileURL = selectionsURL(in: animateURL)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CharacterPackageSelectionManifest()
        }

        guard let data = try? Data(contentsOf: fileURL),
              let manifest = try? JSONDecoder().decode(CharacterPackageSelectionManifest.self, from: data) else {
            return CharacterPackageSelectionManifest()
        }

        return manifest
    }

    func save(_ manifest: CharacterPackageSelectionManifest, to animateURL: URL) throws {
        let fileURL = selectionsURL(in: animateURL)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        try data.write(to: fileURL)
    }

    func activePackageID(for characterSlug: String, in animateURL: URL) -> UUID? {
        load(from: animateURL).activePackageIDsByCharacterSlug[characterSlug]
    }

    func selectionsURL(in animateURL: URL) -> URL {
        animateURL.appendingPathComponent(Self.selectionsFilename)
    }
}
