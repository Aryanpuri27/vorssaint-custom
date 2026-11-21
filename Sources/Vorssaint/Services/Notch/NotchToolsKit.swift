// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import CoreImage
import CoreImage.CIFilterBuiltins
import EventKit
import Foundation

// The toolbox's services: a terminal, GitHub, weather and world clocks,
// reminders, meetings to join, and QR codes. Each runs only while it is
// used or, for GitHub and meetings, on a slow timer.

enum NotchTools {
    /// A command-line tool by name, where Homebrew and the system keep them.
    static func executable(_ name: String) -> URL? {
        let path = (ProcessInfo.processInfo.environment["PATH"] ?? "") + ":/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
        for folder in path.split(separator: ":") {
            let url = URL(fileURLWithPath: String(folder)).appending(path: name)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }
        return nil
    }

    /// Runs a tool to completion off the main thread and returns what it printed.
    static func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 25) async -> (status: Int32, output: String) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                let data = NSMutableData(), lock = NSLock()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    lock.lock(); if data.length < 2 << 20 { data.append(chunk) }; lock.unlock()
                }
                guard (try? process.run()) != nil else { continuation.resume(returning: (-1, "")); return }
                let deadline = Date().addingTimeInterval(timeout)
                while process.isRunning, Date() < deadline { usleep(50_000) }
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                pipe.fileHandleForReading.readabilityHandler = nil
                lock.lock(); data.append(pipe.fileHandleForReading.readDataToEndOfFile()); let text = String(data: data as Data, encoding: .utf8) ?? ""; lock.unlock()
                continuation.resume(returning: (process.terminationStatus, text))
            }
        }
    }
}

// MARK: Terminal

/// A small shell in the notch: each line runs with zsh in the current
/// folder, its output streams in, and `cd` moves the folder. Not a full
/// terminal emulator, so programs that take over the screen won't work.
final class NotchTerminal: ObservableObject {
    static let shared = NotchTerminal()

    struct Line: Identifiable, Equatable {
        enum Kind { case command, output, error, info }
        let id = UUID()
        let kind: Kind
        var text: String
    }

    @Published private(set) var lines: [Line] = [Line(kind: .info, text: "Hoo Notch terminal · runs with zsh · Ctrl-C stops · ↑ for history")]
    @Published private(set) var folder: URL
    @Published private(set) var running = false
    @Published var input = ""
    private(set) var history: [String] = UserDefaults.standard.stringArray(forKey: "notchTerminalHistory") ?? []
    private var historyIndex: Int?
    private var process: Process?
    private var lastCommand = ""
    private var lastOutput = ""

    private init() {
        let saved = UserDefaults.standard.string(forKey: "notchTerminalFolder")
        folder = saved.map { URL(fileURLWithPath: $0) } ?? FileManager.default.homeDirectoryForCurrentUser
    }

    var folderName: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return folder.path == home ? "~" : folder.path.replacingOccurrences(of: home, with: "~")
    }

    func submit() {
        let command = input.trimmingCharacters(in: .whitespaces)
        input = ""
        historyIndex = nil
        guard !command.isEmpty, !running else { return }
        history.removeAll { $0 == command }
        history.append(command)
        history = Array(history.suffix(100))
        UserDefaults.standard.set(history, forKey: "notchTerminalHistory")
        append(.command, command)
        if command == "clear" { lines.removeAll(); return }
        if command == "cd" || command.hasPrefix("cd ") { changeFolder(String(command.dropFirst(2)).trimmingCharacters(in: .whitespaces)); return }
        start(command)
    }

    func recall(older: Bool) {
        guard !history.isEmpty else { return }
        let index = historyIndex.map { older ? max(0, $0 - 1) : min(history.count, $0 + 1) } ?? (older ? history.count - 1 : history.count)
        historyIndex = index
        input = index < history.count ? history[index] : ""
    }

    func interrupt() {
        process?.interrupt()
    }

    func useFolder(_ url: URL) {
        folder = url
        UserDefaults.standard.set(url.path, forKey: "notchTerminalFolder")
        append(.info, "→ " + folderName)
    }

    /// Hands the last command and its output to Claude Code to explain or fix.
    func askClaude() {
        guard !lastCommand.isEmpty else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let profile = ClaudeAccountProfile.discover(home: home).first { !$0.isDefault } ?? ClaudeAccountProfile()
        let prompt = "I ran this in \(folder.path):\n$ \(lastCommand)\n\(String(lastOutput.suffix(6000)))\n\nExplain what happened and how to fix any problem. Don't change files."
        NotchClaudeExtras.shared.run(prompt: prompt, folder: folder.path, profile: profile, allowEdits: false)
        append(.info, "Asked Claude about it. The answer comes back from Hoo.")
    }

    private func changeFolder(_ target: String) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var path = target.isEmpty || target == "~" ? home.path : target
        if path.hasPrefix("~/") { path = home.path + path.dropFirst(1) }
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appending(path: path)
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.standardizedFileURL.path, isDirectory: &directory), directory.boolValue else {
            append(.error, "cd: no such folder: \(target)"); return
        }
        useFolder(url.standardizedFileURL)
    }

    private func start(_ command: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-l", "-c", command]
        process.currentDirectoryURL = folder
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "dumb"; environment["NO_COLOR"] = "1"; environment["CLICOLOR"] = "0"
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        lastCommand = command
        lastOutput = ""
        for (pipe, kind) in [(out, Line.Kind.output), (err, Line.Kind.error)] {
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
                DispatchQueue.main.async { self?.stream(text, kind: kind) }
            }
        }
        process.terminationHandler = { [weak self] finished in
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            DispatchQueue.main.async {
                guard let self else { return }
                self.running = false
                self.process = nil
                if finished.terminationStatus != 0 {
                    self.append(.info, "exit \(finished.terminationStatus)")
                }
            }
        }
        do { try process.run(); self.process = process; running = true }
        catch { append(.error, "Couldn’t run: \(error.localizedDescription)") }
    }

    private func stream(_ text: String, kind: Line.Kind) {
        lastOutput += text
        if lastOutput.count > 20_000 { lastOutput = String(lastOutput.suffix(20_000)) }
        let clean = text.replacingOccurrences(of: "\u{1B}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        for (index, piece) in clean.components(separatedBy: "\n").enumerated() {
            if index == 0, let last = lines.last, last.kind == kind, !lastLineClosed {
                lines[lines.count - 1].text += piece
            } else if !(piece.isEmpty && index > 0 && index == clean.components(separatedBy: "\n").count - 1) {
                lines.append(Line(kind: kind, text: piece))
            }
        }
        lastLineClosed = clean.hasSuffix("\n")
        if lines.count > 1500 { lines.removeFirst(lines.count - 1500) }
    }
    private var lastLineClosed = true

    private func append(_ kind: Line.Kind, _ text: String) {
        lines.append(Line(kind: kind, text: text))
        lastLineClosed = true
    }
}

// MARK: GitHub

/// Your open pull requests and the ones waiting for your review, with
/// their checks, through the GitHub CLI you are signed in to. Checked every
/// five minutes; the companion speaks up when checks pass or fail.
final class NotchGitHub: ObservableObject {
    static let shared = NotchGitHub()

    struct PullRequest: Identifiable, Equatable {
        let id: String
        let number: Int
        let title: String
        let repository: String
        let url: URL?
        let checks: String?
        let review: String?
        let draft: Bool
    }

    @Published private(set) var mine: [PullRequest] = []
    @Published private(set) var reviewing: [PullRequest] = []
    @Published private(set) var loading = false
    @Published private(set) var problem: String?
    @Published private(set) var checked: Date?
    private var timer: Timer?
    private var known: [String: String] = [:]
    private var knownReviews: Set<String>?

    var available: Bool { NotchTools.executable("gh") != nil }

    func start() {
        guard timer == nil, available, UserDefaults.standard.object(forKey: DefaultsKey.notchGitHub) as? Bool ?? true else { return }
        refresh()
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in self?.refresh() }
        timer.tolerance = 30
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        guard let gh = NotchTools.executable("gh"), !loading else { return }
        loading = true
        let query = """
        { viewer { pullRequests(first: 12, states: OPEN, orderBy: {field: UPDATED_AT, direction: DESC}) { nodes { ...pr } } }
          search(query: "is:pr is:open review-requested:@me archived:false", type: ISSUE, first: 12) { nodes { ...pr } } }
        fragment pr on PullRequest { id number title url isDraft reviewDecision repository { nameWithOwner }
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } } }
        """
        Task {
            let result = await NotchTools.run(gh, ["api", "graphql", "-f", "query=" + query])
            await MainActor.run { self.finish(result) }
        }
    }

    private func finish(_ result: (status: Int32, output: String)) {
        loading = false
        checked = Date()
        guard result.status == 0, let data = result.output.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let root = json["data"] as? [String: Any] else {
            problem = result.output.contains("auth") ? "Sign in with `gh auth login`" : "Couldn’t reach GitHub"
            return
        }
        problem = nil
        func parse(_ nodes: Any?) -> [PullRequest] {
            (nodes as? [[String: Any]] ?? []).compactMap { node in
                guard let id = node["id"] as? String, let number = node["number"] as? Int else { return nil }
                let commit = ((node["commits"] as? [String: Any])?["nodes"] as? [[String: Any]])?.first?["commit"] as? [String: Any]
                return PullRequest(id: id, number: number, title: node["title"] as? String ?? "",
                                   repository: (node["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? "",
                                   url: (node["url"] as? String).flatMap(URL.init(string:)),
                                   checks: (commit?["statusCheckRollup"] as? [String: Any])?["state"] as? String,
                                   review: node["reviewDecision"] as? String, draft: node["isDraft"] as? Bool ?? false)
            }
        }
        let newMine = parse(((root["viewer"] as? [String: Any])?["pullRequests"] as? [String: Any])?["nodes"])
        let newReviewing = parse((root["search"] as? [String: Any])?["nodes"])
        // Speak up for changes since the last look, not on the first one.
        if !known.isEmpty {
            for pr in newMine {
                let before = known[pr.id]
                if before == "PENDING", pr.checks == "FAILURE" || pr.checks == "ERROR" {
                    NotchStageController.shared.say("Checks failed on #\(pr.number) \(pr.title.prefix(40))")
                } else if before == "PENDING", pr.checks == "SUCCESS" {
                    NotchStageController.shared.say("Checks passed on #\(pr.number) ✓")
                }
            }
        }
        if let knownReviews, let fresh = newReviewing.first(where: { !knownReviews.contains($0.id) }) {
            NotchStageController.shared.say("Review requested: \(fresh.repository.split(separator: "/").last ?? "")#\(fresh.number)")
        }
        known = Dictionary(uniqueKeysWithValues: newMine.map { ($0.id, $0.checks ?? "") })
        knownReviews = Set(newReviewing.map(\.id))
        mine = newMine
        reviewing = newReviewing
    }
}

// MARK: Weather and clocks

/// The weather where you are, from Open-Meteo (free, no account), and the
/// time in the cities you keep. Only the city's name is sent, to find it.
final class NotchWeather: ObservableObject {
    static let shared = NotchWeather()

    struct Day: Identifiable, Equatable { let id: String; let symbol: String; let high: Double; let low: Double }

    @Published private(set) var city = ""
    @Published private(set) var temperature: Double?
    @Published private(set) var symbol = "cloud.sun.fill"
    @Published private(set) var condition = ""
    @Published private(set) var days: [Day] = []
    @Published private(set) var problem: String?
    private var location: (lat: Double, lon: Double, name: String)?
    private var fetched: Date?

    static var defaultCity: String {
        let zone = TimeZone.current.identifier.split(separator: "/").last.map(String.init) ?? "London"
        return zone == "Calcutta" ? "Kolkata" : zone.replacingOccurrences(of: "_", with: " ")
    }

    var chosenCity: String {
        let saved = UserDefaults.standard.string(forKey: DefaultsKey.notchWeatherCity) ?? ""
        return saved.isEmpty ? Self.defaultCity : saved
    }

    static var clocks: [TimeZone] {
        let saved = UserDefaults.standard.string(forKey: DefaultsKey.notchWorldClocks) ?? "America/New_York,Europe/London,Asia/Tokyo"
        return saved.split(separator: ",").compactMap { TimeZone(identifier: String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { $0.identifier != TimeZone.current.identifier }
    }

    func refresh(force: Bool = false) {
        if !force, let fetched, Date().timeIntervalSince(fetched) < 1800, location?.name == chosenCity { return }
        let name = chosenCity
        Task {
            do {
                if location?.name != name {
                    var geo = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
                    geo.queryItems = [URLQueryItem(name: "name", value: name), URLQueryItem(name: "count", value: "1")]
                    let (data, _) = try await URLSession.shared.data(from: geo.url!)
                    guard let first = ((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]])?.first,
                          let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else {
                        await MainActor.run { self.problem = "Couldn’t find “\(name)”" }; return
                    }
                    location = (lat, lon, name)
                }
                guard let location else { return }
                var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
                url.queryItems = [
                    URLQueryItem(name: "latitude", value: String(location.lat)), URLQueryItem(name: "longitude", value: String(location.lon)),
                    URLQueryItem(name: "current", value: "temperature_2m,weather_code,is_day"),
                    URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min"),
                    URLQueryItem(name: "timezone", value: "auto"), URLQueryItem(name: "forecast_days", value: "5"),
                ]
                let (data, _) = try await URLSession.shared.data(from: url.url!)
                let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
                let current = json["current"] as? [String: Any] ?? [:]
                let daily = json["daily"] as? [String: Any] ?? [:]
                let codes = daily["weather_code"] as? [Int] ?? [], highs = daily["temperature_2m_max"] as? [Double] ?? []
                let lows = daily["temperature_2m_min"] as? [Double] ?? [], dates = daily["time"] as? [String] ?? []
                let day = (current["is_day"] as? Int ?? 1) == 1
                await MainActor.run {
                    self.city = name
                    self.temperature = current["temperature_2m"] as? Double
                    let code = current["weather_code"] as? Int ?? 0
                    self.symbol = Self.symbol(code, day: day)
                    self.condition = Self.words(code)
                    self.days = (0..<min(codes.count, highs.count, lows.count, dates.count)).map {
                        Day(id: dates[$0], symbol: Self.symbol(codes[$0], day: true), high: highs[$0], low: lows[$0])
                    }
                    self.fetched = Date()
                    self.problem = nil
                }
            } catch {
                await MainActor.run { self.problem = "Weather is unavailable right now" }
            }
        }
    }

    static func symbol(_ code: Int, day: Bool) -> String {
        switch code {
        case 0: return day ? "sun.max.fill" : "moon.stars.fill"
        case 1, 2: return day ? "cloud.sun.fill" : "cloud.moon.fill"
        case 3: return "cloud.fill"
        case 45, 48: return "cloud.fog.fill"
        case 51...57: return "cloud.drizzle.fill"
        case 61...67, 80...82: return "cloud.rain.fill"
        case 71...77, 85, 86: return "cloud.snow.fill"
        case 95...99: return "cloud.bolt.rain.fill"
        default: return "cloud.fill"
        }
    }

    static func words(_ code: Int) -> String {
        switch code {
        case 0: return "Clear"
        case 1: return "Mostly clear"
        case 2: return "Partly cloudy"
        case 3: return "Cloudy"
        case 45, 48: return "Fog"
        case 51...57: return "Drizzle"
        case 61...67, 80...82: return "Rain"
        case 71...77, 85, 86: return "Snow"
        case 95...99: return "Thunderstorms"
        default: return ""
        }
    }
}

// MARK: Reminders

/// Today's reminders, overdue ones and those with no date, to tick off.
final class NotchReminders: ObservableObject {
    static let shared = NotchReminders()

    struct Item: Identifiable, Equatable { let id: String; let title: String; let due: Date?; let list: String; let color: NSColor? }

    @Published private(set) var items: [Item] = []
    @Published private(set) var access = EKEventStore.authorizationStatus(for: .reminder)
    private let store = EKEventStore()

    func refresh() {
        access = EKEventStore.authorizationStatus(for: .reminder)
        guard access == .fullAccess else { return }
        let end = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_400)
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: end, calendars: nil)
        let undated = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] dated in
            self?.store.fetchReminders(matching: undated) { all in
                let undatedOnes = (all ?? []).filter { $0.dueDateComponents == nil }
                let list = ((dated ?? []) + undatedOnes).prefix(12).map { reminder in
                    Item(id: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                         due: reminder.dueDateComponents?.date, list: reminder.calendar?.title ?? "",
                         color: reminder.calendar?.color)
                }
                DispatchQueue.main.async { self?.items = Array(list) }
            }
        }
    }

    func requestAccess() {
        store.requestFullAccessToReminders { [weak self] _, _ in DispatchQueue.main.async { self?.refresh() } }
    }

    func complete(_ id: String) {
        guard let reminder = store.calendarItem(withIdentifier: id) as? EKReminder else { return }
        reminder.isCompleted = true
        try? store.save(reminder, commit: true)
        items.removeAll { $0.id == id }
        NotchService.shared.reactMascot(.celebrate, patience: 2)
        NotchMoodMeter.shared.note(.taskDone)
    }
}

// MARK: Meetings

/// Two minutes before an event with a call link, the companion offers to join.
final class NotchMeetings {
    static let shared = NotchMeetings()
    private var offered = Set<String>()

    func minute() {
        let now = Date()
        for event in NotchCalendarService.shared.events where !event.allDay {
            guard let link = event.meetingURL, !offered.contains(event.id) else { continue }
            let lead = event.start.timeIntervalSince(now)
            guard lead <= 150, lead > -300 else { continue }
            offered.insert(event.id)
            NotchStageController.shared.offerMeeting(title: event.title, link: link, start: event.start)
        }
    }

    /// A Meet, Zoom, Teams, Webex or FaceTime link in the event, if any.
    static func link(in texts: [String?]) -> URL? {
        let pattern = #"https?://[^\s<>"]*(meet\.google\.com|zoom\.us|teams\.microsoft\.com|teams\.live\.com|webex\.com|facetime\.apple\.com|whereby\.com)[^\s<>"]*"#
        for text in texts.compactMap({ $0 }) {
            if let range = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) {
                return URL(string: String(text[range]))
            }
        }
        return nil
    }
}

// MARK: QR codes

enum NotchQR {
    /// A crisp QR code for `text`.
    static func image(for text: String, size: CGFloat = 180) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = size / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }

    /// Lets you drag over a QR code anywhere on screen and reads it.
    static func scan(completion: @escaping (String?) -> Void) {
        let file = FileManager.default.temporaryDirectory.appending(path: "hoo-qr-\(UUID().uuidString).png")
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            process.arguments = ["-i", "-x", file.path]
            try? process.run(); process.waitUntilExit()
            defer { try? FileManager.default.removeItem(at: file) }
            guard let image = CIImage(contentsOf: file),
                  let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else {
                DispatchQueue.main.async { completion(nil) }; return
            }
            let text = (detector.features(in: image).first as? CIQRCodeFeature)?.messageString
            DispatchQueue.main.async { completion(text) }
        }
    }
}

// MARK: Docker (OrbStack)

/// Containers through the Docker CLI (OrbStack's here), grouped by Compose
/// project, with start, stop, restart, logs and their ports. While Docker
/// runs, the companion speaks up when a container crashes or turns unhealthy.
final class NotchDocker: ObservableObject {
    static let shared = NotchDocker()

    struct Container: Identifiable, Equatable {
        let id: String
        let name: String
        let image: String
        let state: String
        let status: String
        let ports: [Int]
        let project: String?
        var cpu: String?
        var memory: String?
        var running: Bool { state == "running" }
        var unhealthy: Bool { status.contains("unhealthy") }
        var shortName: String {
            guard let project else { return name }
            var short = name.hasPrefix(project + "-") ? String(name.dropFirst(project.count + 1)) : name
            if short.hasSuffix("-1") { short.removeLast(2) }
            return short
        }
    }

    @Published private(set) var containers: [Container] = []
    @Published private(set) var reachable = true
    @Published private(set) var loading = false
    @Published private(set) var busy = Set<String>()
    @Published var logs: (name: String, text: String)?
    private var watcher: Timer?
    private var lastStates: [String: (state: String, unhealthy: Bool)] = [:]

    var docker: URL? { NotchTools.executable("docker") }

    var projects: [(name: String, containers: [Container])] {
        let grouped = Dictionary(grouping: containers) { $0.project ?? "" }
        return grouped.keys.sorted { a, b in
            if a.isEmpty != b.isEmpty { return !a.isEmpty }
            let runningA = grouped[a]!.contains(where: \.running), runningB = grouped[b]!.contains(where: \.running)
            return runningA != runningB ? runningA : a < b
        }.map { ($0, grouped[$0]!.sorted { $0.running != $1.running ? $0.running : $0.name < $1.name }) }
    }

    /// Watches quietly once a minute for crashes and health changes.
    func startWatching() {
        guard watcher == nil, docker != nil, UserDefaults.standard.object(forKey: DefaultsKey.notchDocker) as? Bool ?? true else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.refresh(stats: false) }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        watcher = timer
        refresh(stats: false)
    }

    func refresh(stats: Bool = true) {
        guard let docker, !loading else { return }
        loading = true
        Task {
            let list = await NotchTools.run(docker, ["ps", "-a", "--format", "{{json .}}"], timeout: 10)
            var usage: [String: (String, String)] = [:]
            if stats, list.status == 0 {
                let result = await NotchTools.run(docker, ["stats", "--no-stream", "--format", "{{json .}}"], timeout: 12)
                for line in result.output.split(separator: "\n") {
                    guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let name = json["Name"] as? String else { continue }
                    let memory = (json["MemUsage"] as? String)?.components(separatedBy: " / ").first ?? ""
                    usage[name] = (json["CPUPerc"] as? String ?? "", memory)
                }
            }
            let gathered = usage
            await MainActor.run { self.finish(list, usage: gathered) }
        }
    }

    private func finish(_ list: (status: Int32, output: String), usage: [String: (String, String)]) {
        loading = false
        reachable = list.status == 0
        guard reachable else { containers = []; return }
        let parsed: [Container] = list.output.split(separator: "\n").compactMap { line in
            guard let json = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = json["ID"] as? String, let name = json["Names"] as? String else { return nil }
            let labels = json["Labels"] as? String ?? ""
            let project = labels.split(separator: ",").first { $0.hasPrefix("com.docker.compose.project=") }
                .map { String($0.dropFirst("com.docker.compose.project=".count)) }
            let ports = Self.hostPorts(json["Ports"] as? String ?? "")
            return Container(id: id, name: name, image: json["Image"] as? String ?? "", state: json["State"] as? String ?? "",
                             status: json["Status"] as? String ?? "", ports: ports, project: project,
                             cpu: usage[name]?.0, memory: usage[name]?.1)
        }
        // Speak up for what changed on its own: a crash or a turn for the worse.
        if !lastStates.isEmpty {
            for container in parsed {
                guard let before = lastStates[container.id], !busy.contains(container.id) else { continue }
                if before.state == "running", container.state == "exited", !container.status.contains("(0)") {
                    NotchStageController.shared.say("🐳 \(container.shortName) crashed: \(container.status.prefix(24))")
                } else if !before.unhealthy, container.unhealthy {
                    NotchStageController.shared.say("🐳 \(container.shortName) is unhealthy")
                }
            }
        }
        lastStates = Dictionary(uniqueKeysWithValues: parsed.map { ($0.id, ($0.state, $0.unhealthy)) })
        containers = parsed
    }

    /// Host ports a container publishes, from "0.0.0.0:5432->5432/tcp, …".
    static func hostPorts(_ text: String) -> [Int] {
        var ports: [Int] = []
        for part in text.components(separatedBy: ", ") {
            guard let arrow = part.range(of: "->"), let colon = part[..<arrow.lowerBound].lastIndex(of: ":"),
                  let port = Int(part[part.index(after: colon)..<arrow.lowerBound]), !ports.contains(port) else { continue }
            ports.append(port)
        }
        return ports
    }

    func act(_ verb: String, _ container: Container) {
        guard let docker else { return }
        busy.insert(container.id)
        Task {
            let result = await NotchTools.run(docker, [verb, container.id], timeout: 60)
            await MainActor.run {
                self.busy.remove(container.id)
                if result.status != 0 { NotchStageController.shared.say("Couldn’t \(verb) \(container.shortName)") }
                self.refresh()
            }
        }
    }

    /// Starts or stops every container of a Compose project, without its file.
    func project(_ name: String, start: Bool) {
        guard let docker else { return }
        let ids = containers.filter { $0.project == name }.map(\.id)
        busy.formUnion(ids)
        Task {
            _ = await NotchTools.run(docker, [start ? "start" : "stop"] + ids, timeout: 120)
            await MainActor.run {
                self.busy.subtract(ids)
                NotchStageController.shared.say("🐳 \(name) \(start ? "is up" : "stopped")")
                self.refresh()
            }
        }
    }

    func showLogs(_ container: Container) {
        guard let docker else { return }
        logs = (container.shortName, "Loading…")
        Task {
            let result = await NotchTools.run(docker, ["logs", "--tail", "120", "--timestamps", container.id], timeout: 15)
            await MainActor.run { self.logs = (container.shortName, result.output.isEmpty ? "No logs." : result.output) }
        }
    }

    func startOrbStack() {
        guard let orb = NotchTools.executable("orb") else { return }
        Task {
            _ = await NotchTools.run(orb, ["start"], timeout: 60)
            await MainActor.run { self.refresh() }
        }
    }

    func askClaudeAboutLogs() {
        guard let logs else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let profile = ClaudeAccountProfile.discover(home: home).first { !$0.isDefault } ?? ClaudeAccountProfile()
        NotchClaudeExtras.shared.run(prompt: "These are the last logs of the Docker container \(logs.name):\n\(String(logs.text.suffix(6000)))\n\nWhat is going on, and is anything wrong? Be brief.",
                                     folder: home.path, profile: profile, allowEdits: false)
        NotchStageController.shared.say("Asked Claude about \(logs.name)’s logs")
    }
}
