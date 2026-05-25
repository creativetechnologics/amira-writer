import Foundation

enum TimelineTrackRole: String, Codable, Sendable, CaseIterable {
    case transform
    case visibility
    case facing
    case view
    case pose
    case expression
    case action
    case mouth
    case shadowStyle
    case shadowOpacity
    case drawing
    case camera
    case cameraShot
    case cameraDefaultShot
    case cameraFocus
    case cameraIntent
    case cameraBeat
    case cameraNotes
    case custom

    init(trackSuffix: String) {
        switch trackSuffix.lowercased() {
        case "transform": self = .transform
        case "visibility": self = .visibility
        case "facing": self = .facing
        case "view": self = .view
        case "pose": self = .pose
        case "expression": self = .expression
        case "action": self = .action
        case "mouth": self = .mouth
        case "shadow-style": self = .shadowStyle
        case "shadow-opacity": self = .shadowOpacity
        case "drawing": self = .drawing
        case "camera": self = .camera
        case "shot": self = .cameraShot
        case "default-shot": self = .cameraDefaultShot
        case "focus": self = .cameraFocus
        case "intent": self = .cameraIntent
        case "beat": self = .cameraBeat
        case "notes": self = .cameraNotes
        default: self = .custom
        }
    }

    var trackSuffix: String {
        switch self {
        case .transform: "transform"
        case .visibility: "visibility"
        case .facing: "facing"
        case .view: "view"
        case .pose: "pose"
        case .expression: "expression"
        case .action: "action"
        case .mouth: "mouth"
        case .shadowStyle: "shadow-style"
        case .shadowOpacity: "shadow-opacity"
        case .drawing: "drawing"
        case .camera: "camera"
        case .cameraShot: "shot"
        case .cameraDefaultShot: "default-shot"
        case .cameraFocus: "focus"
        case .cameraIntent: "intent"
        case .cameraBeat: "beat"
        case .cameraNotes: "notes"
        case .custom: "custom"
        }
    }

    var displayLabel: String {
        switch self {
        case .transform: "Transform"
        case .visibility: "Visibility"
        case .facing: "Facing"
        case .view: "View"
        case .pose: "Pose"
        case .expression: "Expression"
        case .action: "Action"
        case .mouth: "Mouth"
        case .shadowStyle: "Shadow Style"
        case .shadowOpacity: "Shadow Opacity"
        case .drawing: "Drawing"
        case .camera: "Camera"
        case .cameraShot: "Shot"
        case .cameraDefaultShot: "Default Shot"
        case .cameraFocus: "Focus"
        case .cameraIntent: "Intent"
        case .cameraBeat: "Beat"
        case .cameraNotes: "Notes"
        case .custom: "Track"
        }
    }
}
