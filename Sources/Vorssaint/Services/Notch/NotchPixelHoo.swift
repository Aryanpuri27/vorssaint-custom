// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import CoreGraphics
import Foundation

// Hoo, the pixel owlet: a 16 × 16 sprite drawn a frame at a time. The body
// sits in the lower 14 × 12 cells; the four rows above it hold hats.

enum NotchMascotAccessory: String, CaseIterable, Identifiable {
    /// Picks one by what is going on: headphones with music, a beanie late
    /// at night, a party hat on Fridays, a scarf in winter.
    case auto
    case none, headphones, partyHat, beanie, wizard, crown, sunglasses, bowTie, scarf, gradCap

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "Automatic"
        case .none: return "None"
        case .headphones: return "Headphones"
        case .partyHat: return "Party hat"
        case .beanie: return "Beanie"
        case .wizard: return "Wizard hat"
        case .crown: return "Crown"
        case .sunglasses: return "Sunglasses"
        case .bowTie: return "Bow tie"
        case .scarf: return "Scarf"
        case .gradCap: return "Grad cap"
        }
    }

    static func current(in defaults: UserDefaults = .standard) -> NotchMascotAccessory {
        NotchMascotAccessory(rawValue: defaults.string(forKey: DefaultsKey.notchMascotAccessory) ?? "") ?? .auto
    }

    /// What Automatic wears right now.
    static func automatic(musicPlaying: Bool, date: Date = Date(), calendar: Calendar = .current) -> NotchMascotAccessory {
        if musicPlaying { return .headphones }
        let hour = calendar.component(.hour, from: date)
        if hour >= 23 || hour < 6 { return .beanie }
        let month = calendar.component(.month, from: date)
        if month == 12 || month <= 2 { return .scarf }
        if calendar.component(.weekday, from: date) == 6, hour >= 16 { return .partyHat }
        return .none
    }
}

/// A short act Hoo plays on its own while it rests, so it never looks frozen.
enum NotchPixelIdleAct: CaseIterable {
    case still, lookLeft, lookRight, oneEyeBlink, ruffle, hoot, tilt
}

enum NotchPixelHoo {
    static let side = 16
    /// Frames a second. The sprite is redrawn this often while it is on screen.
    static let fps: Double = 8

    /// The owlet, 14 wide, placed one cell in and four down.
    /// a body · h belly · w eye disc · o beak and feet
    static let body = [
        "..a........a..",
        "..aa......aa..",
        "..aaaaaaaaaa..",
        ".awwwaaaawwwa.",
        ".awwwaaaawwwa.",
        ".awwwaooawwwa.",
        ".aaaaaaaaaaaa.",
        ".aahhhhhhhhaa.",
        "..aahhhhhhaa..",
        "...aaaaaaaa...",
    ]
    static let wingsOut = [6: "aaaaaaaaaaaaaa", 7: "aaahhhhhhhhaaa"]
    static let tuftsUp = [0: "..a........a..", 1: "..aa......aa.."]
    static let tuftsFlat = [0: "..............", 1: ".aaa......aaa."]
    static let beakOpen = [6: ".aaaaaooaaaaa."]
    static let origin = (x: 1, y: 4)
    /// The left and right eye, the top of each pupil, in sprite cells.
    static let eyes = [(x: 3, y: 3), (x: 10, y: 3)]

    struct Palette {
        let body: NotchMascotColor
        let belly: NotchMascotColor
        static let ink = NotchMascotColor(red: 0.11, green: 0.10, blue: 0.13)
        static let disc = NotchMascotColor(red: 1, green: 1, blue: 1)
        static let beak = NotchMascotColor(red: 1, green: 0.60, blue: 0.24)
        static let pink = NotchMascotColor(red: 1, green: 0.35, blue: 0.52)
        static let blush = NotchMascotColor(red: 1, green: 0.56, blue: 0.67)
        static let gold = NotchMascotColor(red: 1, green: 0.85, blue: 0.31)
        static let red = NotchMascotColor(red: 1, green: 0.36, blue: 0.40)
        static let darkRed = NotchMascotColor(red: 0.78, green: 0.20, blue: 0.27)
        static let dark = NotchMascotColor(red: 0.17, green: 0.16, blue: 0.20)
        static let purple = NotchMascotColor(red: 0.45, green: 0.36, blue: 0.95)
        static let teal = NotchMascotColor(red: 0.30, green: 0.80, blue: 0.75)
        static let zzz = NotchMascotColor(red: 0.79, green: 0.72, blue: 1)
        static let grey = NotchMascotColor(red: 0.61, green: 0.60, blue: 0.65)

        init(_ palette: NotchMascotPalette) {
            body = palette.shade
            belly = palette.light
        }
    }

    struct State {
        var mood: NotchMascotMood = .idle
        var frame = 0
        var accessory: NotchMascotAccessory = .none
        var palette: NotchMascotPalette = .lilac
        /// Where the pointer pulls the eyes, -1…1 on each axis.
        var gaze = CGPoint.zero
        /// Walking: the feet step every frame.
        var walking = false
    }

    /// The act playing at `frame`: one every eight seconds or so, each about
    /// a second and a half long, chosen by the frame so it needs no state.
    static func idleAct(at frame: Int) -> NotchPixelIdleAct {
        let slot = frame / 64, phase = frame % 64
        guard phase >= 48 else { return .still }
        let acts: [NotchPixelIdleAct] = [.lookLeft, .oneEyeBlink, .ruffle, .lookRight, .hoot, .tilt]
        return acts[(slot * 5 + 3) % acts.count]
    }

    /// The whole picture for one frame, row by row from the top.
    static func pixels(_ state: State) -> [[NotchMascotColor?]] {
        let pal = Palette(state.palette)
        let f = state.frame
        var grid = Array(repeating: [NotchMascotColor?](repeating: nil, count: side), count: side)
        let mood = state.mood
        let act: NotchPixelIdleAct = mood == .idle && !state.walking ? idleAct(at: f) : .still
        let flapping = mood == .happy || mood == .love || (act == .ruffle && f % 2 == 0)
            || (mood == .determined && f % 4 < 2)
        var rows = body
        if flapping, f % 2 == 0 { for (k, v) in wingsOut { rows[k] = v } }
        if mood == .surprised || mood == .alert { for (k, v) in tuftsUp { rows[k] = v } }
        if mood == .sleepy { for (k, v) in tuftsFlat { rows[k] = v } }
        if act == .hoot, f % 4 < 2 { for (k, v) in beakOpen { rows[k] = v } }
        // A sleepy owl settles a cell lower; a tilting one leans a cell over.
        let sink = mood == .sleepy ? 1 : 0
        let lean = act == .tilt ? (f % 16 < 8 ? 1 : 0) : 0

        func put(_ x: Int, _ y: Int, _ color: NotchMascotColor?) {
            guard let color, (0..<side).contains(x), (0..<side).contains(y) else { return }
            grid[y][x] = color
        }
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                let color: NotchMascotColor?
                switch ch {
                case "a": color = pal.body
                case "h": color = pal.belly
                case "w": color = Palette.disc
                case "o": color = Palette.beak
                default: color = nil
                }
                // The head leans; the body below it stays.
                put(x + origin.x + (y <= 5 ? lean : 0), y + origin.y + sink, color)
            }
        }
        // Feet: they step while walking or busy, and tuck in while asleep.
        if mood != .sleepy {
            let stepping = state.walking || mood == .determined
            for (k, fx) in [5, 8].enumerated() {
                let lifted = stepping && (f + k) % 2 == 0
                put(fx + origin.x, 10 + origin.y, Palette.beak)
                if !lifted { put(fx + origin.x, 11 + origin.y, Palette.beak) }
            }
        }

        // Eyes.
        let gx = state.gaze.x > 0.35 ? 1 : state.gaze.x < -0.35 ? -1 : 0
        let gy = state.gaze.y > 0.45 ? 1 : 0
        for (k, eye) in eyes.enumerated() {
            let ex = eye.x + origin.x + lean, ey = eye.y + origin.y + sink
            let right = k == 1
            var shape = mood
            if mood == .wink { shape = right ? .happy : .idle }
            if mood == .confused { shape = right ? .alert : .idle }
            let blink = (shape == .idle || shape == .determined) && (f % 37 == 0
                || (act == .oneEyeBlink && right && f % 64 < 54))
            var dx = gx
            if act == .lookLeft || (mood == .searching && f % 16 < 8) { dx = -1 }
            if act == .lookRight || (mood == .searching && f % 16 >= 8) { dx = 1 }
            if mood == .thinking { dx = 1 }
            switch shape {
            case _ where blink:
                put(ex - 1, ey + 1, Palette.ink); put(ex, ey + 1, Palette.ink); put(ex + 1, ey + 1, Palette.ink)
            case .happy:
                put(ex - 1, ey + 1, Palette.ink); put(ex, ey, Palette.ink); put(ex + 1, ey + 1, Palette.ink)
            case .love:
                put(ex - 1, ey, Palette.pink); put(ex + 1, ey, Palette.pink)
                put(ex - 1, ey + 1, Palette.pink); put(ex, ey + 1, Palette.pink); put(ex + 1, ey + 1, Palette.pink)
                put(ex, ey + 2, Palette.pink)
            case .sleepy:
                put(ex - 1, ey + 1, Palette.ink); put(ex, ey + 1, Palette.ink); put(ex + 1, ey + 1, Palette.ink)
            case .surprised, .alert:
                put(ex, ey, Palette.ink); put(ex + (right ? 1 : -1), ey, Palette.ink)
                put(ex, ey + 1, Palette.ink); put(ex + (right ? 1 : -1), ey + 1, Palette.ink)
            case .determined:
                put(ex + dx, ey + 1, Palette.ink); put(ex + dx + (right ? -1 : 1), ey, Palette.ink)
            case .thinking:
                put(ex + 1, ey - 0, Palette.ink); put(ex + 1, ey + 1, Palette.ink)
            default:
                put(ex + dx, ey + gy, Palette.ink); put(ex + dx, ey + 1 + gy, Palette.ink)
            }
        }
        if mood == .love || mood == .happy {
            put(2 + origin.x, 6 + origin.y + sink, Palette.blush)
            put(11 + origin.x, 6 + origin.y + sink, Palette.blush)
        }

        drawAccessory(resolvedAccessory(state), into: put, lean: lean, sink: sink, frame: f)

        // Little marks above its head.
        switch mood {
        case .sleepy:
            let y = 2 - (f / 3) % 3
            for x in 12...14 { put(x, y, Palette.zzz); put(x, y + 2, Palette.zzz) }
            put(13, y + 1, Palette.zzz)
        case .determined, .thinking:
            for dot in 0..<min(3, f % 4 + 1) { put(11 + dot * 2 - 1, 1, Palette.grey) }
        case .surprised, .alert:
            put(14, 0, Palette.gold); put(14, 1, Palette.gold); put(14, 3, Palette.gold)
        case .confused:
            put(13, 0, Palette.gold); put(14, 0, Palette.gold); put(14, 1, Palette.gold); put(13, 2, Palette.gold); put(13, 4, Palette.gold)
        case .love:
            let y = 2 - (f / 2) % 3
            put(13, y, Palette.pink); put(15, y, Palette.pink); put(14, y + 1, Palette.pink)
        default: break
        }
        return grid
    }

    static func resolvedAccessory(_ state: State) -> NotchMascotAccessory { state.accessory }

    private static func drawAccessory(_ accessory: NotchMascotAccessory, into put: (Int, Int, NotchMascotColor?) -> Void,
                                      lean: Int, sink: Int, frame f: Int) {
        let p = NotchPixelHoo.Palette.self
        func at(_ x: Int, _ y: Int, _ c: NotchMascotColor) { put(x + lean, y + sink, c) }
        switch accessory {
        case .auto, .none: break
        case .headphones:
            for x in 4...11 { at(x, 4, p.dark) }
            at(3, 5, p.dark); at(12, 5, p.dark); at(2, 6, p.dark); at(13, 6, p.dark)
            for y in 7...9 { at(1, y, p.pink); at(14, y, p.pink) }
            at(2, 7, p.pink); at(13, 7, p.pink)
        case .partyHat:
            at(8, 1, p.gold)
            at(7, 2, p.red); at(8, 2, p.red)
            at(6, 3, p.red); at(7, 3, p.gold); at(8, 3, p.red); at(9, 3, p.gold)
            for x in 5...10 { at(x, 4, x % 2 == 0 ? p.red : p.gold) }
            for x in 5...10 { at(x, 5, p.red) }
        case .beanie:
            at(7, 2, p.teal); at(8, 2, p.teal)
            for x in 5...10 { at(x, 3, p.red) }
            for x in 4...11 { at(x, 4, p.red); at(x, 5, p.red) }
            for x in 4...11 { at(x, 6, x % 2 == 0 ? p.darkRed : p.red) }
        case .wizard:
            at(9, 0, p.purple); at(8, 1, p.purple); at(9, 1, p.purple)
            for x in 7...9 { at(x, 2, p.purple) }
            for x in 6...10 { at(x, 3, p.purple) }
            at(8, 3, f % 8 < 4 ? p.gold : p.purple)
            for x in 5...10 { at(x, 4, p.purple) }
            for x in 3...12 { at(x, 5, p.purple) }
        case .crown:
            at(5, 3, p.gold); at(7, 3, p.gold); at(8, 3, p.gold); at(10, 3, p.gold)
            for x in 5...10 { at(x, 4, p.gold) }
            at(7, 4, p.red); at(8, 4, p.red)
            for x in 5...10 { at(x, 5, p.gold) }
        case .sunglasses:
            for x in 3...12 { at(x, 7, p.dark) }
            for x in 3...5 { at(x, 8, p.dark); at(x + 7, 8, p.dark) }
            at(3, 7, p.disc); at(10, 7, p.disc)
        case .bowTie:
            at(5, 10, p.red); at(6, 10, p.red); at(7, 10, p.darkRed); at(8, 10, p.darkRed); at(9, 10, p.red); at(10, 10, p.red)
            at(5, 11, p.red); at(10, 11, p.red)
        case .scarf:
            for x in 2...13 { at(x, 10, x % 3 == 0 ? p.disc : p.red) }
            at(11, 11, p.red); at(11, 12, p.red); at(12, 12, p.disc)
        case .gradCap:
            for x in 4...11 { at(x, 3, p.dark) }
            for x in 3...12 { at(x, 4, p.dark) }
            for x in 6...9 { at(x, 5, p.dark) }
            at(12, 5, p.gold); at(12, 6, p.gold); at(12, 7, f % 8 < 4 ? p.gold : p.dark)
        }
    }

    /// The sprite as an image, one pixel per cell, to be scaled up with
    /// nearest-neighbour filtering.
    static func image(_ state: State) -> CGImage? {
        let grid = pixels(state)
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        for (y, row) in grid.enumerated() {
            for (x, color) in row.enumerated() {
                guard let color else { continue }
                context.setFillColor(color.cgColor)
                // Core Graphics counts rows from the bottom.
                context.fill(CGRect(x: x, y: side - 1 - y, width: 1, height: 1))
            }
        }
        return context.makeImage()
    }
}
