// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import Foundation

/// The evening recap, the spending alert, and Claude Code tasks started from
/// the notch. Ticks once a minute with the stage's scheduler.
final class NotchClaudeExtras: ObservableObject {
    static let shared = NotchClaudeExtras()

    struct Task: Identifiable, Equatable {
        enum Status: Equatable { case running, done, failed }
        let id = UUID()
        let project: String
        let folder: String
        let prompt: String
        let account: String
        var status: Status = .running
        var result = ""
        let started = Date()
    }

    @Published private(set) var tasks: [Task] = []
    private var recapDay: String?
    private var costSamples: [(date: Date, cost: Double)] = []
    private var lastSpikeAlert = Date.distantPast
    private var processes: [UUID: Process] = [:]

    // MARK: Once a minute

    func minute() {
        let now = Date()
        let cost = AgentUsageService.shared.snapshot.usage(.today).total.cost
        costSamples.append((now, cost))
        costSamples.removeAll { now.timeIntervalSince($0.date) > 3600 }
        checkSpike(now: now, cost: cost)
        checkRecap(now: now, cost: cost)
    }

    /// Spending that jumps: at least two dollars in ten minutes, and three
    /// times the hour's usual pace.
    private func checkSpike(now: Date, cost: Double) {
        guard UserDefaults.standard.object(forKey: DefaultsKey.claudeSpikeAlert) as? Bool ?? true,
              now.timeIntervalSince(lastSpikeAlert) > 30 * 60,
              let tenAgo = costSamples.last(where: { now.timeIntervalSince($0.date) >= 600 }),
              let hourAgo = costSamples.first else { return }
        let recent = cost - tenAgo.cost
        let hourly = max(0.01, (cost - hourAgo.cost) / max(1, now.timeIntervalSince(hourAgo.date) / 600))
        guard recent >= 2, recent > hourly * 3 || now.timeIntervalSince(hourAgo.date) < 1200 else { return }
        lastSpikeAlert = now
        NotchStageController.shared.say("Whoa, \(AgentFormat.cost(recent)) of Claude in the last 10 minutes")
    }

    private func checkRecap(now: Date, cost: Double) {
        guard UserDefaults.standard.object(forKey: DefaultsKey.claudeRecap) as? Bool ?? true else { return }
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: now).description
        guard calendar.component(.hour, from: now) >= 18, recapDay != day else { return }
        let tally = ClaudeLiveService.shared.today
        let tasks = tally.day == day ? tally.tasks : 0
        guard tasks > 0 || cost > 0 else { return }
        recapDay = day
        var parts: [String] = []
        if tasks > 0 { parts.append("\(tasks) task\(tasks == 1 ? "" : "s") done") }
        if tally.day == day, tally.edits > 0 { parts.append("\(tally.edits) edits") }
        if cost > 0 { parts.append(AgentFormat.cost(cost)) }
        NotchStageController.shared.say("Today with Claude: " + parts.joined(separator: " · ") + " 🎉")
    }

    // MARK: Tasks from the notch

    /// Recent project folders: the live sessions' and the ones tasks ran in.
    var recentFolders: [String] {
        var seen = Set<String>(), result: [String] = []
        for folder in ClaudeLiveService.shared.sessions.map(\.cwd) + tasks.map(\.folder)
            + (UserDefaults.standard.stringArray(forKey: "claudeTaskFolders") ?? []) where !folder.isEmpty {
            if seen.insert(folder).inserted { result.append(folder) }
        }
        return Array(result.prefix(8))
    }

    /// Runs `claude -p` in `folder` for `profile`, in the background. With
    /// edits allowed, file changes go ahead; anything else that needs
    /// permission asks in the notch when that account is connected.
    func run(prompt: String, folder: String, profile: ClaudeAccountProfile, allowEdits: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let executable = AgentClaudeServer.executable(home: home, searchPath: ProcessInfo.processInfo.environment["PATH"])
        else {
            NotchStageController.shared.say("Claude Code isn’t installed where I can find it")
            return
        }
        var folders = UserDefaults.standard.stringArray(forKey: "claudeTaskFolders") ?? []
        folders.removeAll { $0 == folder }; folders.insert(folder, at: 0)
        UserDefaults.standard.set(Array(folders.prefix(8)), forKey: "claudeTaskFolders")

        let account = profile.isDefault ? "main" : profile.name(defaultName: "main")
        var task = Task(project: URL(fileURLWithPath: folder).lastPathComponent, folder: folder, prompt: prompt, account: account)
        let process = Process()
        process.executableURL = executable
        process.currentDirectoryURL = URL(fileURLWithPath: folder)
        process.arguments = ["-p", prompt, "--permission-mode", allowEdits ? "acceptEdits" : "default"]
        var environment = AgentCodexServer.environment(for: executable, searchPath: nil)
        environment["PATH"] = AgentClaudeServer.searchPath(after: environment["PATH"] ?? "", home: home)
        if !profile.isDefault { environment["CLAUDE_CONFIG_DIR"] = profile.directory } else { environment.removeValue(forKey: "CLAUDE_CONFIG_DIR") }
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        let id = task.id
        // Read as it comes, so a long answer never fills the pipe and stalls Claude.
        let collected = NSMutableData(), lock = NSLock()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            lock.lock(); if collected.length < 1 << 20 { collected.append(chunk) }; lock.unlock()
        }
        process.terminationHandler = { [weak self] finished in
            output.fileHandleForReading.readabilityHandler = nil
            let rest = output.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); collected.append(rest); let data = collected as Data; lock.unlock()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                guard let self, let index = self.tasks.firstIndex(where: { $0.id == id }) else { return }
                self.processes[id] = nil
                self.tasks[index].status = finished.terminationStatus == 0 ? .done : .failed
                self.tasks[index].result = String(text.prefix(4000))
                let line = ClaudeLiveService.firstLine(text)
                NotchStageController.shared.say(finished.terminationStatus == 0
                    ? "\(self.tasks[index].project): \(line.isEmpty ? "done" : line)"
                    : "\(self.tasks[index].project): the task stopped")
            }
        }
        do {
            try process.run()
            processes[id] = process
            task.status = .running
            tasks.insert(task, at: 0)
            tasks = Array(tasks.prefix(10))
        } catch {
            NotchStageController.shared.say("Couldn’t start Claude Code")
        }
    }

    func stop(_ id: UUID) {
        processes[id]?.terminate()
    }

    func copyResult(_ id: UUID) {
        guard let task = tasks.first(where: { $0.id == id }) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(task.result, forType: .string)
    }
}
