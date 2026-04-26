import Foundation

// MARK: - Scene Shot Gallery (Beginning / Middle / End)

enum ImagineShotMoment: String, CaseIterable, Identifiable, Codable, Sendable {
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
