// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import Foundation
import Network

// Claude Code, live: Claude Code's HTTP hooks post every step of every
// session to a small server on 127.0.0.1, and the notch shows it as it
// happens: what each session is doing, its todo list, when it needs you
// (with Allow and Deny for permission prompts) and when it is done.
// Nothing leaves the Mac, and only requests carrying this Mac's token count.

struct ClaudeLiveSession: Identifiable, Equatable {
    enum Status: Equatable { case working, waiting, idle, done }

    let id: String
    var project: String
    var cwd: String
    var account: String
    var status: Status = .idle
    var step = ""
    var stepSymbol = "sparkles"
    var todosDone = 0
    var todosTotal = 0
    var currentTodo: String?
    var promptStarted: Date?
    var lastEvent = Date()
    var edits = 0
    var commands = 0
    var lastMessage: String?
    /// The app the session runs in, to bring it forward.
    var bundleID: String?
    var termProgram: String?

    var elapsed: TimeInterval? { promptStarted.map { Date().timeIntervalSince($0) } }
}

struct ClaudeLiveQuestion: Equatable {
    let question: String
    let header: String
    let options: [String]
    let multiSelect: Bool
}

struct ClaudeLiveAsk: Identifiable, Equatable {
    let id: String
    let sessionID: String
    let tool: String
    let summary: String
    let project: String
    let account: String
    let created: Date
    /// Whether the session waits for the notch's answer; a notice only otherwise.
    let answerable: Bool
    /// Claude asking you to choose (AskUserQuestion).
    var questions: [ClaudeLiveQuestion] = []
    /// A plan waiting for approval (ExitPlanMode).
    var plan: String?
    /// The tool's input as sent, for answers that hand it back.
    var input: Data = Data()
}

final class ClaudeLiveService: ObservableObject {
    static let shared = ClaudeLiveService()
    static let defaultPort: UInt16 = 47615
    static let hookPath = "/vorssaint-hook"
    /// How long a permission prompt waits for the notch before Claude Code
    /// asks in its own window as usual.
    static let askHold: TimeInterval = 25

    @Published private(set) var sessions: [ClaudeLiveSession] = []
    @Published private(set) var asks: [ClaudeLiveAsk] = []
    @Published private(set) var listening = false
    @Published private(set) var lastSummary: (sessionID: String, text: String)?
    /// Today's tally across every connected account, for the evening recap.
    @Published private(set) var today = (day: "", tasks: 0, edits: 0, commands: 0)

    private var listener: NWListener?
    private var waiting: [String: (Data) -> Void] = [:]
    private var pruneTimer: Timer?

    /// A random secret the hooks send, so another process cannot post as Claude.
    static var token: String {
        if let saved = UserDefaults.standard.string(forKey: DefaultsKey.claudeLiveToken), saved.count >= 32 { return saved }
        let fresh = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        UserDefaults.standard.set(fresh, forKey: DefaultsKey.claudeLiveToken)
        return fresh
    }

    static var answersInNotch: Bool {
        UserDefaults.standard.object(forKey: DefaultsKey.claudeLiveAnswerInNotch) as? Bool ?? true
    }

    var isEnabled: Bool { UserDefaults.standard.object(forKey: DefaultsKey.claudeLiveEnabled) as? Bool ?? true }

    /// What the busiest session is doing right now, for the closed notch.
    var currentStep: (symbol: String, waiting: Bool)? {
        let recent = sessions.filter { $0.status == .working || $0.status == .waiting }
            .filter { Date().timeIntervalSince($0.lastEvent) < 600 }
        if recent.contains(where: { $0.status == .waiting }) { return ("hand.raised.fill", true) }
        guard let busy = recent.max(by: { $0.lastEvent < $1.lastEvent }) else { return nil }
        return (busy.stepSymbol, false)
    }

    // MARK: Server

    func start() {
        guard listener == nil, isEnabled else { return }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: Self.defaultPort)!)
        parameters.allowLocalEndpointReuse = true
        guard let listener = try? NWListener(using: parameters) else { return }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready: self?.listening = true
                case .failed, .cancelled: self?.listening = false; self?.listener = nil
                default: break
                }
            }
        }
        listener.start(queue: .main)
        self.listener = listener
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.prune() }
        RunLoop.main.add(timer, forMode: .common)
        pruneTimer = timer
    }

    func stop() {
        listener?.cancel(); listener = nil
        pruneTimer?.invalidate(); pruneTimer = nil
        for (_, reply) in waiting { reply(Data("{}".utf8)) }
        waiting.removeAll()
        asks.removeAll()
        listening = false
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            if let data { buffer.append(data) }
            guard buffer.count < 4 << 20 else { connection.cancel(); return }
            if let request = HTTPRequest(buffer) {
                self.handle(request, connection: connection)
            } else if complete || error != nil {
                connection.cancel()
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    private struct HTTPRequest {
        let method: String
        let path: String
        let headers: [String: String]
        let body: Data

        init?(_ data: Data) {
            guard let end = data.range(of: Data("\r\n\r\n".utf8)),
                  let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
            var lines = head.components(separatedBy: "\r\n")
            let first = lines.removeFirst().split(separator: " ")
            guard first.count >= 2 else { return nil }
            method = String(first[0]); path = String(first[1])
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            self.headers = headers
            let length = Int(headers["content-length"] ?? "0") ?? 0
            let bodyStart = end.upperBound
            guard data.count - bodyStart >= length else { return nil }
            body = data.subdata(in: bodyStart..<(bodyStart + length))
        }
    }

    private func respond(_ connection: NWConnection, status: String = "200 OK", body: Data = Data("{}".utf8)) {
        var head = "HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        if body.isEmpty { head = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" }
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func handle(_ request: HTTPRequest, connection: NWConnection) {
        guard request.method == "POST", request.path.hasPrefix(Self.hookPath) else {
            respond(connection, status: "404 Not Found", body: Data()); return
        }
        guard request.headers["x-vorssaint-token"] == Self.token else {
            respond(connection, status: "403 Forbidden", body: Data()); return
        }
        guard let json = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
              let event = json["hook_event_name"] as? String else { respond(connection); return }
        let context = Context(configDir: request.headers["x-claude-config"] ?? "",
                              bundleID: request.headers["x-bundle"] ?? "",
                              term: request.headers["x-term"] ?? "")
        if event == "PermissionRequest", let ask = record(permission: json, context: context) {
            // The session waits for the notch's answer, for a while.
            waiting[ask.id] = { [weak self] body in self?.respond(connection, body: body) }
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.askHold) { [weak self] in
                self?.answer(ask.id, allow: nil)
            }
            return
        }
        apply(event: event, json: json, context: context)
        respond(connection)
    }

    // MARK: Events

    private struct Context {
        let configDir: String
        let bundleID: String
        let term: String
    }

    private func accountName(_ configDir: String) -> String {
        let trimmed = configDir.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return "office" }
        let name = URL(fileURLWithPath: trimmed).lastPathComponent
        return name.hasPrefix(".claude-") ? String(name.dropFirst(8)) : name == ".claude" ? "office" : name
    }

    private func session(for json: [String: Any], context: Context) -> Int {
        let id = json["session_id"] as? String ?? "unknown"
        let cwd = json["cwd"] as? String ?? ""
        if let index = sessions.firstIndex(where: { $0.id == id }) {
            sessions[index].lastEvent = Date()
            if !cwd.isEmpty { sessions[index].cwd = cwd; sessions[index].project = URL(fileURLWithPath: cwd).lastPathComponent }
            if !context.bundleID.isEmpty { sessions[index].bundleID = context.bundleID }
            return index
        }
        sessions.append(ClaudeLiveSession(id: id, project: cwd.isEmpty ? "Claude" : URL(fileURLWithPath: cwd).lastPathComponent,
                                          cwd: cwd, account: accountName(context.configDir),
                                          bundleID: context.bundleID.isEmpty ? nil : context.bundleID,
                                          termProgram: context.term.isEmpty ? nil : context.term))
        return sessions.count - 1
    }

    private func apply(event: String, json: [String: Any], context: Context) {
        let index = session(for: json, context: context)
        var session = sessions[index]
        switch event {
        case "SessionStart":
            session.status = .idle
        case "UserPromptSubmit":
            session.status = .working
            session.promptStarted = Date()
            session.edits = 0; session.commands = 0
            session.step = "Thinking"; session.stepSymbol = "brain"
        case "PreToolUse":
            session.status = .working
            if session.promptStarted == nil { session.promptStarted = Date() }
            let (step, symbol) = Self.describe(tool: json["tool_name"] as? String ?? "", input: json["tool_input"] as? [String: Any] ?? [:])
            session.step = step; session.stepSymbol = symbol
            switch json["tool_name"] as? String {
            case "Edit", "Write", "MultiEdit", "NotebookEdit": session.edits += 1
            case "Bash": session.commands += 1
            default: break
            }
            NotchService.shared.claudeStepped(tool: json["tool_name"] as? String ?? "")
        case "PostToolUse":
            if json["tool_name"] as? String == "TodoWrite",
               let todos = (json["tool_input"] as? [String: Any])?["todos"] as? [[String: Any]] {
                session.todosTotal = todos.count
                session.todosDone = todos.filter { $0["status"] as? String == "completed" }.count
                session.currentTodo = (todos.first { $0["status"] as? String == "in_progress" }?["activeForm"] as? String)
                    ?? (todos.first { $0["status"] as? String == "in_progress" }?["content"] as? String)
            }
        case "Notification":
            let type = json["notification_type"] as? String ?? ""
            if ["permission_prompt", "idle_prompt", "elicitation_dialog", "elicitation_url_dialog", "agent_needs_input"].contains(type) {
                let wasWaiting = session.status == .waiting
                session.status = .waiting
                // A permission prompt the notch already shows needs no second word.
                let shown = asks.contains { $0.sessionID == session.id }
                if !shown, !wasWaiting {
                    let message = json["message"] as? String ?? "Claude needs your input"
                    sessions[index] = session
                    present(ClaudeLiveAsk(id: "note." + UUID().uuidString, sessionID: session.id, tool: type == "idle_prompt" ? "Waiting" : "Input",
                                          summary: message, project: session.project, account: session.account,
                                          created: Date(), answerable: false))
                    return
                }
            }
        case "Stop":
            session.status = .done
            session.lastMessage = (json["last_assistant_message"] as? String).map(Self.firstLine)
            let summary = Self.summary(session)
            sessions[index] = session
            let day = Calendar.current.startOfDay(for: Date()).description
            if today.day != day { today = (day, 0, 0, 0) }
            today.tasks += 1; today.edits += session.edits; today.commands += session.commands
            NotchMoodMeter.shared.note(.taskDone)
            lastSummary = (session.id, summary)
            asks.removeAll { $0.sessionID == session.id && !$0.answerable }
            NotchService.shared.claudeFinished(sessionID: session.id, project: session.project, account: session.account,
                                               summary: summary)
            return
        case "SessionEnd":
            sessions.remove(at: index)
            asks.removeAll { $0.sessionID == session.id && !$0.answerable }
            return
        default: break
        }
        sessions[index] = session
    }

    private func record(permission json: [String: Any], context: Context) -> ClaudeLiveAsk? {
        let index = session(for: json, context: context)
        sessions[index].status = .waiting
        let tool = json["tool_name"] as? String ?? "Tool"
        let input = json["tool_input"] as? [String: Any] ?? [:]
        var ask = ClaudeLiveAsk(id: UUID().uuidString, sessionID: sessions[index].id, tool: tool,
                                summary: Self.describe(tool: tool, input: input, long: true).0,
                                project: sessions[index].project, account: sessions[index].account, created: Date(),
                                answerable: Self.answersInNotch)
        ask.input = (try? JSONSerialization.data(withJSONObject: input)) ?? Data()
        if tool == "AskUserQuestion" {
            ask.questions = (input["questions"] as? [[String: Any]] ?? []).prefix(4).map { question in
                ClaudeLiveQuestion(question: question["question"] as? String ?? "",
                                   header: question["header"] as? String ?? "",
                                   options: (question["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String },
                                   multiSelect: question["multiSelect"] as? Bool ?? false)
            }
        }
        if tool == "ExitPlanMode" { ask.plan = input["plan"] as? String ?? "" }
        present(ask)
        return ask.answerable ? ask : nil
    }

    private func present(_ ask: ClaudeLiveAsk) {
        asks.append(ask)
        NotchService.shared.claudeAsks(ask)
    }

    /// Answers Claude's questions with the chosen option labels, by question.
    func answer(_ id: String, choices: [String: String]) {
        guard let ask = asks.first(where: { $0.id == id }) else { return }
        var input = (try? JSONSerialization.jsonObject(with: ask.input)) as? [String: Any] ?? [:]
        input["answers"] = choices
        answer(id, allow: true, updatedInput: input)
    }

    /// Approves a plan, or sends Claude back to keep planning.
    func approvePlan(_ id: String, _ approve: Bool) {
        guard let ask = asks.first(where: { $0.id == id }) else { return }
        let input = (try? JSONSerialization.jsonObject(with: ask.input)) as? [String: Any] ?? [:]
        if approve { answer(id, allow: true, updatedInput: input) }
        else { answer(id, allow: false, message: "Not approved yet: keep planning and refine the plan.") }
    }

    /// Allow, deny, or nil to let Claude Code ask in its own window.
    func answer(_ id: String, allow: Bool?, updatedInput: [String: Any]? = nil, message: String? = nil) {
        if let ask = asks.first(where: { $0.id == id }), let index = sessions.firstIndex(where: { $0.id == ask.sessionID }) {
            sessions[index].status = allow == nil ? .waiting : .working
        }
        asks.removeAll { $0.id == id }
        guard let reply = waiting.removeValue(forKey: id) else { return }
        guard let allow else { reply(Data("{}".utf8)); return }
        var decision: [String: Any] = ["behavior": allow ? "allow" : "deny"]
        if !allow { decision["message"] = message ?? "Denied from the notch." }
        if allow, let updatedInput { decision["updatedInput"] = updatedInput }
        let body = ["hookSpecificOutput": ["hookEventName": "PermissionRequest", "decision": decision]]
        reply((try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8))
        NotchService.shared.claudeAnswered()
    }

    func dismiss(_ id: String) {
        if waiting[id] != nil { answer(id, allow: nil) } else { asks.removeAll { $0.id == id } }
    }

    /// Brings forward the terminal or editor a session runs in.
    func focus(_ sessionID: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        var bundle = session.bundleID
        if bundle == nil {
            switch session.termProgram {
            case "vscode": bundle = "com.microsoft.VSCode"
            case "iTerm.app": bundle = "com.googlecode.iterm2"
            case "Apple_Terminal": bundle = "com.apple.Terminal"
            case "WarpTerminal": bundle = "dev.warp.Warp-Stable"
            case "ghostty": bundle = "com.mitchellh.ghostty"
            default: break
            }
        }
        guard let bundle, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return }
        app.activate()
    }

    private func prune() {
        let now = Date()
        sessions.removeAll { now.timeIntervalSince($0.lastEvent) > ($0.status == .working ? 3600 : 1800) }
    }

    // MARK: Describing

    static func firstLine(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return String(line.prefix(140))
    }

    static func summary(_ session: ClaudeLiveSession) -> String {
        var parts: [String] = []
        if let elapsed = session.elapsed { parts.append(duration(elapsed)) }
        if session.edits > 0 { parts.append("\(session.edits) edit\(session.edits == 1 ? "" : "s")") }
        if session.commands > 0 { parts.append("\(session.commands) command\(session.commands == 1 ? "" : "s")") }
        if session.todosTotal > 0 { parts.append("\(session.todosDone)/\(session.todosTotal) todos") }
        return parts.joined(separator: " · ")
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s / 60 % 60)m"
    }

    static func describe(tool: String, input: [String: Any], long: Bool = false) -> (String, String) {
        func file(_ key: String) -> String {
            let path = input[key] as? String ?? ""
            return long ? path : URL(fileURLWithPath: path).lastPathComponent
        }
        func clip(_ text: String, _ limit: Int) -> String {
            let line = text.replacingOccurrences(of: "\n", with: " ")
            return line.count > limit ? String(line.prefix(limit - 1)) + "…" : line
        }
        switch tool {
        case "Edit", "MultiEdit": return ("Editing " + file("file_path"), "pencil")
        case "Write": return ("Writing " + file("file_path"), "doc.badge.plus")
        case "NotebookEdit": return ("Editing " + file("notebook_path"), "pencil")
        case "Read": return ("Reading " + file("file_path"), "doc.text.magnifyingglass")
        case "Bash":
            let command = input["command"] as? String ?? ""
            let description = input["description"] as? String
            return (long ? clip(command, 220) : clip(description ?? command, 46), "terminal")
        case "Grep": return ("Searching “\(clip(input["pattern"] as? String ?? "", 30))”", "magnifyingglass")
        case "Glob": return ("Finding files", "folder")
        case "WebFetch": return ("Reading " + clip((input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "the web", 40), "globe")
        case "WebSearch": return ("Searching the web", "globe")
        case "TodoWrite": return ("Updating the plan", "checklist")
        case "Task", "Agent": return ("Running an agent", "person.2")
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_").filter { !$0.isEmpty }
                return ("Using " + (parts.dropFirst().first.map(String.init) ?? "a tool"), "puzzlepiece")
            }
            return (tool.isEmpty ? "Working" : "Using " + tool, "hammer")
        }
    }
}

// MARK: Connecting an account

/// Adds, or takes out, the hooks that tell the notch what a Claude Code
/// account is doing. Only the account's own settings.json is touched, and a
/// copy of it is kept the first time.
enum ClaudeLiveInstaller {
    static let events = ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "Notification",
                         "PermissionRequest", "Stop", "SessionEnd"]

    static func settingsURL(for profile: ClaudeAccountProfile, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        profile.configurationURL(home: home).appending(path: "settings.json")
    }

    static func isConnected(_ profile: ClaudeAccountProfile) -> Bool {
        guard let data = try? Data(contentsOf: settingsURL(for: profile)),
              let text = String(data: data, encoding: .utf8) else { return false }
        return text.contains(ClaudeLiveService.hookPath)
    }

    private static func ours(_ entry: Any) -> Bool {
        guard let entry = entry as? [String: Any], let hooks = entry["hooks"] as? [[String: Any]] else { return false }
        return hooks.contains { ($0["url"] as? String)?.contains(ClaudeLiveService.hookPath) == true }
    }

    @discardableResult
    static func connect(_ profile: ClaudeAccountProfile, _ on: Bool) -> Bool {
        let url = settingsURL(for: profile)
        var settings: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let parsed = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
            settings = parsed
            let backup = url.deletingLastPathComponent().appending(path: "settings.json.vorssaint-backup")
            if !FileManager.default.fileExists(atPath: backup.path) { try? data.write(to: backup) }
        }
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        for event in events {
            var entries = (hooks[event] as? [Any] ?? []).filter { !ours($0) }
            if on {
                let hook: [String: Any] = [
                    "type": "http",
                    "url": "http://127.0.0.1:\(ClaudeLiveService.defaultPort)\(ClaudeLiveService.hookPath)",
                    "timeout": event == "PermissionRequest" ? Int(ClaudeLiveService.askHold) + 5 : 3,
                    "headers": ["X-Vorssaint-Token": ClaudeLiveService.token, "X-Claude-Config": "$CLAUDE_CONFIG_DIR",
                                "X-Bundle": "$__CFBundleIdentifier", "X-Term": "$TERM_PROGRAM"],
                    "allowedEnvVars": ["CLAUDE_CONFIG_DIR", "__CFBundleIdentifier", "TERM_PROGRAM"],
                ]
                entries.append(["hooks": [hook]])
            }
            if entries.isEmpty { hooks.removeValue(forKey: event) } else { hooks[event] = entries }
        }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        guard let data = try? JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}
