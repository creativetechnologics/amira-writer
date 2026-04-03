import Foundation

enum AnimatePage: String, CaseIterable, Identifiable, Codable {
    case script = "Script"
    case characters = "Characters"
    case places = "Places"
    case props = "Props"
    case animate = "Animate"
    case timeline = "Timeline"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .script: "text.viewfinder"
        case .characters: "person.2"
        case .places: "building.2"
        case .props: "shippingbox"
        case .animate: "play.rectangle"
        case .timeline: "ruler"
        }
    }
}
