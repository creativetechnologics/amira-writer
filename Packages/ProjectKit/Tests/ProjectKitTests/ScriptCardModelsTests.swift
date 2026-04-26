import XCTest
@testable import ProjectKit

final class ScriptCardModelsTests: XCTestCase {

    // MARK: - BracketDSLParser

    func testBracketDSLParser_ParsesCanonicalCameraDirection() throws {
        let parsed = try XCTUnwrap(BracketDSLParser.parse(
            "[camera: zoom_in | from=wide | to=close | bars=17-24]"
        ))
        XCTAssertEqual(parsed.tag, "camera")
        XCTAssertEqual(parsed.primary, "zoom_in")
        XCTAssertEqual(parsed.parameters["from"], "wide")
        XCTAssertEqual(parsed.parameters["to"], "close")
        XCTAssertEqual(parsed.parameters["bars"], "17-24")
    }

    func testBracketDSLParser_HonoursQuotedSegments() throws {
        let parsed = try XCTUnwrap(BracketDSLParser.parse(
            #"[scene: "Mountain Valley" | bg=mountain_valley_dawn | lighting=day]"#
        ))
        XCTAssertEqual(parsed.tag, "scene")
        XCTAssertEqual(parsed.primary, "Mountain Valley")
        XCTAssertEqual(parsed.parameters["bg"], "mountain_valley_dawn")
        XCTAssertEqual(parsed.parameters["lighting"], "day")
    }

    func testBracketDSLParser_RejectsMalformedInput() {
        XCTAssertNil(BracketDSLParser.parse("just plain text"))
        XCTAssertNil(BracketDSLParser.parse("[: missing tag]"))
    }

    func testBracketDSLParser_KeepsUnknownTagsAndKeys() throws {
        let parsed = try XCTUnwrap(BracketDSLParser.parse(
            "[future_thing: foo | weird_key=value | another=42]"
        ))
        XCTAssertEqual(parsed.tag, "future_thing")
        XCTAssertEqual(parsed.parameters["weird_key"], "value")
        XCTAssertEqual(parsed.parameters["another"], "42")
    }

    // MARK: - DSLExporter round-trip

    func testExporter_RendersShotCardWithBarsAndIntent() {
        let shot = ScriptShotCard(
            label: "A1",
            direction: "Find Luke through the crowd",
            camera: CameraSpec(
                shotSize: "close",
                movement: "track",
                focus: "luke",
                intent: "isolation",
                label: "A1"
            ),
            timing: TimingSpec(startBar: 17, endBar: 24),
            status: .manual,
            provenance: CardProvenance(source: .manual)
        )
        let dsl = ScriptCardDSLExporter.renderShot(shot)
        XCTAssertEqual(
            dsl,
            "[camera: track | label=A1 | focus=luke | size=close | intent=isolation | bars=17-24]"
        )
    }

    func testExporter_DefaultsToHoldWhenMovementMissing() {
        let shot = ScriptShotCard(
            camera: CameraSpec(focus: "luke"),
            timing: TimingSpec(startBar: 5),
            status: .manual,
            provenance: CardProvenance(source: .manual)
        )
        XCTAssertEqual(
            ScriptCardDSLExporter.renderShot(shot),
            "[camera: hold | focus=luke | bars=5]"
        )
    }

    func testExporter_PreservesOriginalRawMarkupForImportedCards() {
        let raw = "[camera: zoom_in | from=wide | to=close | bars=1-8]"
        let shot = ScriptShotCard(
            camera: CameraSpec(movement: "zoom_in"),
            status: .importedLegacy,
            provenance: CardProvenance(source: .importedLegacy, originalRawMarkup: raw)
        )
        XCTAssertEqual(ScriptCardDSLExporter.renderShot(shot), raw)
    }

    func testExporter_ActionCardPrefersOriginalRaw() {
        let raw = "[Luke crosses the bridge]"
        let action = ActionCard(text: "Luke crosses the bridge", originalRawMarkup: raw)
        XCTAssertEqual(ScriptCardDSLExporter.renderAction(action), raw)
    }

    func testExporter_ActionCardWithoutRawRendersBracketAction() {
        let action = ActionCard(text: "Luke arrives", originalRawMarkup: "")
        XCTAssertEqual(
            ScriptCardDSLExporter.renderAction(action),
            "[action: Luke arrives]"
        )
    }

    func testExporter_OrdersDirectionsThenActionsThenShots() {
        let scene = ScriptScene(
            directions: [LegacyDirectionCard(
                address: "1.01.0.001",
                descriptionText: "Wide shot of the marketplace",
                originalRawMarkup: "[[1.01.0.001 - Wide shot of the marketplace]]"
            )],
            actions: [ActionCard(text: "Luke arrives", originalRawMarkup: "[Luke arrives]")],
            shots: [ScriptShotCard(
                camera: CameraSpec(movement: "track", focus: "luke"),
                timing: TimingSpec(startBar: 1, endBar: 4),
                provenance: CardProvenance(source: .manual)
            )]
        )
        let lines = ScriptCardDSLExporter.exportDSL(scene)
            .split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 3)
        XCTAssertTrue(lines[0].hasPrefix("[[1.01.0.001"))
        XCTAssertEqual(lines[1], "[Luke arrives]")
        XCTAssertEqual(lines[2], "[camera: track | focus=luke | bars=1-4]")
    }

    // MARK: - Codable round-trip

    func testScriptDocumentCards_CodableRoundTrip() throws {
        let doc = ScriptDocumentCards(
            songs: [
                "Songs/VerseOne.ows": SongScriptCards(
                    songRelativePath: "Songs/VerseOne.ows",
                    scenes: [
                        ScriptScene(
                            label: "Marketplace",
                            directions: [LegacyDirectionCard(
                                address: "1.01.0.001",
                                descriptionText: "Wide shot",
                                originalRawMarkup: "[[1.01.0.001 - Wide shot]]"
                            )],
                            shots: [ScriptShotCard(
                                camera: CameraSpec(movement: "zoom_in", focus: "luke"),
                                tags: TagSet(characters: ["luke"], mood: ["isolation"]),
                                timing: TimingSpec(startBar: 1, endBar: 4),
                                status: .importedLegacy,
                                provenance: CardProvenance(
                                    source: .importedLegacy,
                                    originalRawMarkup: "[camera: zoom_in | focus=luke | bars=1-4]"
                                )
                            )]
                        )
                    ]
                )
            ]
        )

        // Round-trip the document through encode → decode → encode and
        // assert the second encoding matches the first byte-for-byte.
        // Direct `==` on Date would fail because ISO8601-with-fractional-
        // seconds rounds to ms while `Date` carries finer precision.
        let encoder = ScriptCardSidecarStore.makeEncoder()
        let decoder = ScriptCardSidecarStore.makeDecoder()
        let firstPass = try encoder.encode(doc)
        let decoded = try decoder.decode(ScriptDocumentCards.self, from: firstPass)
        let secondPass = try encoder.encode(decoded)
        XCTAssertEqual(firstPass, secondPass)

        // Spot-check non-date fields survive intact.
        XCTAssertEqual(decoded.songs.keys.sorted(), doc.songs.keys.sorted())
        let decodedSong = try XCTUnwrap(decoded.songs["Songs/VerseOne.ows"])
        let expectedSong = try XCTUnwrap(doc.songs["Songs/VerseOne.ows"])
        XCTAssertEqual(decodedSong.scenes.first?.shots.first?.camera.movement, "zoom_in")
        XCTAssertEqual(decodedSong.scenes.first?.shots.first?.tags.mood, ["isolation"])
        XCTAssertEqual(decodedSong.id, expectedSong.id)
    }

    // MARK: - Sidecar store

    func testSidecarStore_LoadReturnsEmptyDocumentWhenFileMissing() throws {
        let tempRoot = makeTempProject()
        defer { try? FileManager.default.removeItem(at: tempRoot) }
        let document = try ScriptCardSidecarStore.load(projectURL: tempRoot)
        XCTAssertTrue(document.songs.isEmpty)
    }

    func testSidecarStore_SaveThenLoadPreservesContent() throws {
        let tempRoot = makeTempProject()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        var doc = ScriptDocumentCards()
        doc.songs["Songs/VerseOne.ows"] = SongScriptCards(
            songRelativePath: "Songs/VerseOne.ows",
            scenes: [ScriptScene(label: "Marketplace")]
        )

        try ScriptCardSidecarStore.save(doc, projectURL: tempRoot)
        let url = ProjectPaths(root: tempRoot).scriptCardsJSON
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let loaded = try ScriptCardSidecarStore.load(projectURL: tempRoot)
        XCTAssertEqual(loaded.songs.keys.sorted(), ["Songs/VerseOne.ows"])
        XCTAssertEqual(loaded.songs["Songs/VerseOne.ows"]?.scenes.first?.label, "Marketplace")
        XCTAssertEqual(loaded.schemaVersion, ScriptDocumentCards.currentSchemaVersion)
    }

    func testSidecarStore_RejectsFutureSchemaVersion() throws {
        let tempRoot = makeTempProject()
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(
            at: ProjectPaths(root: tempRoot).metadata,
            withIntermediateDirectories: true
        )
        let url = ProjectPaths(root: tempRoot).scriptCardsJSON
        let payload = """
        {
          "schemaVersion": 9999,
          "songs": {},
          "updatedAt": "2026-04-26T00:00:00Z"
        }
        """
        try payload.data(using: .utf8)!.write(to: url)

        XCTAssertThrowsError(try ScriptCardSidecarStore.load(projectURL: tempRoot)) { error in
            guard case ScriptCardSidecarStore.LoadError.unsupportedSchemaVersion = error else {
                XCTFail("Expected unsupportedSchemaVersion, got \(error)")
                return
            }
        }
    }

    // MARK: - Helpers

    private func makeTempProject() -> URL {
        let url = FileManager.default
            .temporaryDirectory
            .appendingPathComponent("script-cards-tests-\(UUID().uuidString).owp")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
