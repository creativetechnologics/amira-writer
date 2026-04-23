import Foundation

// MARK: - Scene Shot Gallery (Beginning / Middle / End)

enum ImagineShotMoment: String, CaseIterable, Identifiable, Codable {
    case beginning = "Beginning"
    case middle = "Middle"
    case end = "End"

    var id: String { rawValue }

    var directoryName: String {
        switch self {
        case .beginning: "beginning"
        case .middle: "middle"
        case .end: "end"
        }
    }
}

struct ImagineSceneShotGallery: Identifiable, Codable, Sendable {
    var id: UUID = UUID()
    var shotID: UUID
    var sceneID: UUID
    var beginningImagePaths: [String] = []
    var middleImagePaths: [String] = []
    var endImagePaths: [String] = []
    var beginningPrompt: String = ""
    var middlePrompt: String = ""
    var endPrompt: String = ""
    var selectedBeginningPath: String?
    var selectedMiddlePath: String?
    var selectedEndPath: String?

    func paths(for moment: ImagineShotMoment) -> [String] {
        switch moment {
        case .beginning: beginningImagePaths
        case .middle: middleImagePaths
        case .end: endImagePaths
        }
    }

    func prompt(for moment: ImagineShotMoment) -> String {
        switch moment {
        case .beginning: beginningPrompt
        case .middle: middlePrompt
        case .end: endPrompt
        }
    }

    mutating func setPrompt(_ prompt: String, for moment: ImagineShotMoment) {
        switch moment {
        case .beginning: beginningPrompt = prompt
        case .middle: middlePrompt = prompt
        case .end: endPrompt = prompt
        }
    }

    mutating func setSelectedPath(_ path: String?, for moment: ImagineShotMoment) {
        switch moment {
        case .beginning: selectedBeginningPath = path
        case .middle: selectedMiddlePath = path
        case .end: selectedEndPath = path
        }
    }

    func selectedPath(for moment: ImagineShotMoment) -> String? {
        switch moment {
        case .beginning: selectedBeginningPath
        case .middle: selectedMiddlePath
        case .end: selectedEndPath
        }
    }

    mutating func appendPath(_ path: String, for moment: ImagineShotMoment) {
        switch moment {
        case .beginning: beginningImagePaths.append(path)
        case .middle: middleImagePaths.append(path)
        case .end: endImagePaths.append(path)
        }
    }

    mutating func absorbStoredState(from stored: ImagineSceneShotGallery?) {
        guard let stored else { return }
        beginningPrompt = stored.beginningPrompt
        middlePrompt = stored.middlePrompt
        endPrompt = stored.endPrompt
        selectedBeginningPath = matchedSelection(stored.selectedBeginningPath, candidates: beginningImagePaths)
        selectedMiddlePath = matchedSelection(stored.selectedMiddlePath, candidates: middleImagePaths)
        selectedEndPath = matchedSelection(stored.selectedEndPath, candidates: endImagePaths)
    }

    private func matchedSelection(_ storedPath: String?, candidates: [String]) -> String? {
        guard let storedPath, !storedPath.isEmpty else { return nil }
        if candidates.contains(storedPath) {
            return storedPath
        }

        let normalizedStored = storedPath.replacingOccurrences(of: "\\", with: "/")
        let storedLastPathComponent = URL(fileURLWithPath: storedPath).lastPathComponent

        return candidates.first { candidate in
            let normalizedCandidate = candidate.replacingOccurrences(of: "\\", with: "/")
            return normalizedCandidate == normalizedStored ||
                normalizedCandidate.hasSuffix(normalizedStored) ||
                normalizedStored.hasSuffix(normalizedCandidate) ||
                URL(fileURLWithPath: candidate).lastPathComponent == storedLastPathComponent
        }
    }
}

// MARK: - DrawThings Model Selection

enum ImagineDrawThingsModel: String, CaseIterable, Identifiable, Codable, Sendable {
    case fluxKlein9B = "flux2_klein_9b"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fluxKlein9B: "Flux.2 Klein 9B"
        }
    }

    /// Recommended step count per model.
    var defaultSteps: Int {
        switch self {
        case .fluxKlein9B:
            return 4
        }
    }

    /// CFG / guidance scale per model.
    var defaultCFGScale: Double {
        switch self {
        case .fluxKlein9B:
            return 1.0
        }
    }

    /// Shift parameter (Flux-specific, controls noise schedule).
    var defaultShift: Double {
        switch self {
        case .fluxKlein9B:
            return 3.0
        }
    }

    /// Whether to use resolution-dependent shift (Flux-specific).
    var resolutionDependentShift: Bool {
        switch self {
        case .fluxKlein9B:
            return false
        }
    }

    /// Recommended sampler name for Draw Things.
    var defaultSampler: String {
        switch self {
        case .fluxKlein9B:
            return "DDIM Trailing"
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case Self.fluxKlein9B.rawValue,
             "flux2-klein-base-9b",
             "flux2_klein_4b",
             "z_image_turbo":
            self = .fluxKlein9B
        default:
            self = .fluxKlein9B
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

// MARK: - Bulk Run Configuration

struct ImagineBulkRunConfig: Codable, Sendable {
    var model: ImagineDrawThingsModel = .fluxKlein9B
    /// Number of images DrawThings generates per single API call (1-4).
    var batchSize: Int = 4
    /// Number of times to re-run each prompt (each run produces batchSize images).
    var repeatsPerPrompt: Int = 1
    var autoGeneratePrompts: Bool = true
    var includeBeginning: Bool = true
    var includeMiddle: Bool = true
    var includeEnd: Bool = true
    /// If nil, runs for all scenes. Otherwise, only the listed scene IDs.
    var sceneFilter: [UUID]? = nil

    /// Total images per moment per shot = batchSize × repeatsPerPrompt
    var imagesPerMoment: Int { batchSize * repeatsPerPrompt }
}

// MARK: - Bulk Run State

struct ImagineBulkRunProgress: Sendable {
    var isRunning: Bool = false
    var isCancelled: Bool = false
    var totalImages: Int = 0
    var completedImages: Int = 0
    var currentSceneName: String = ""
    var currentShotIndex: Int = 0
    var currentMoment: ImagineShotMoment = .beginning
    var errorMessage: String?

    var fractionComplete: Double {
        guard totalImages > 0 else { return 0 }
        return Double(completedImages) / Double(totalImages)
    }
}

// MARK: - Universal Image Picker

enum ImagineImageCategory: String, CaseIterable, Identifiable {
    case imagine = "Imagine"
    case characters = "Characters"
    case places = "Places"
    case props = "Props"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .imagine: "sparkles"
        case .characters: "person.2"
        case .places: "map"
        case .props: "shippingbox"
        }
    }
}

struct ImagineImagePickerEntry: Identifiable, Hashable {
    var id: String { path }
    var path: String
    var categoryLabel: String
    var subcategoryLabel: String
}
