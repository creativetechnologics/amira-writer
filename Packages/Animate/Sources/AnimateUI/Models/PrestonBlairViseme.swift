import Foundation

enum PrestonBlairViseme: Int, Codable, Sendable, CaseIterable {
    case rest = 0
    case ai = 1
    case e = 2
    case o = 3
    case u = 4
    case consonant = 5
    case fv = 6
    case l = 7
    case mbp = 8
    case wq = 9

    var label: String {
        switch self {
        case .rest: "Rest"
        case .ai: "A/I"
        case .e: "E"
        case .o: "O"
        case .u: "U"
        case .consonant: "C/D/G/K"
        case .fv: "F/V"
        case .l: "L"
        case .mbp: "M/B/P"
        case .wq: "W/Q"
        }
    }

    var token: String {
        switch self {
        case .rest: "rest"
        case .ai: "ai"
        case .e: "e"
        case .o: "o"
        case .u: "u"
        case .consonant: "consonant"
        case .fv: "fv"
        case .l: "l"
        case .mbp: "mbp"
        case .wq: "wq"
        }
    }
}
