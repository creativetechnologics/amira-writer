import Foundation

enum AnimatePage: String, CaseIterable, Identifiable, Codable {
    case script = "Script"
    case characters = "Characters"
    case places = "Places"
    /// Legacy compatibility page; hidden from the visible page switcher.
    case props = "Props"
    case scenes = "Scenes"
    case animate = "Animate"
    case timeline = "Timeline"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .script: "text.viewfinder"
        case .characters: "person.2"
        case .places: "building.2"
        case .props: "shippingbox"
        case .scenes: "film.stack"
        case .animate: "play.rectangle"
        case .timeline: "ruler"
        }
    }

    var isVisibleInNavigation: Bool {
        self != .script && self != .characters && self != .places && self != .props && self != .scenes
    }

    var navigationPage: AnimatePage {
        switch self {
        case .script, .characters, .places, .props, .scenes:
            return .animate
        case .animate, .timeline:
            return self
        }
    }
}
