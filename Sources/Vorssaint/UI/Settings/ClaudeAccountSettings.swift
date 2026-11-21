// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// Chooses an existing login. Claude Code remains responsible for signing in.
struct ClaudeAccountSettings: View {
    @AppStorage(DefaultsKey.notchAgentsClaudeProfile) private var selected = ""
    @AppStorage(DefaultsKey.notchAgentsClaudeAllAccounts) private var allAccounts = true
    @AppStorage(DefaultsKey.claudeLiveEnabled) private var liveEnabled = true
    @AppStorage(DefaultsKey.claudeLiveAnswerInNotch) private var answerInNotch = true
    @ObservedObject private var live = ClaudeLiveService.shared
    @State private var hookRevision = 0
    @ObservedObject private var l10n = L10n.shared
    @ObservedObject private var usage = AgentUsageService.shared
    @State private var entries: [Entry] = []
    @State private var readID = UUID()
    @State private var invalidFolder = false
    private var text: ClaudeAccountStrings { FeatureStrings.claudeAccount(l10n.language) }

    private struct Entry: Identifiable {
        let profile: ClaudeAccountProfile
        var identity: ClaudeAccountProfile.Identity?
        var available = true
        var id: String { profile.id }

        func label(defaultName: String) -> String {
            let name = profile.name(defaultName: defaultName)
            return identity?.email.map { name + " · " + $0 } ?? name
        }
    }

    /// Every Claude Code account on this Mac: the usual login and each ~/.claude-* folder.
    private var liveAccounts: [ClaudeAccountProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let usual = AgentLogRoot.canonical(home.appending(path: ".claude")).path
        return [ClaudeAccountProfile()] + ClaudeAccountProfile.discover(home: home)
            .filter { AgentLogRoot.canonical(URL(fileURLWithPath: $0.directory)).path != usual }
    }

    @ViewBuilder private var liveSection: some View {
        Divider().padding(.vertical, 4)
        Toggle("Claude Code live in the notch", isOn: $liveEnabled)
            .onChange(of: liveEnabled) { liveEnabled ? live.start() : live.stop() }
        Text("Shows what each session is doing, pops open when Claude needs you and when it finishes, and lists every session in the dock.")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        if liveEnabled {
            Label(live.listening ? "Listening on 127.0.0.1:\(ClaudeLiveService.defaultPort)" : "Not listening: the port may be in use",
                  systemImage: live.listening ? "dot.radiowaves.left.and.right" : "exclamationmark.triangle")
                .font(.caption).foregroundStyle(live.listening ? Color.secondary : Color.orange)
            Toggle("Answer permission prompts from the notch", isOn: $answerInNotch)
            Text("A prompt waits up to \(Int(ClaudeLiveService.askHold)) seconds for Allow or Deny in the notch, then Claude Code asks in its own window as usual.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ForEach(liveAccounts) { profile in
                let connected = { _ = hookRevision; return ClaudeLiveInstaller.isConnected(profile) }()
                HStack {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(profile.isDefault ? "Usual login" : profile.name(defaultName: text.defaultAccount))
                        Text(ClaudeLiveInstaller.settingsURL(for: profile).deletingLastPathComponent().path
                                .replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if connected { Label("Connected", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green) }
                    Button(connected ? "Disconnect" : "Connect") {
                        ClaudeLiveInstaller.connect(profile, !connected)
                        hookRevision += 1
                    }
                }
            }
            Text("Connect adds hooks to that account’s settings.json and keeps a copy as settings.json.vorssaint-backup. Sessions started afterwards report to the notch.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Keep the current option in the menu while the disk read is pending.
    private var options: [Entry] {
        var options = entries
        if !options.contains(where: { $0.id.isEmpty }) { options.insert(Entry(profile: ClaudeAccountProfile()), at: 0) }
        if !options.contains(where: { $0.id == selected }) { options.append(Entry(profile: ClaudeAccountProfile(directory: selected))) }
        return options
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SettingsMenuRow(symbol: "person.crop.circle", title: text.title, selection: $selected) {
                ForEach(options) { entry in
                    Text(entry.label(defaultName: text.defaultAccount)).tag(entry.id)
                }
            }
            if let entry = entries.first(where: { $0.id == selected }) {
                if !entry.available {
                    Text(text.invalidFolder).font(.caption).foregroundStyle(.orange)
                } else if entry.identity == nil {
                    Text(text.unknownAccount).font(.caption).foregroundStyle(.secondary)
                }
                if !selected.isEmpty {
                    Text(selected).font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle).help(selected)
                }
            }
            Button(text.chooseFolder) { chooseFolder() }
            Toggle("Also read my other Claude Code accounts", isOn: $allAccounts)
                .onChange(of: allAccounts) { AgentUsageService.shared.syncWithPreferences() }
            liveSection
            if allAccounts {
                let others = ClaudeProfileLimitsService.extras()
                Text(others.isEmpty ? "No other Claude Code config folders found (~/.claude-*)."
                     : "Also reading: " + others.map { $0.name(defaultName: text.defaultAccount) }.joined(separator: ", ")
                        + ". Usage adds up across all of them, and each gets its own limits card.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(text.explanation).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Link(text.signInHelp, destination: URL(string: "https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts")!)
                .font(.caption)
        }
        .onAppear { refresh() }
        .onChange(of: selected) { _, _ in refresh() }
        .onChange(of: usage.claudeAccountIdentity) { _, _ in refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
        .onDisappear { readID = UUID() }
        .alert(text.title, isPresented: $invalidFolder) {
            Button("OK", role: .cancel) {}
        } message: { Text(text.invalidFolder) }
    }

    private func refresh() {
        let id = UUID()
        readID = id
        let selected = selected
        DispatchQueue.global(qos: .utility).async {
            let home = FileManager.default.homeDirectoryForCurrentUser
            let profiles = [ClaudeAccountProfile(), ClaudeAccountProfile(directory: selected)]
                + ClaudeAccountProfile.discover(home: home)
            var seen = Set<String>()
            let found = profiles.filter { seen.insert($0.id).inserted }.map { profile in
                Entry(profile: profile, identity: profile.read(home: home).identity, available: profile.isAvailable(home: home))
            }
            DispatchQueue.main.async {
                guard readID == id else { return }
                entries = found
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        let home = FileManager.default.homeDirectoryForCurrentUser
        panel.directoryURL = home
        guard panel.runModal() == .OK, let folder = panel.url else { return }
        let profile = ClaudeAccountProfile(directory: folder.path)
        // The ordinary ~/.claude folder uses ~/.claude.json. An explicit
        // profile in that folder instead has its own nested .claude.json.
        if folder.standardizedFileURL == home.appending(path: ".claude", directoryHint: .isDirectory).standardizedFileURL,
           !FileManager.default.fileExists(atPath: profile.profileURL(home: home).path) {
            selected = ""
        } else if profile.isAvailable(home: home) {
            selected = profile.directory
        } else {
            invalidFolder = true
        }
    }
}
