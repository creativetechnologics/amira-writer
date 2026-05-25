import Foundation

enum EasingCurve: Codable, Sendable {
    case linear
    case stepped
    case easeIn
    case easeOut
    case easeInOut
    case custom(cx1: Float, cy1: Float, cx2: Float, cy2: Float)
}
