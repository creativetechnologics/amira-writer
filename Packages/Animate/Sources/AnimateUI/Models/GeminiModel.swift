import Foundation

enum GeminiModel: String, Codable, Sendable, CaseIterable {
    case nanoBanana = "gemini-2.5-flash-image"
    case flash = "gemini-3.1-flash-image-preview"
    case pro = "gemini-3-pro-image-preview"

    var displayName: String {
        switch self {
        case .nanoBanana: "Nano Banana"
        case .flash: "Nano Banana 2"
        case .pro: "Nano Banana Pro"
        }
    }

    var estimatedCostPerImage: Double {
        estimatedCost(for: "1K")
    }

    func estimatedCost(for imageSize: String) -> Double {
        switch self {
        case .nanoBanana:
            0.039
        case .flash:
            switch imageSize {
            case "4K": 0.150
            case "2K": 0.101
            default: 0.067
            }
        case .pro:
            switch imageSize {
            case "4K": 0.240
            default: 0.134
            }
        }
    }

    func estimatedBatchCost(for imageSize: String) -> Double {
        switch self {
        case .nanoBanana:
            0.0195
        case .flash:
            switch imageSize {
            case "4K": 0.076
            case "2K": 0.050
            default: 0.034
            }
        case .pro:
            switch imageSize {
            case "4K": 0.120
            default: 0.067
            }
        }
    }
}
