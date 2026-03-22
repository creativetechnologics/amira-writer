import Foundation

// MARK: - Template Model

struct ScoreTemplate: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var tracks: [TemplateTrack]
    var timeSignatureNumerator: Int
    var timeSignatureDenominator: Int
    var tempo: Double

    init(
        id: UUID = UUID(),
        name: String,
        tracks: [TemplateTrack],
        timeSignatureNumerator: Int = 4,
        timeSignatureDenominator: Int = 4,
        tempo: Double = 112
    ) {
        self.id = id
        self.name = name
        self.tracks = tracks
        self.timeSignatureNumerator = timeSignatureNumerator
        self.timeSignatureDenominator = timeSignatureDenominator
        self.tempo = tempo
    }
}

struct TemplateTrack: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var instrumentName: String?
    var colorHex: String?
    var trackIndex: Int
    // Full mix setup fields (Feature 10)
    var sf2Path: String?
    var bankMSB: Int?
    var bankLSB: Int?
    var program: Int?
    var gainDB: Double?
    var pan: Double?
    var instrumentSourceType: InstrumentSourceType?
    var auComponentType: UInt32?
    var auComponentSubType: UInt32?
    var auComponentManufacturer: UInt32?

    init(id: UUID = UUID(), name: String, instrumentName: String? = nil, colorHex: String? = nil, trackIndex: Int) {
        self.id = id
        self.name = name
        self.instrumentName = instrumentName
        self.colorHex = colorHex
        self.trackIndex = trackIndex
    }
}

// MARK: - Template Manager

@available(macOS 26.0, *)
@MainActor
final class TemplateManager {

    static let shared = TemplateManager()

    private let templatesDir: URL = {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Novotro Score")
            .appendingPathComponent("Templates")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    // MARK: - Built-in Templates

    static let fullOrchestra = ScoreTemplate(
        name: "Full Orchestra",
        tracks: [
            TemplateTrack(name: "Amira", instrumentName: "Amira", colorHex: "#EB4045", trackIndex: 0),
            TemplateTrack(name: "Luke", instrumentName: "Luke", colorHex: "#F86B33", trackIndex: 1),
            TemplateTrack(name: "Johnny", instrumentName: "Johnny", colorHex: "#FAAB19", trackIndex: 2),
            TemplateTrack(name: "Flutes", instrumentName: "Flutes", colorHex: "#4DB8FF", trackIndex: 3),
            TemplateTrack(name: "Oboes", instrumentName: "Oboes", colorHex: "#3CA0E6", trackIndex: 4),
            TemplateTrack(name: "Clarinets", instrumentName: "Clarinets", colorHex: "#2E88CC", trackIndex: 5),
            TemplateTrack(name: "Bassoons", instrumentName: "Bassoons", colorHex: "#2070B3", trackIndex: 6),
            TemplateTrack(name: "French Horns", instrumentName: "French Horns", colorHex: "#D4A017", trackIndex: 7),
            TemplateTrack(name: "Trumpets", instrumentName: "Trumpets", colorHex: "#E8B828", trackIndex: 8),
            TemplateTrack(name: "Trombones", instrumentName: "Trombones", colorHex: "#C89015", trackIndex: 9),
            TemplateTrack(name: "Tuba", instrumentName: "Tuba", colorHex: "#B07D10", trackIndex: 10),
            TemplateTrack(name: "Timpani", instrumentName: "Timpani", colorHex: "#8B6914", trackIndex: 11),
            TemplateTrack(name: "Percussion", instrumentName: "Percussion", colorHex: "#9E7B20", trackIndex: 12),
            TemplateTrack(name: "Bells/Celesta", instrumentName: "Bells/Celesta", colorHex: "#B08D2C", trackIndex: 13),
            TemplateTrack(name: "Harp", instrumentName: "Harp", colorHex: "#7DB87D", trackIndex: 14),
            TemplateTrack(name: "Piano", instrumentName: "Piano", colorHex: "#6BA06B", trackIndex: 15),
            TemplateTrack(name: "Organ", instrumentName: "Organ", colorHex: "#5A885A", trackIndex: 16),
            TemplateTrack(name: "Violins I", instrumentName: "Violins I", colorHex: "#43ADF8", trackIndex: 17),
            TemplateTrack(name: "Violins II", instrumentName: "Violins II", colorHex: "#3899E0", trackIndex: 18),
            TemplateTrack(name: "Violas", instrumentName: "Violas", colorHex: "#2D85C8", trackIndex: 19),
            TemplateTrack(name: "Cellos", instrumentName: "Cellos", colorHex: "#2271B0", trackIndex: 20),
            TemplateTrack(name: "Double Basses", instrumentName: "Double Basses", colorHex: "#1A5D98", trackIndex: 21),
        ]
    )

    static let stringQuartet = ScoreTemplate(
        name: "String Quartet",
        tracks: [
            TemplateTrack(name: "Violin I", instrumentName: "Violins I", colorHex: "#43ADF8", trackIndex: 0),
            TemplateTrack(name: "Violin II", instrumentName: "Violins II", colorHex: "#3899E0", trackIndex: 1),
            TemplateTrack(name: "Viola", instrumentName: "Violas", colorHex: "#2D85C8", trackIndex: 2),
            TemplateTrack(name: "Cello", instrumentName: "Cellos", colorHex: "#2271B0", trackIndex: 3),
        ],
        tempo: 120
    )

    static let windQuintet = ScoreTemplate(
        name: "Wind Quintet",
        tracks: [
            TemplateTrack(name: "Flute", instrumentName: "Flutes", colorHex: "#4DB8FF", trackIndex: 0),
            TemplateTrack(name: "Oboe", instrumentName: "Oboes", colorHex: "#3CA0E6", trackIndex: 1),
            TemplateTrack(name: "Clarinet", instrumentName: "Clarinets", colorHex: "#2E88CC", trackIndex: 2),
            TemplateTrack(name: "Bassoon", instrumentName: "Bassoons", colorHex: "#2070B3", trackIndex: 3),
            TemplateTrack(name: "Horn", instrumentName: "French Horns", colorHex: "#D4A017", trackIndex: 4),
        ],
        tempo: 120
    )

    static let brassEnsemble = ScoreTemplate(
        name: "Brass Ensemble",
        tracks: [
            TemplateTrack(name: "Trumpet 1", instrumentName: "Trumpets", colorHex: "#E8B828", trackIndex: 0),
            TemplateTrack(name: "Trumpet 2", instrumentName: "Trumpets", colorHex: "#D4A017", trackIndex: 1),
            TemplateTrack(name: "Horn", instrumentName: "French Horns", colorHex: "#C89015", trackIndex: 2),
            TemplateTrack(name: "Trombone", instrumentName: "Trombones", colorHex: "#B07D10", trackIndex: 3),
            TemplateTrack(name: "Tuba", instrumentName: "Tuba", colorHex: "#8B6914", trackIndex: 4),
        ],
        tempo: 108
    )

    static let builtInTemplates: [ScoreTemplate] = [
        fullOrchestra, stringQuartet, windQuintet, brassEnsemble
    ]

    // MARK: - Save / Load / List

    func saveTemplate(_ template: ScoreTemplate) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(template)
        let fileName = template.name.replacingOccurrences(of: "/", with: "_") + ".json"
        let fileURL = templatesDir.appendingPathComponent(fileName)
        try data.write(to: fileURL, options: .atomic)
        NSLog("[TemplateManager] Saved template: %@", template.name)
    }

    func saveTemplate(name: String, from store: ScoreStore) throws {
        var tracks: [TemplateTrack] = []
        let fromChannelKeys = Set(store.pianoRollChannelKeyByTrackChannel.keys.compactMap {
            Int($0.split(separator: ":").first ?? "")
        })
        let trackIndices = Set(store.pianoRollNotes.map(\.trackIndex))
            .union(Set(store.pianoRollTrackNames.keys))
            .union(fromChannelKeys)
            .sorted()
        for idx in trackIndices {
            let trackName = store.pianoRollTrackNames[idx] ?? "Track \(idx)"
            let channelKey = store.pianoRollChannelKeyByTrackChannel.first(where: { $0.key.hasPrefix("\(idx):") })?.value
            let mapping = channelKey.flatMap { store.instrumentMappings[$0] }
            var track = TemplateTrack(
                name: trackName,
                instrumentName: mapping?.displayName,
                colorHex: mapping?.colorHex,
                trackIndex: idx
            )
            // Capture full mix setup
            if let m = mapping {
                track.sf2Path = m.sf2Path
                track.bankMSB = m.bankMSB
                track.bankLSB = m.bankLSB
                track.program = m.program
                track.gainDB = m.gainDB
                track.instrumentSourceType = m.effectiveSourceType
                track.auComponentType = m.auComponentType
                track.auComponentSubType = m.auComponentSubType
                track.auComponentManufacturer = m.auComponentManufacturer
            }
            if let key = channelKey {
                track.pan = store.channelPan[key]
            }
            tracks.append(track)
        }
        let timeSig = store.pianoRollTimeSignatures.first ?? TimeSignatureEvent(tick: 0, numerator: 4, denominator: 4)
        let template = ScoreTemplate(
            name: name,
            tracks: tracks,
            timeSignatureNumerator: timeSig.numerator,
            timeSignatureDenominator: timeSig.denominator,
            tempo: store.tempoBPM
        )
        try saveTemplate(template)
    }

    func loadTemplate(name: String) -> ScoreTemplate? {
        // Check built-in first
        if let builtIn = Self.builtInTemplates.first(where: { $0.name == name }) {
            return builtIn
        }
        let fileName = name.replacingOccurrences(of: "/", with: "_") + ".json"
        let fileURL = templatesDir.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(ScoreTemplate.self, from: data)
    }

    func listTemplates() -> [ScoreTemplate] {
        var templates = Self.builtInTemplates
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: templatesDir, includingPropertiesForKeys: nil) {
            for file in files where file.pathExtension == "json" {
                if let data = try? Data(contentsOf: file),
                   let template = try? JSONDecoder().decode(ScoreTemplate.self, from: data) {
                    // Don't duplicate built-ins
                    if !templates.contains(where: { $0.name == template.name }) {
                        templates.append(template)
                    }
                }
            }
        }
        return templates
    }

    func deleteTemplate(name: String) -> Bool {
        let fileName = name.replacingOccurrences(of: "/", with: "_") + ".json"
        let fileURL = templatesDir.appendingPathComponent(fileName)
        do {
            try FileManager.default.removeItem(at: fileURL)
            return true
        } catch {
            return false
        }
    }

    func applyTemplate(_ template: ScoreTemplate, to store: ScoreStore) {
        // Clear existing data
        store.pianoRollNotes.removeAll()
        store.pianoRollTrackNames.removeAll()
        store.pianoRollChannelKeyByTrackChannel.removeAll()
        store.instrumentMappings.removeAll()
        store.selectedTrackFilter.removeAll()
        store.mutedTracks.removeAll()
        store.soloedTracks.removeAll()
        store.pianoRollMarkers.removeAll()
        store.chordMarkers.removeAll()
        store.pianoRollAudioClips.removeAll()

        // Set tempo and time signature
        store.tempoBPM = template.tempo
        store.pianoRollTempoEvents = [TempoPoint(tick: 0, bpm: template.tempo)]
        store.pianoRollTimeSignatures = [
            TimeSignatureEvent(tick: 0, numerator: template.timeSignatureNumerator, denominator: template.timeSignatureDenominator)
        ]

        // Create tracks
        for track in template.tracks {
            store.pianoRollTrackNames[track.trackIndex] = track.name

            let channelKey = "track\(track.trackIndex)"
            store.pianoRollChannelKeyByTrackChannel["\(track.trackIndex):0"] = channelKey

            var mapping = InstrumentMapping(
                id: UUID(),
                channelKey: channelKey,
                displayName: track.name,
                bankMSB: track.bankMSB ?? 0,
                bankLSB: track.bankLSB ?? 0,
                program: track.program ?? 0,
                gainDB: track.gainDB ?? 0,
                muted: false
            )
            mapping.colorHex = track.colorHex
            mapping.sf2Path = track.sf2Path
            if let srcType = track.instrumentSourceType {
                mapping.instrumentSourceType = srcType
            }
            mapping.auComponentType = track.auComponentType
            mapping.auComponentSubType = track.auComponentSubType
            mapping.auComponentManufacturer = track.auComponentManufacturer
            store.instrumentMappings[channelKey] = mapping
            if let pan = track.pan {
                store.channelPan[channelKey] = pan
            }
        }

        // Set default song length (16 bars of 4/4)
        let beatsPerMeasure = template.timeSignatureNumerator
        store.pianoRollLengthTicks = beatsPerMeasure * store.ticksPerQuarter * 16

        NSLog("[TemplateManager] Applied template: %@ (%d tracks)", template.name, template.tracks.count)
    }
}
