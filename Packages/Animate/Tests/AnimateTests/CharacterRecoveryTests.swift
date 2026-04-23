import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
@MainActor
final class CharacterRecoveryTests: XCTestCase {
    func testOpenOWPWithoutCharactersManifestRecoversPersistedRigCharacters() async throws {
        let projectURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CharacterRecoveryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: projectURL) }

        try writeRig(
            AnimationCharacter(
                id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                name: "Johnny Ward",
                description: "",
                owpSlug: "johnny",
                storageSlug: "johnny-ward",
                parts: []
            ),
            to: projectURL.appendingPathComponent("Characters/johnny-ward/rig.json")
        )

        try writeRig(
            AnimationCharacter(
                id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                name: "Amira Nazari",
                description: "",
                owpSlug: "amira",
                storageSlug: "amira-nazari",
                parts: []
            ),
            to: projectURL.appendingPathComponent("Characters/amira-nazari/rig.json")
        )

        let store = AnimateStore()
        store.disableExternalFileWatch = true

        await store.openOWP(url: projectURL)

        XCTAssertEqual(
            Set(store.characters.map(\.name)),
            Set(["Johnny Ward", "Amira Nazari"])
        )
        XCTAssertEqual(store.characters.count, 2)
    }

    private func writeRig(_ character: AnimationCharacter, to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(character).write(to: url)
    }
}
