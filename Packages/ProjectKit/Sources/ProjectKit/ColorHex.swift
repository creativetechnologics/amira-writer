#if canImport(AppKit)
import AppKit
public typealias PlatformColor = NSColor
#elseif canImport(UIKit)
import UIKit
public typealias PlatformColor = UIColor
#endif
import SwiftUI

public enum ColorHex {
    public static func color(from hex: String?) -> Color? {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6, let intValue = Int(hex, radix: 16) else {
            return nil
        }

        let red = Double((intValue >> 16) & 0xFF) / 255.0
        let green = Double((intValue >> 8) & 0xFF) / 255.0
        let blue = Double(intValue & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }

    public static func platformColor(from hex: String?) -> PlatformColor? {
        guard var hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let intValue = Int(hex, radix: 16) else { return nil }
        let r = CGFloat((intValue >> 16) & 0xFF) / 255.0
        let g = CGFloat((intValue >> 8) & 0xFF) / 255.0
        let b = CGFloat(intValue & 0xFF) / 255.0
        #if canImport(AppKit)
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
        #elseif canImport(UIKit)
        return UIColor(red: r, green: g, blue: b, alpha: 1.0)
        #endif
    }

    #if canImport(AppKit)
    public static func nsColor(from hex: String?) -> NSColor? {
        return platformColor(from: hex)
    }
    #endif

    public static func hex(from color: Color) -> String? {
        #if canImport(AppKit)
        let nsColor = NSColor(color)
        guard let rgb = nsColor.usingColorSpace(.extendedSRGB) else {
            return nil
        }
        let red = Int(round(rgb.redComponent * 255))
        let green = Int(round(rgb.greenComponent * 255))
        let blue = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
        #elseif canImport(UIKit)
        let uiColor = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        uiColor.getRed(&r, green: &g, blue: &b, alpha: &a)
        let red = Int(round(r * 255))
        let green = Int(round(g * 255))
        let blue = Int(round(b * 255))
        return String(format: "#%02X%02X%02X", red, green, blue)
        #endif
    }
}
