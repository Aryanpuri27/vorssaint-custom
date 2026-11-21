// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Combine
import Foundation

struct ClaudeProfileLimitsState: Equatable, Identifiable {
    var profile: ClaudeAccountProfile
    var limits: AgentLimits?
    var plan: String?
    var email: String?
    var checking = false
    var failed = false
    var attempted: Date?
    var id: String { profile.isDefault ? "claude.default" : profile.id }

    func currentLimits(at now: Date) -> AgentLimits? {
        guard var limits else { return nil }
        limits.windows.removeAll { $0.resetsAt.map { $0 <= now } ?? false }
        return limits.windows.isEmpty ? nil : limits
    }
}

/// Every other Claude Code account on this Mac, beside the one chosen in
/// Settings: each has its own config folder (CLAUDE_CONFIG_DIR), its own
/// logs and its own plan limits. Their logs join the usage reading; their
/// limits are asked one account at a time while the AI page shows.
final class ClaudeProfileLimitsService: ObservableObject {
    static let shared = ClaudeProfileLimitsService()

    @Published private(set) var states: [ClaudeProfileLimitsState] = []
    private var timer: Timer?
    private var running: AgentClaudeServer.Request?
    private var waiting: [String] = []
    private var visible = false
    private let queue = DispatchQueue(label: "com.vorssaint.claude-profile-limits", qos: .utility)
    private let home = FileManager.default.homeDirectoryForCurrentUser

    /// The accounts read besides the chosen one: the usual login when another
    /// folder is chosen, and every `~/.claude-*` folder Claude Code set up.
    static func extras(defaults: UserDefaults = .standard,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ClaudeAccountProfile] {
        guard defaults.object(forKey: DefaultsKey.notchAgentsClaudeAllAccounts) as? Bool ?? true else { return [] }
        let selected = ClaudeAccountProfile.selected(in: defaults)
        func path(_ profile: ClaudeAccountProfile) -> String {
            AgentLogRoot.canonical(profile.configurationURL(home: home)).path
        }
        let usual = Set([".claude", ".config/claude"].map { AgentLogRoot.canonical(home.appending(path: $0)).path })
        var seen = Set([path(selected)])
        if selected.isDefault { seen.formUnion(usual) }
        var result: [ClaudeAccountProfile] = selected.isDefault ? [] : [ClaudeAccountProfile()]
        if !selected.isDefault { seen.formUnion(usual) }
        for profile in ClaudeAccountProfile.discover(home: home) where seen.insert(path(profile)).inserted {
            result.append(profile)
        }
        return result
    }

    func synchronize() {
        let wanted = NotchAgentSupport.isEnabled() ? Self.extras(home: home) : []
        if states.map(\.profile) != wanted {
            let previous = states
            states = wanted.map { profile in
                if let kept = previous.first(where: { $0.profile == profile }) { return kept }
                let reading = profile.read(home: home)
                return ClaudeProfileLimitsState(profile: profile, plan: reading.plan?.name, email: reading.identity?.email)
            }
            waiting.removeAll { id in !states.contains { $0.id == id } }
        }
        syncTimer()
        if visible { refresh() }
    }

    func pageDidAppear(preview: Bool = false) {
        if !preview { visible = true }
        synchronize()
    }

    func pageDidDisappear() {
        visible = false
        waiting.removeAll()
        for index in states.indices where states[index].checking && running == nil { states[index].checking = false }
        syncTimer()
    }

    /// Asks the accounts that are due, or `id` at once when the person asks.
    func refresh(id: String? = nil, force: Bool = false, now: Date = Date()) {
        guard visible || force, NotchAgentSupport.isEnabled() else { return }
        for index in states.indices where (id == nil || states[index].id == id) && !states[index].checking {
            if !force, let attempted = states[index].attempted,
               now.timeIntervalSince(attempted) < (states[index].failed ? 600 : 180) { continue }
            states[index].checking = true
            waiting.append(states[index].id)
        }
        startNext()
    }

    private func startNext() {
        guard running == nil, !waiting.isEmpty else { return }
        let id = waiting.removeFirst()
        guard let index = states.firstIndex(where: { $0.id == id }) else { return startNext() }
        let profile = states[index].profile
        states[index].attempted = Date()
        let request = AgentClaudeServer.Request()
        running = request
        let home = self.home
        queue.async { [weak self] in
            let result: Result<AgentClaudeServer.Summary, AgentClaudeServer.Failure>
            if let executable = AgentClaudeServer.executable(home: home, searchPath: ProcessInfo.processInfo.environment["PATH"]) {
                var environment = AgentCodexServer.environment(for: executable, searchPath: nil)
                environment["PATH"] = AgentClaudeServer.searchPath(after: environment["PATH"] ?? "", home: home)
                result = request.run(executable, home: home, environment: environment, profile: profile)
            } else {
                result = .failure(.missing)
            }
            let reading = profile.read(home: home)
            DispatchQueue.main.async {
                guard let self, self.running === request else { return }
                self.running = nil
                if let index = self.states.firstIndex(where: { $0.id == id }) {
                    var state = self.states[index]
                    state.checking = false
                    state.plan = reading.plan?.name ?? state.plan
                    state.email = reading.identity?.email ?? state.email
                    switch result {
                    case .success(let summary): state.limits = summary.limits; state.failed = false
                    case .failure: state.failed = true
                    }
                    self.states[index] = state
                }
                self.startNext()
            }
        }
    }

    private func syncTimer() {
        guard visible, !states.isEmpty else { timer?.invalidate(); timer = nil; return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
