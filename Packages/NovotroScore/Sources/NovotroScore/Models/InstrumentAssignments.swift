import Foundation

/// SoundFont assignment data — portable across macOS and iPad.
struct SoundFontAssignment: Codable, Hashable, Sendable {
    var sf2RelativePath: String?
    var sf2FileName: String?
    /// Absolute path on disk (transient, not persisted)
    var resolvedPath: String?
    var bankMSB: Int = 0
    var bankLSB: Int = 0
    var program: Int = 0

    enum CodingKeys: String, CodingKey {
        case sf2RelativePath, sf2FileName, bankMSB, bankLSB, program
    }

    static func == (lhs: SoundFontAssignment, rhs: SoundFontAssignment) -> Bool {
        lhs.sf2RelativePath == rhs.sf2RelativePath &&
        lhs.sf2FileName == rhs.sf2FileName &&
        lhs.bankMSB == rhs.bankMSB &&
        lhs.bankLSB == rhs.bankLSB &&
        lhs.program == rhs.program
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(sf2RelativePath)
        hasher.combine(sf2FileName)
        hasher.combine(bankMSB)
        hasher.combine(bankLSB)
        hasher.combine(program)
    }
}

/// Audio Unit assignment data — macOS only, ignored on iPad.
struct AudioUnitAssignment: Codable, Hashable, Sendable {
    var componentType: UInt32
    var componentSubType: UInt32
    var componentManufacturer: UInt32
    var presetData: Data?
}
