import SwiftUI

@available(macOS 26.0, *)
enum MixPalette {
    static let workspaceTop = Color(red: 0.20, green: 0.20, blue: 0.20)
    static let workspaceBase = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let toolbarTop = Color(red: 0.24, green: 0.24, blue: 0.24)
    static let toolbarBottom = Color(red: 0.15, green: 0.15, blue: 0.15)
    static let arrangeBackdrop = Color(red: 0.09, green: 0.09, blue: 0.09)
    static let arrangeBackground = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let trackColumnBackground = Color(red: 0.16, green: 0.16, blue: 0.16)
    static let trackHeaderTop = Color(red: 0.25, green: 0.25, blue: 0.25)
    static let trackHeaderBottom = Color(red: 0.18, green: 0.18, blue: 0.18)
    static let trackSurface = Color(red: 0.20, green: 0.20, blue: 0.20)
    static let trackSelected = Color(red: 0.25, green: 0.25, blue: 0.25)
    static let rulerBackground = Color(red: 0.16, green: 0.16, blue: 0.16)
    static let rulerHighlight = Color.white.opacity(0.08)
    static let laneBase = Color(red: 0.11, green: 0.11, blue: 0.11)
    static let laneAlternate = Color(red: 0.13, green: 0.13, blue: 0.13)
    static let laneSelected = Color(red: 0.17, green: 0.17, blue: 0.17)
    static let mixerTop = Color(red: 0.17, green: 0.17, blue: 0.17)
    static let mixerBottom = Color(red: 0.12, green: 0.12, blue: 0.12)
    static let mixerStrip = Color(red: 0.19, green: 0.19, blue: 0.19)
    static let mixerStripSelected = Color(red: 0.24, green: 0.24, blue: 0.24)
    static let masterStrip = Color(red: 0.22, green: 0.22, blue: 0.22)
    static let displayBackground = Color(red: 0.08, green: 0.08, blue: 0.08)
    static let displayStroke = Color.white.opacity(0.16)
    static let displayText = Color(red: 0.84, green: 0.92, blue: 0.86)
    static let controlFill = Color(red: 0.21, green: 0.21, blue: 0.21)
    static let panelStroke = Color.white.opacity(0.11)
    static let meterRail = Color(red: 0.07, green: 0.07, blue: 0.07)
    static let meterGreen = Color(red: 0.42, green: 0.83, blue: 0.28)
    static let meterYellow = Color(red: 0.93, green: 0.79, blue: 0.27)
    static let meterPeak = Color(red: 0.94, green: 0.34, blue: 0.28)
    static let gridMajor = Color.white.opacity(0.13)
    static let gridMinor = Color.white.opacity(0.07)
    static let gridSubdivision = Color.white.opacity(0.035)
    static let steel = Color(red: 0.70, green: 0.74, blue: 0.80)
    static let lime = Color(red: 0.52, green: 0.78, blue: 0.29)
    static let gold = Color(red: 0.94, green: 0.74, blue: 0.26)
    static let cyan = Color(red: 0.28, green: 0.75, blue: 0.75)
    static let warn = Color(red: 0.86, green: 0.42, blue: 0.38)
    static let recordArmed = Color(red: 0.92, green: 0.29, blue: 0.25)
    static let trackNeutral = Color(red: 0.72, green: 0.72, blue: 0.72)

    static let workspaceGradient = LinearGradient(
        colors: [
            workspaceTop,
            workspaceBase
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: UInt64
        switch cleaned.count {
        case 6:
            r = (value >> 16) & 0xFF
            g = (value >> 8) & 0xFF
            b = value & 0xFF
        case 3:
            // Support shorthand hex (#ABC → #AABBCC)
            r = ((value >> 8) & 0xF) * 17
            g = ((value >> 4) & 0xF) * 17
            b = (value & 0xF) * 17
        default:
            // Neutral gray fallback for malformed hex strings
            r = 180
            g = 180
            b = 180
        }

        self.init(
            red: Double(r) / 255.0,
            green: Double(g) / 255.0,
            blue: Double(b) / 255.0
        )
    }
}
