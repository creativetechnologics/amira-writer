import SwiftUI
import XCTest
@testable import WriteUI
import ProjectKit

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
        let color = Color(hex: "not-a-color", fallback: ScriptPalette.scriptBackground)
        let fallback = Color(hex: ScriptPalette.scriptBackground, fallback: "#FFFFFF")

        XCTAssertEqual(ScriptPalette.normalizedHex("not-a-color"), nil)
        XCTAssertEqual(
            ColorHex.hex(from: color),
            ColorHex.hex(from: fallback)
        )
    }
}
