import Foundation

enum AnimatePage: String, CaseIterable, Identifiable, Codable {
    case script = "Script"
    case characters = "Characters"
    case animate = "Animate"
    case timeline = "Timeline"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .script: "text.viewfinder"
        case .characters: "person.2"
        case .animate: "play.rectangle"
        case .timeline: "ruler"
        }
    }
}
