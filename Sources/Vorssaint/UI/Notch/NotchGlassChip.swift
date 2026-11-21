// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

// MARK: Glass chips

/// Light gathering along a chip's top edge and, faintly, its bottom.
struct NotchGlassHighlight<S: InsettableShape>: View {
    let shape: S
    var strength: Double = 1

    var body: some View {
        shape
            .strokeBorder(LinearGradient(stops: [
                .init(color: .white.opacity(0.42 * strength), location: 0),
                .init(color: .white.opacity(0.06 * strength), location: 0.45),
                .init(color: .white.opacity(0.14 * strength), location: 1)
            ], startPoint: .top, endPoint: .bottom), lineWidth: 0.75)
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
    }
}

struct NotchGlassChip<S: InsettableShape>: ViewModifier {
    let shape: S
    var fill: Double = 0.14

    func body(content: Content) -> some View {
        content
            .background(shape.fill(.white.opacity(fill)))
            .overlay { NotchGlassHighlight(shape: shape) }
    }
}

extension View {
    func notchGlassChip(radius: CGFloat, fill: Double = 0.14) -> some View {
        modifier(NotchGlassChip(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), fill: fill))
    }
}
