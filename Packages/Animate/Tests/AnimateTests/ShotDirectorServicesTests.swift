import XCTest
@testable import AnimateUI

@available(macOS 26.0, *)
final class ShotDirectorServicesTests: XCTestCase {
    func testVisualContractValidatorBlocksForbiddenPowerLines() {
        let spec = makeSpec(
            prompt: "Wide valley road with overhead power lines.",
            visualContract: makeContract(places: ["Korengal Valley"])
        )

        let blockers = ShotSpecValidationService().contentBlockers(for: spec)

        XCTAssertTrue(blockers.contains { $0.code == .blockedForbiddenPromptTerm })
    }

    func testVisualContractValidatorBlocksMissingPlaces() {
        let spec = makeSpec(
            prompt: "A clear shot of the valley road.",
            visualContract: makeContract(places: [])
        )

        let blockers = ShotSpecValidationService().contentBlockers(for: spec)

        XCTAssertTrue(blockers.contains { $0.field == "visualContract.places" })
    }

    func testDirectorInputStoreRoundTripsAcceptedNotes() throws {
        let projectRoot = try makeTemporaryProjectRoot()
        let sceneID = UUID()
        let shotID = UUID()
        var record = ShotDirectorInputRecord(
            status: "accepted",
            sceneID: sceneID,
            shotID: shotID,
            shotIndex: 0,
            transcriptText: "Make the river dominate the foreground.",
            proposedAction: "River in foreground, convoy above."
        )
        record.acceptedAt = Date()

        let url = try ShotDirectorInputStore.write(record, projectRoot: projectRoot)
        let loaded = ShotDirectorInputStore.read(projectRoot: projectRoot, sceneID: sceneID, shotID: shotID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(loaded?.status, "accepted")
        XCTAssertEqual(
            ShotDirectorInputStore.acceptedNotes(for: loaded),
            "River in foreground, convoy above. Make the river dominate the foreground."
        )
    }

    private func makeSpec(
        prompt: String,
        visualContract: ShotVisualContract?
    ) -> EffectiveShotSpec {
        EffectiveShotSpec(
            id: UUID(),
            createdAt: Date(),
            source: "active_ows_camera_card",
            sceneID: UUID(),
            sceneName: "Test Scene",
            shotID: UUID(),
            shotIndex: 0,
            shotName: "Test Shot",
            shotCardLabel: "Test Shot",
            shotCardFocus: nil,
            shotCardNotes: nil,
            shotCardContinuityNotes: nil,
            shotCardPlaces: visualContract?.places,
            shotCardProps: visualContract?.props,
            shotCardLandmarks: visualContract?.landmarks,
            visualContract: visualContract,
            startFrame: 0,
            endFrame: 24,
            backgroundID: UUID(),
            backgroundName: "Korengal Valley",
            approvedPlaceImagePath: nil,
            focusCharacterID: nil,
            focusCharacterSlug: nil,
            focusCharacterName: nil,
            characterIDs: [],
            characterSlugs: [],
            characterNames: [],
            cameraShot: nil,
            shotIntent: nil,
            action: "A clear shot of the valley road.",
            notes: "",
            lyricExcerpt: nil,
            worldPeriod: "2008 Afghanistan",
            regionalWorldCues: "Mountain valley",
            architectureMaterials: "",
            lighting: "",
            cameraFraming: "",
            visualTone: "",
            negativeGuardrails: [],
            prompt: prompt,
            blockers: []
        )
    }

    private func makeContract(places: [String]) -> ShotVisualContract {
        ShotVisualContract(
            source: "active_ows_camera_card",
            sourceLineNumber: 1,
            cameraCardIndex: 0,
            cameraCardCount: 1,
            label: "Test Shot",
            focus: nil,
            visibleCharacters: [],
            leftCharacters: [],
            middleCharacters: [],
            rightCharacters: [],
            leftFacing: nil,
            middleFacing: nil,
            rightFacing: nil,
            places: places,
            props: [],
            landmarks: [],
            timeOfDay: "dawn",
            interiorExterior: "exterior",
            weatherAtmosphere: nil,
            lightSource: nil,
            lens: nil,
            cameraAngle: nil,
            depthOfField: nil,
            continuityNotes: nil,
            notes: nil,
            acceptedDirectorNotes: nil
        )
    }

    private func makeTemporaryProjectRoot() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ShotDirectorServicesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }
}
