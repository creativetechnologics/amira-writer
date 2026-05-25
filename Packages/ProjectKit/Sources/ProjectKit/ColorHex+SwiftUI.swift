import SwiftUI

public extension Color {
    init(hex: String, fallback: String = "#FFFFFF") {
        self = ColorHex.color(from: hex) ?? ColorHex.color(from: fallback) ?? .white
    }
}
