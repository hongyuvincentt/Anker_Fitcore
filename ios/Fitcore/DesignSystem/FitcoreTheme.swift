import SwiftUI

/// Blue/white visual language from mobile_final.html.
enum FitcoreTheme {
    static let ink = Color(hex: 0x0B2340)
    static let muted = Color(hex: 0x6D7D91)
    static let canvas = Color(hex: 0xF3F6FA)
    static let navy = Color(hex: 0x0B3157)
    static let deep = Color(hex: 0x071D3C)
    static let accent = Color(hex: 0x1267D8)
    static let lime = Color(hex: 0xBAF35C)
    static let limeSoft = Color(hex: 0xEEF8D9)
    static let line = Color(hex: 0xE4EAF2)
}

private extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255, opacity: 1)
    }
}
