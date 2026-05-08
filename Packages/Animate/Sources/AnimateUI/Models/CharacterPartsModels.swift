import Foundation

@available(macOS 26.0, *)
struct CharacterPart: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    var characterSlug: String
    var costumeName: String       // Links to a CharacterCostumeReferenceSet name
    var partKind: PartKind
    var emotion: String?          // Only set for front views with emotions
    var imagePath: String         // Relative to part library directory
    var thumbnailPath: String?
    var boundingBox: PartBoundingBox?
    var generatedAt: Date = Date()
    var generationPrompt: String?
}

@available(macOS 26.0, *)
enum PartKind: String, Codable, Sendable, CaseIterable {
    case front = "front"
    case back = "back"
    case leftProfile = "left_profile"
    case rightProfile = "right_profile"
    case quarterLeft = "quarter_left"
    case quarterRight = "quarter_right"

    var displayName: String {
        switch self {
        case .front: "Front"
        case .back: "Back"
        case .leftProfile: "Left Side"
        case .rightProfile: "Right Side"
        case .quarterLeft: "3/4 Left"
        case .quarterRight: "3/4 Right"
        }
    }

    var angleDescription: String {
        switch self {
        case .front: "facing directly toward camera, symmetrical full-body view"
        case .back: "facing directly away from camera, seen from behind"
        case .leftProfile: "seen from the left side in profile"
        case .rightProfile: "seen from the right side in profile"
        case .quarterLeft: "three-quarter view, slightly turned to their left"
        case .quarterRight: "three-quarter view, slightly turned to their right"
        }
    }
}

@available(macOS 26.0, *)
struct PartBoundingBox: Codable, Sendable {
    var minX: Double
    var minY: Double
    var maxX: Double
    var maxY: Double
    var centerX: Double { (minX + maxX) / 2 }
    var centerY: Double { (minY + maxY) / 2 }
    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
}

@available(macOS 26.0, *)
struct CharacterPartsManifest: Codable, Sendable {
    var characterSlug: String
    var parts: [CharacterPart]
    var updatedAt: Date = Date()
}
