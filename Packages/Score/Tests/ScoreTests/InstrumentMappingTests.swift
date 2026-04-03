import Foundation
import Testing
@testable import ScoreUI

@Suite("SoundFontAssignment")
struct SoundFontAssignmentTests {
    @Test func roundTripCodable() throws {
        let original = SoundFontAssignment(
            sf2RelativePath: "SoundFonts/Piano.sf2",
            sf2FileName: "Piano.sf2",
            bankMSB: 0, bankLSB: 0, program: 1
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SoundFontAssignment.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("AudioUnitAssignment")
struct AudioUnitAssignmentTests {
    @Test func roundTripCodable() throws {
        let original = AudioUnitAssignment(
            componentType: 1635085685,
            componentSubType: 1684828960,
            componentManufacturer: 1634758764,
            presetData: nil
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(AudioUnitAssignment.self, from: data)
        #expect(decoded == original)
    }
}

@Suite("InstrumentMapping Vocal Gender")
struct InstrumentMappingVocalGenderTests {
    @Test func infersGenderFromLegacyVoiceID() {
        let mapping = InstrumentMapping(
            channelKey: "johnny",
            displayName: "Johnny",
            trackRole: .vocal,
            voiceID: "us1"
        )

        #expect(mapping.inferredVocalGender == .male)
        #expect(mapping.resolvedVocalGender == .male)
    }

    @Test func explicitGenderOverridesLegacyInference() {
        let mapping = InstrumentMapping(
            channelKey: "jane",
            displayName: "Jane",
            trackRole: .vocal,
            vocalGender: .female,
            voiceID: "us1"
        )

        #expect(mapping.inferredVocalGender == .female)
        #expect(mapping.resolvedVocalGender == .female)
    }
}

@Suite("OWP Project Instruments")
struct OWPProjectInstrumentTests {
    @Test func normalizeProjectMappingsStripsSongScope() {
        let scoped = InstrumentMapping(
            channelKey: "song|Songs/1.01.0 - OVERTURE.ows|johnny",
            songPath: "Songs/1.01.0 - OVERTURE.ows",
            displayName: "Johnny",
            trackRole: .vocal,
            sf2Path: "SoundFonts/johnny.sf2"
        )

        let normalized = OWPProjectIO.normalizeProjectInstrumentMappings([
            scoped.channelKey: scoped
        ])

        #expect(normalized.keys.count == 1)
        #expect(normalized["johnny"]?.channelKey == "johnny")
        #expect(normalized["johnny"]?.songPath == nil)
        #expect(normalized["johnny"]?.sf2Path == "SoundFonts/johnny.sf2")
    }

    @Test func resolveSoundFontsHandlesLegacyRelativeFlatPath() throws {
        let fm = FileManager.default
        let tempRoot = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let soundFontsDir = tempRoot.appendingPathComponent("SoundFonts", isDirectory: true)
        try fm.createDirectory(at: soundFontsDir, withIntermediateDirectories: true)

        let embeddedURL = soundFontsDir.appendingPathComponent("johnny.sf2")
        try Data("test".utf8).write(to: embeddedURL)
        defer { try? fm.removeItem(at: tempRoot) }

        var mappings: [String: InstrumentMapping] = [
            "johnny": InstrumentMapping(
                channelKey: "johnny",
                displayName: "Johnny",
                trackRole: .vocal,
                sf2Path: "SoundFonts/johnny.sf2"
            )
        ]

        OWPProjectIO.resolveSoundFonts(mappings: &mappings, in: tempRoot)

        #expect(mappings["johnny"]?.sf2Path == embeddedURL.path)
        #expect(mappings["johnny"]?.soundFont?.sf2RelativePath == "SoundFonts/johnny.sf2")
        #expect(mappings["johnny"]?.soundFont?.resolvedPath == embeddedURL.path)
    }
}
