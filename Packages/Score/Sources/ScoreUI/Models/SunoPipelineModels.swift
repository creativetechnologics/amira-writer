import Foundation

// MARK: - Chunk Planning

enum SunoSplitMode: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case noSplit
    case structural
    case manualSplits
    case evenDuration

    var id: String { rawValue }

    var title: String {
        switch self {
        case .noSplit: return "No Split"
        case .structural: return "Structural"
        case .manualSplits: return "Manual Splits"
        case .evenDuration: return "Even Duration"
        }
    }
}

enum SunoStylePreset: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case orchestraFidelity
    case chamberFidelity
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .orchestraFidelity: return "Orchestra Fidelity"
        case .chamberFidelity: return "Chamber Fidelity"
        case .custom: return "Custom"
        }
    }

    var template: String? {
        switch self {
        case .orchestraFidelity:
            return "orchestra, instrumental, same tempo, same structure, restrained dynamics, same key, same keychanges, same melodies"
        case .chamberFidelity:
            return "chamber music, adagio for strings, lyrical woodwinds, instrumental, same tempo, same structure, restrained dynamics"
        case .custom:
            return nil
        }
    }
}

/// A single chunk to send to Suno for generation.
struct SunoChunkSpec: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var tickStart: Int
    var tickEnd: Int
    var timeStart: Double
    var timeEnd: Double
    var instrumentGroup: [String]
    var groupLabel: String
    var density: ChunkDensity
    var renderedWAVPath: String?
    var generatedPrompt: String
    var takes: [SunoTake] = []
    var selectedTakeIndex: Int?
    var status: SunoChunkStatus = .planned

    var contentHash: String {
        "\(tickStart)-\(tickEnd)-\(instrumentGroup.sorted().joined())"
    }
}

enum ChunkDensity: String, Codable, Sendable {
    case sparse   // 1-3 simultaneous instruments
    case medium   // 4-6
    case dense    // 7+
}

enum SunoChunkStatus: String, Codable, Sendable {
    case planned
    case exporting
    case exported
    case generating
    case downloaded
    case aligning
    case aligned
    case selected
    case failed
}

struct SunoTake: Identifiable, Codable, Hashable, Sendable {
    var id: UUID = UUID()
    var sunoTrackID: String?
    var downloadedFilePath: String?
    var similarityScore: Double?
    var alignedFilePath: String?
    var generatedAt: Date = Date()
}

// MARK: - Chunk Plan

struct SunoChunkPlan: Codable, Sendable {
    var id: UUID = UUID()
    var songID: UUID
    var chunks: [SunoChunkSpec]
    var styleTemplate: String
    var createdAt: Date = Date()
    var config: SunoChunkConfig
}

struct SunoChunkConfig: Codable, Hashable, Sendable {
    var maxChunkDurationSeconds: Double = 120.0
    var minChunkDurationSeconds: Double = 45.0
    var densityThresholdMedium: Int = 4
    var densityThresholdDense: Int = 7
    var takesPerChunk: Int = 3
    var splitByInstrumentGroup: Bool = false
}

// MARK: - Render Session

struct SunoRenderSession: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var plan: SunoChunkPlan
    var qcMode: SunoQCMode = .curated
    var alignmentMode: SunoAlignmentMode = .stretchAudioToMIDI
    var status: SunoSessionStatus = .planning
    var createdAt: Date = Date()
    var extractedTempoMap: [TempoPoint]?
}

enum SunoQCMode: String, Codable, Sendable {
    case auto
    case curated
    case iterative
}

enum SunoAlignmentMode: String, Codable, Sendable {
    case stretchAudioToMIDI
    case adaptMIDIToAudio
}

enum SunoSessionStatus: String, Codable, Sendable {
    case planning
    case exporting
    case generating
    case reviewing
    case assembling
    case complete
    case failed
}
