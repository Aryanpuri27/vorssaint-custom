// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import SwiftUI

/// This fork's own options, in one place: the dock, quiet hours, privacy
/// dots, the companion's mood and its games.
struct NotchExtrasSettings: View {
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var mood = NotchMoodMeter.shared
    @AppStorage(DefaultsKey.notchQuickAccessDocked) private var docked = true
    @AppStorage(DefaultsKey.notchQuietHours) private var quiet = false
    @AppStorage(DefaultsKey.notchQuietStart) private var quietStart = 22
    @AppStorage(DefaultsKey.notchQuietEnd) private var quietEnd = 8
    @AppStorage(DefaultsKey.notchPrivacyDots) private var dots = true
    @AppStorage(DefaultsKey.notchMascotGameBest) private var fireflyBest = 0
    @AppStorage(DefaultsKey.notchMascotGameBestReflex) private var reflexBest = 0
    private var text: NotchMascotStrings { FeatureStrings.notchMascot(l10n.language) }

    var body: some View {
        SettingsCard(title: text.extrasCard) {
            SettingsRow(symbol: "dock.rectangle", title: text.dock, caption: text.dockCaption) {
                Toggle(text.dock, isOn: $docked).labelsHidden().toggleStyle(.switch)
                    .onChange(of: docked) { NotchService.shared.syncWithPreferences() }
            }
            SettingsRow(symbol: "moon.zzz", title: text.quietHours, caption: text.quietCaption) {
                HStack(spacing: 6) {
                    if quiet {
                        Picker(text.quietHours, selection: $quietStart) { ForEach(0..<24, id: \.self) { Text(hour($0)).tag($0) } }
                            .labelsHidden().fixedSize()
                        Text("–")
                        Picker(text.quietHours, selection: $quietEnd) { ForEach(0..<24, id: \.self) { Text(hour($0)).tag($0) } }
                            .labelsHidden().fixedSize()
                    }
                    Toggle(text.quietHours, isOn: $quiet).labelsHidden().toggleStyle(.switch)
                }
            }
            SettingsRow(symbol: "circle.fill", title: text.privacyDots, caption: text.privacyCaption) {
                Toggle(text.privacyDots, isOn: $dots).labelsHidden().toggleStyle(.switch)
            }
            SettingsRow(symbol: "heart", title: text.moodMeter, caption: mood.label) {
                ProgressView(value: mood.value, total: 100).frame(width: 120)
            }
            SettingsRow(symbol: "gamecontroller", title: text.games, caption: text.gamesCaption(firefly: fireflyBest, reflex: reflexBest)) {
                HStack {
                    Button(text.game) { NotchStageController.shared.startGame() }
                    Button(text.reflexGame) { NotchStageController.shared.startReflex() }
                }
            }
        }
    }

    private func hour(_ value: Int) -> String {
        var components = DateComponents(); components.hour = value
        return Calendar.current.date(from: components)?.formatted(.dateTime.hour()) ?? "\(value)"
    }
}
