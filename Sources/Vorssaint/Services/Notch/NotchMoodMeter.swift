// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

/// How the companion feels, 0 to 100: petting, finished work, breaks and
/// games cheer it up; long stretches without a break wear it down. It drifts
/// back toward content over time, and shows on its resting face.
final class NotchMoodMeter: ObservableObject {
    static let shared = NotchMoodMeter()

    enum Event { case petted, taskDone, breakTaken, longStretch, gamePlayed }

    @Published private(set) var value: Double
    private var lastPet = Date.distantPast

    private init() {
        value = UserDefaults.standard.object(forKey: DefaultsKey.notchMascotMoodValue) as? Double ?? 70
    }

    func note(_ event: Event) {
        let delta: Double
        switch event {
        case .petted:
            // A pat counts once a minute; more is affection, not a mood swing.
            guard Date().timeIntervalSince(lastPet) > 60 else { return }
            lastPet = Date(); delta = 3
        case .taskDone: delta = 6
        case .breakTaken: delta = 8
        case .gamePlayed: delta = 5
        case .longStretch: delta = -12
        }
        set(value + delta)
    }

    /// Called once a minute: a slow return toward content.
    func drift() { set(value + (65 - value) * 0.01) }

    private func set(_ next: Double) {
        let clamped = max(0, min(100, next))
        let before = restingMood
        value = clamped
        UserDefaults.standard.set(clamped, forKey: DefaultsKey.notchMascotMoodValue)
        if restingMood != before { NotchService.shared.objectWillChange.send() }
    }

    /// The face it rests with when the mood is strong either way.
    var restingMood: NotchMascotMood? {
        value >= 85 ? .happy : value <= 25 ? .sleepy : nil
    }

    var label: String {
        switch value {
        case 85...: return "Overjoyed"
        case 65..<85: return "Happy"
        case 45..<65: return "Content"
        case 25..<45: return "A bit tired"
        default: return "Worn out, take a break"
        }
    }
}
