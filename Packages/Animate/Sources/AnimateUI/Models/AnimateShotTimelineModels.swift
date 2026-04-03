import Foundation

@available(macOS 26.0, *)
struct AnimateShotSegment: Identifiable, Sendable {
    enum Provenance: String, Sendable {
        case authored
        case inferred
        case preview

        var label: String {
            switch self {
            case .authored: "Authored"
            case .inferred: "Inferred"
            case .preview: "Preview"
            }
        }
    }

    let id: String
    let title: String
    let detail: String
    let startFrame: Int
    let endFrame: Int
    let containsCurrentFrame: Bool
    let provenance: Provenance

    var durationFrames: Int {
        max(1, endFrame - startFrame + 1)
    }

    var frameRangeLabel: String {
        "\(startFrame)–\(endFrame)"
    }
}

@available(macOS 26.0, *)
struct AnimateProjectSceneSegment: Identifiable, Sendable {
    let id: UUID
    let name: String
    let estimatedFrames: Int
    let characterCount: Int
    let shotCount: Int
    let isSelected: Bool

    var frameLabel: String {
        "\(estimatedFrames)f"
    }
}
