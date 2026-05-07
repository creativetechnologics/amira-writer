import XCTest
@testable import WriteUI

@available(macOS 26.0, *)
final class ProjectSettingsTests: XCTestCase {
    func testScriptBackgroundColorRoundTripsThroughProjectSettings() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let settings = ProjectSettingsData(scriptBackgroundColorHex: "#24272A")

        ProjectSettingsPersistence.save(settings, to: tempDirectory)
        let loaded = ProjectSettingsPersistence.load(from: tempDirectory)

        XCTAssertEqual(loaded.scriptBackgroundColorHex, "#24272A")
    }

    func testScriptBackgroundColorInvalidHexFallsBackToDefault() {
        let color = ScriptMarkupPalette.color(
            from: "not-a-color",
            fallback: ScriptMarkupPalette.defaultScriptBackgroundHex
        )
        let fallback = ScriptMarkupPalette.color(
            from: ScriptMarkupPalette.defaultScriptBackgroundHex,
            fallback: "#FFFFFF"
        )

        XCTAssertEqual(ScriptMarkupPalette.normalizedHex("not-a-color"), nil)
        XCTAssertEqual(
            ScriptMarkupPalette.hex(from: color, fallback: "#FFFFFF"),
            ScriptMarkupPalette.hex(from: fallback, fallback: "#FFFFFF")
        )
    }
}
