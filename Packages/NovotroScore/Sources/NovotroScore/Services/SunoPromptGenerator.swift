import Foundation

enum SunoPromptGenerator {

    /// Load instrument prompt dictionary with three-tier override chain:
    /// OWP override > UserDefaults override > bundled defaults.
    static func loadInstrumentDictionary(owpURL: URL? = nil) -> [String: String] {
        var dict: [String: String] = [:]
        if let url = Bundle.main.url(forResource: "suno-instrument-prompts", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let bundled = try? JSONDecoder().decode([String: String].self, from: data) {
            dict = bundled
        }

        if let userOverrides = UserDefaults.standard.dictionary(forKey: "sunoInstrumentPromptOverrides") as? [String: String] {
            dict.merge(userOverrides) { _, new in new }
        }

        if let owp = owpURL {
            let overridePath = owp.appendingPathComponent("PromptTemplates/instrument-overrides.json")
            if let data = try? Data(contentsOf: overridePath),
               let owpOverrides = try? JSONDecoder().decode([String: String].self, from: data) {
                dict.merge(owpOverrides) { _, new in new }
            }
        }

        return dict
    }

    /// Generate a Suno prompt for a chunk.
    static func generate(
        instrumentNames: [String],
        styleTemplate: String,
        tempo: Double,
        keySignature: String?,
        timeSignature: String?,
        dynamicRange: ClosedRange<Dynamic>?,
        sectionLabel: String?,
        hasPercussion: Bool = false,
        instrumentDictionary: [String: String] = [:]
    ) -> String {
        var parts: [String] = []

        if !styleTemplate.isEmpty {
            parts.append(styleTemplate)
        }

        let descriptions = instrumentNames.compactMap { name -> String? in
            instrumentDictionary[name] ?? name.lowercased()
        }
        if !descriptions.isEmpty {
            parts.append(descriptions.joined(separator: ", "))
        }

        var structureParts: [String] = []
        if let label = sectionLabel {
            structureParts.append("[Instrumental \(label)]")
        } else {
            structureParts.append("[Instrumental]")
        }

        if let range = dynamicRange {
            structureParts.append(dynamicDescriptor(range))
        }

        if let key = keySignature { structureParts.append(key) }

        let tempoName = tempoMarking(tempo)
        structureParts.append("\(tempoName) ~\(Int(tempo))bpm")

        if let ts = timeSignature { structureParts.append("\(ts) time") }

        parts.append(structureParts.joined(separator: ", "))

        var negatives = "no vocals, no electronic elements"
        if !hasPercussion {
            negatives += ", no drums, no percussion"
        }
        parts.append(negatives)

        return parts.joined(separator: ", ")
    }

    // MARK: - Helpers

    enum Dynamic: Int, Comparable, Sendable {
        case pianissimo = 0, piano, mezzoPiano, mezzoForte, forte, fortissimo

        static func < (lhs: Dynamic, rhs: Dynamic) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        static func from(velocity: Int) -> Dynamic {
            switch velocity {
            case 0..<32: return .pianissimo
            case 32..<54: return .piano
            case 54..<75: return .mezzoPiano
            case 75..<96: return .mezzoForte
            case 96..<117: return .forte
            default: return .fortissimo
            }
        }
    }

    private static func dynamicDescriptor(_ range: ClosedRange<Dynamic>) -> String {
        if range.lowerBound == range.upperBound {
            switch range.lowerBound {
            case .pianissimo, .piano: return "gentle and soft"
            case .mezzoPiano, .mezzoForte: return "moderate intensity"
            case .forte, .fortissimo: return "powerful and bold"
            }
        }
        if range.lowerBound.rawValue <= Dynamic.piano.rawValue
            && range.upperBound.rawValue >= Dynamic.forte.rawValue {
            return "builds from soft to powerful"
        }
        return "dynamic"
    }

    private static func tempoMarking(_ bpm: Double) -> String {
        switch bpm {
        case ..<60: return "largo"
        case 60..<72: return "adagio"
        case 72..<86: return "andante"
        case 86..<110: return "moderato"
        case 110..<132: return "allegro"
        case 132..<168: return "vivace"
        default: return "presto"
        }
    }
}
