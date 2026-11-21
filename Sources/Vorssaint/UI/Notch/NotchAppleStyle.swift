// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

// Apple's look inside the notch: every app has its own color, icons sit in
// app-icon squircles with a soft gradient, Control Center toggles are round
// and fill with color when on, and widgets wear colored symbols.

enum NotchApple {
    static let red = Color(red: 1, green: 0.27, blue: 0.23)
    static let orange = Color(red: 1, green: 0.62, blue: 0.04)
    static let yellow = Color(red: 1, green: 0.8, blue: 0.0)
    static let green = Color(red: 0.2, green: 0.84, blue: 0.29)
    static let mint = Color(red: 0.0, green: 0.78, blue: 0.75)
    static let teal = Color(red: 0.19, green: 0.69, blue: 0.78)
    static let cyan = Color(red: 0.39, green: 0.82, blue: 1)
    static let blue = Color(red: 0.04, green: 0.52, blue: 1)
    static let indigo = Color(red: 0.37, green: 0.36, blue: 0.9)
    static let purple = Color(red: 0.75, green: 0.35, blue: 0.95)
    static let pink = Color(red: 1, green: 0.18, blue: 0.33)
    static let brown = Color(red: 0.67, green: 0.52, blue: 0.37)
    static let gray = Color(red: 0.56, green: 0.56, blue: 0.6)
    static let claude = Color(red: 0.85, green: 0.47, blue: 0.34)

    /// The color an SF Symbol belongs to, the way Apple's own apps color it.
    static func color(for symbol: String) -> Color {
        let rules: [(String, Color)] = [
            ("sparkle", claude), ("timer", orange), ("stopwatch", orange), ("hourglass", orange),
            ("calendar", red), ("bell", red), ("record", red),
            ("music", pink), ("headphones", pink), ("play", pink), ("speaker", pink), ("waveform", pink),
            ("mic", orange), ("clipboard", yellow), ("note", yellow), ("pencil", yellow),
            ("viewfinder", purple), ("camera.viewfinder", purple), ("web.camera", green), ("video", green),
            ("camera", gray), ("photo", mint), ("tray", blue), ("folder", blue), ("arrow.down", blue),
            ("doc", blue), ("link", blue), ("network", cyan), ("wifi", blue), ("antenna", blue),
            ("cpu", blue), ("rectangle.connected", purple), ("memorychip", green), ("battery", green),
            ("internaldrive", indigo), ("powerplug", yellow), ("bolt", yellow), ("fan", teal), ("cable", gray),
            ("gauge", green), ("eye", teal), ("cup", brown), ("moon", indigo), ("sun", yellow),
            ("eyedropper", indigo), ("text", teal), ("keyboard", gray), ("lock", gray), ("slider", gray),
            ("gear", gray), ("square.grid", gray), ("command", indigo), ("magnifyingglass", gray),
        ]
        return rules.first { symbol.contains($0.0) }?.1 ?? blue
    }

    static func color(for module: NotchModule) -> Color {
        switch module {
        case .controls: return gray
        case .mixer: return pink
        case .music: return red
        case .clipboard: return yellow
        case .captures: return purple
        case .files: return blue
        case .system: return green
        case .tools: return indigo
        case .calendar: return red
        case .notifications: return red
        case .timer: return orange
        case .camera: return green
        case .downloads: return blue
        case .agents: return claude
        case .watch: return teal
        case .scratchpad: return yellow
        }
    }
}

/// An app icon: a white glyph on a squircle of the app's color, lit from the top.
struct NotchAppIcon: View {
    let symbol: String
    let color: Color
    var size: CGFloat = 40

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
        Image(systemName: symbol)
            .symbolVariant(.fill)
            .font(.system(size: size * 0.46, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                shape.fill(LinearGradient(colors: [color.mix(.white, 0.18), color.mix(.black, 0.12)],
                                          startPoint: .top, endPoint: .bottom))
            }
            .overlay { shape.strokeBorder(.white.opacity(0.22), lineWidth: 0.5) }
            .shadow(color: color.opacity(0.35), radius: size * 0.12, y: size * 0.05)
    }
}

extension Color {
    /// Blends toward `other` by `amount` (0…1), for gentle highlights and shades.
    func mix(_ other: Color, _ amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .white
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .white
        return Color(.sRGB, red: a.redComponent + (b.redComponent - a.redComponent) * amount,
                     green: a.greenComponent + (b.greenComponent - a.greenComponent) * amount,
                     blue: a.blueComponent + (b.blueComponent - a.blueComponent) * amount, opacity: 1)
    }
}
