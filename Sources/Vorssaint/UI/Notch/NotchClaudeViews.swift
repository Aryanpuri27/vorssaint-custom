// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

// What Claude Code's live hooks look like in the notch: a card when a
// session asks for something or finishes, and a board of every session.

enum NotchClaudeStyle {
    static let accent = Color(red: 0.85, green: 0.47, blue: 0.34)

    static func color(_ status: ClaudeLiveSession.Status) -> Color {
        switch status {
        case .working: return Color(red: 0.45, green: 0.86, blue: 0.62)
        case .waiting: return .orange
        case .idle: return .white.opacity(0.35)
        case .done: return Color(red: 0.49, green: 0.72, blue: 1)
        }
    }
}

struct NotchClaudeBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .padding(.horizontal, 6).frame(height: 16)
            .background(NotchClaudeStyle.accent.opacity(0.28), in: Capsule())
            .foregroundStyle(Color(red: 1, green: 0.78, blue: 0.68))
    }
}

/// The open notice: a permission to grant, a session waiting, or one done.
struct NotchClaudeCardView: View {
    let card: String
    let close: () -> Void
    @ObservedObject private var live = ClaudeLiveService.shared

    var body: some View {
        if card.hasPrefix("ask:") {
            let id = String(card.dropFirst(4))
            if let ask = live.asks.first(where: { $0.id == id }) { askCard(ask) } else { gone }
        } else {
            let sessionID = String(card.dropFirst(5))
            doneCard(live.sessions.first { $0.id == sessionID }, summary: live.lastSummary?.sessionID == sessionID ? live.lastSummary?.text : nil)
        }
    }

    private var gone: some View {
        Label("Answered", systemImage: "checkmark").font(.system(size: 13, weight: .semibold))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func header(symbol: String, title: String, project: String, account: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 13, weight: .bold)).foregroundStyle(NotchClaudeStyle.accent)
            Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            NotchClaudeBadge(text: account)
            Spacer(minLength: 4)
            Text(project).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(1)
        }
    }

    @ViewBuilder private func askCard(_ ask: ClaudeLiveAsk) -> some View {
        if ask.answerable, let plan = ask.plan { planCard(ask, plan: plan) }
        else if ask.answerable, !ask.questions.isEmpty { NotchClaudeQuestionCard(ask: ask, close: close) }
        else { permissionCard(ask) }
    }

    private func planCard(_ ask: ClaudeLiveAsk, plan: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            header(symbol: "list.bullet.clipboard", title: "Claude’s plan", project: ask.project, account: ask.account)
            ScrollView {
                Text(Self.planText(plan))
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.85))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .notchGlassChip(radius: 10, fill: 0.07)
            HStack(spacing: 8) {
                chip("Open", symbol: "arrow.up.forward.app") { live.focus(ask.sessionID); close() }
                Spacer()
                chip("Keep planning", symbol: "arrow.uturn.backward") { live.approvePlan(ask.id, false) }
                chip("Approve", symbol: "checkmark", prominent: true) { live.approvePlan(ask.id, true) }
            }
        }
    }

    /// Markdown headings become bold lines; the rest keeps its inline styling.
    static func planText(_ plan: String) -> AttributedString {
        var result = AttributedString()
        for (index, raw) in plan.components(separatedBy: "\n").enumerated() {
            var line = raw
            var heading = false
            while line.hasPrefix("#") { line.removeFirst(); heading = true }
            line = line.trimmingCharacters(in: .whitespaces).isEmpty ? line : (heading ? line.trimmingCharacters(in: .whitespaces) : line)
            var piece = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                ?? AttributedString(line)
            if heading { piece.font = .system(size: 12.5, weight: .bold) }
            if index > 0 { result += AttributedString("\n") }
            result += piece
        }
        return result
    }

    private func permissionCard(_ ask: ClaudeLiveAsk) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            header(symbol: "hand.raised.fill", title: ask.answerable ? "Claude wants to use \(ask.tool)" : "Claude needs you",
                   project: ask.project, account: ask.account)
            Text(ask.summary)
                .font(.system(size: 12, design: ask.tool == "Bash" ? .monospaced : .default))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .notchGlassChip(radius: 10, fill: 0.07)
            HStack(spacing: 8) {
                chip("Open", symbol: "arrow.up.forward.app") { live.focus(ask.sessionID); close() }
                Spacer()
                if ask.answerable {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(ClaudeLiveService.askHold - context.date.timeIntervalSince(ask.created)))
                        Text("\(left)s").font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.45))
                    }
                    chip("Deny", symbol: "xmark") { live.answer(ask.id, allow: false) }
                    chip("Allow", symbol: "checkmark", prominent: true) { live.answer(ask.id, allow: true) }
                } else {
                    chip("Dismiss", symbol: "xmark") { live.dismiss(ask.id); close() }
                }
            }
        }
    }

    private func doneCard(_ session: ClaudeLiveSession?, summary: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(symbol: "checkmark.circle.fill", title: "Done", project: session?.project ?? "Claude Code",
                   account: session?.account ?? "claude")
            if let summary, !summary.isEmpty {
                Text(summary).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.75))
            }
            if let message = session?.lastMessage {
                Text(message).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
            }
            HStack {
                Spacer()
                if let session { chip("Open", symbol: "arrow.up.forward.app", prominent: true) { live.focus(session.id); close() } }
            }
        }
    }

    private func chip(_ title: String, symbol: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).frame(height: 28)
                .background(prominent ? NotchClaudeStyle.accent.opacity(0.85) : .clear, in: Capsule())
                .modifier(NotchGlassChip(shape: Capsule(), fill: prominent ? 0 : 0.12))
                .contentShape(Capsule())
        }
        .buttonStyle(NotchSquishButtonStyle())
    }
}

/// Every Claude Code session the hooks know about, as rows in the stage.
struct NotchClaudeBoardView: View {
    @ObservedObject private var live = ClaudeLiveService.shared
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "sparkles").foregroundStyle(NotchClaudeStyle.accent)
                Text("Claude sessions").font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22).notchGlassChip(radius: 11)
                }
                .buttonStyle(NotchSquishButtonStyle())
            }
            if live.sessions.isEmpty {
                Text(live.listening ? "No sessions yet. Start Claude Code in a connected account."
                     : "Not listening. Turn on Claude Code live in Settings → AI.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            ForEach(live.sessions.sorted { $0.lastEvent > $1.lastEvent }.prefix(4)) { session in row(session) }
        }
        .padding(.horizontal, 18)
        .foregroundStyle(.white)
    }

    private func row(_ session: ClaudeLiveSession) -> some View {
        HStack(spacing: 10) {
            Circle().fill(NotchClaudeStyle.color(session.status)).frame(width: 8, height: 8)
                .shadow(color: NotchClaudeStyle.color(session.status), radius: session.status == .working ? 4 : 0)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.project).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    NotchClaudeBadge(text: session.account)
                }
                HStack(spacing: 5) {
                    Image(systemName: session.status == .waiting ? "hand.raised" : session.stepSymbol).font(.system(size: 10))
                    Text(session.status == .waiting ? "Waiting for you" : session.status == .done
                         ? (session.lastMessage ?? "Done") : (session.currentTodo ?? session.step))
                        .font(.system(size: 11)).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.62))
                if session.todosTotal > 0 {
                    GeometryReader { proxy in
                        Capsule().fill(.white.opacity(0.15))
                            .overlay(alignment: .leading) {
                                Capsule().fill(NotchClaudeStyle.accent)
                                    .frame(width: proxy.size.width * CGFloat(session.todosDone) / CGFloat(max(1, session.todosTotal)))
                            }
                    }
                    .frame(height: 3)
                }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                if session.todosTotal > 0 {
                    Text("\(session.todosDone)/\(session.todosTotal)").font(.system(size: 10.5, weight: .semibold)).monospacedDigit()
                }
                if let elapsed = session.elapsed, session.status == .working {
                    Text(ClaudeLiveService.duration(elapsed)).font(.system(size: 10.5)).monospacedDigit()
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            Button { live.focus(session.id) } label: {
                Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
                    .frame(width: 26, height: 26).notchGlassChip(radius: 13)
            }
            .buttonStyle(NotchSquishButtonStyle())
            .help("Bring its window forward")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .notchGlassChip(radius: 12, fill: 0.06)
        .contextMenu {
            Button("Bring its window forward") { live.focus(session.id) }
            if !session.cwd.isEmpty {
                Button("Show project in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.cwd)]) }
                if let code = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
                    Button("Open project in VS Code") {
                        NSWorkspace.shared.open([URL(fileURLWithPath: session.cwd)], withApplicationAt: code,
                                                configuration: NSWorkspace.OpenConfiguration())
                    }
                }
                Button("Copy project path") { copy(session.cwd) }
            }
            if let message = session.lastMessage { Button("Copy Claude’s last message") { copy(message) } }
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Claude's multiple-choice questions, one at a time, answered in place.
struct NotchClaudeQuestionCard: View {
    let ask: ClaudeLiveAsk
    let close: () -> Void
    @ObservedObject private var live = ClaudeLiveService.shared
    @State private var page = 0
    @State private var picked: [Int: Set<String>] = [:]

    var body: some View {
        let question = ask.questions[min(page, ask.questions.count - 1)]
        let chosen = picked[page] ?? []
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill").foregroundStyle(NotchClaudeStyle.accent)
                Text(question.header.isEmpty ? "Claude asks" : question.header).font(.system(size: 13, weight: .semibold))
                NotchClaudeBadge(text: ask.account)
                Spacer()
                if ask.questions.count > 1 {
                    Text("\(page + 1)/\(ask.questions.count)").font(.system(size: 11)).monospacedDigit().foregroundStyle(.white.opacity(0.5))
                }
            }
            Text(question.question).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(question.options, id: \.self) { option in
                        let on = chosen.contains(option)
                        Button {
                            var set = chosen
                            if question.multiSelect { if on { set.remove(option) } else { set.insert(option) } } else { set = [option] }
                            picked[page] = set
                            if !question.multiSelect { advance() }
                        } label: {
                            Text(option).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                .padding(.horizontal, 12).frame(height: 28)
                                .background(on ? NotchClaudeStyle.accent.opacity(0.85) : .clear, in: Capsule())
                                .modifier(NotchGlassChip(shape: Capsule(), fill: on ? 0 : 0.12))
                        }
                        .buttonStyle(NotchSquishButtonStyle())
                    }
                }
            }
            HStack {
                Button("Answer in Claude instead") { live.answer(ask.id, allow: nil); live.focus(ask.sessionID); close() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5))
                Spacer()
                if question.multiSelect {
                    Button("Next") { advance() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                        .disabled(chosen.isEmpty)
                }
            }
        }
    }

    private func advance() {
        if page + 1 < ask.questions.count { withAnimation(.smooth(duration: 0.25)) { page += 1 }; return }
        var answers: [String: String] = [:]
        for (index, question) in ask.questions.enumerated() {
            let set = picked[index] ?? []
            answers[question.question] = question.options.filter(set.contains).joined(separator: ", ")
        }
        live.answer(ask.id, choices: answers)
    }
}

/// A Claude Code task started from the notch: where, as whom, and what.
struct NotchClaudeComposeView: View {
    let close: () -> Void
    @ObservedObject private var extras = NotchClaudeExtras.shared
    @State private var prompt = ""
    @State private var folder = NotchClaudeExtras.shared.recentFolders.first ?? ""
    @State private var account = ""
    @State private var allowEdits = false
    @FocusState private var focused: Bool

    private var accounts: [ClaudeAccountProfile] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let usual = AgentLogRoot.canonical(home.appending(path: ".claude")).path
        return [ClaudeAccountProfile()] + ClaudeAccountProfile.discover(home: home)
            .filter { AgentLogRoot.canonical(URL(fileURLWithPath: $0.directory)).path != usual }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "plus.bubble.fill").foregroundStyle(NotchClaudeStyle.accent)
                Text("New Claude task").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    ForEach(extras.recentFolders, id: \.self) { path in
                        Button(URL(fileURLWithPath: path).lastPathComponent) { folder = path }
                    }
                    Divider()
                    Button("Choose folder…") { choose() }
                } label: {
                    Label(folder.isEmpty ? "Project" : URL(fileURLWithPath: folder).lastPathComponent, systemImage: "folder")
                        .font(.system(size: 11.5, weight: .medium))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Picker("", selection: $account) {
                    ForEach(accounts) { profile in
                        Text(profile.isDefault ? "office" : profile.name(defaultName: "office")).tag(profile.directory)
                    }
                }
                .labelsHidden().fixedSize().controlSize(.small)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22).notchGlassChip(radius: 11)
                }
                .buttonStyle(NotchSquishButtonStyle())
            }
            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("What should Claude do?").font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.35))
                        .padding(.horizontal, 5).padding(.vertical, 1)
                }
                TextEditor(text: $prompt)
                    .font(.system(size: 12.5))
                    .scrollContentBackground(.hidden)
                    .focused($focused)
            }
            .padding(8)
            .frame(maxHeight: .infinity)
            .notchGlassChip(radius: 10, fill: 0.07)
            HStack(spacing: 10) {
                Toggle("Allow file edits", isOn: $allowEdits).toggleStyle(.checkbox).font(.system(size: 11.5))
                if let running = extras.tasks.first(where: { $0.status == .running }) {
                    Label("\(running.project) running", systemImage: "hourglass").font(.system(size: 11)).foregroundStyle(.white.opacity(0.6))
                    Button("Stop") { extras.stop(running.id) }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                } else if let last = extras.tasks.first, !last.result.isEmpty {
                    Button("Copy last result") { extras.copyResult(last.id) }.buttonStyle(.plain).font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.6))
                }
                Spacer()
                Button {
                    let profile = accounts.first { $0.directory == account } ?? ClaudeAccountProfile()
                    extras.run(prompt: prompt, folder: folder, profile: profile, allowEdits: allowEdits)
                    close()
                } label: {
                    Label("Run", systemImage: "paperplane.fill").font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 28)
                        .background(NotchClaudeStyle.accent.opacity(0.85), in: Capsule())
                }
                .buttonStyle(NotchSquishButtonStyle())
                .disabled(folder.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(.horizontal, 18)
        .foregroundStyle(.white)
        .onAppear {
            if account.isEmpty, let personal = accounts.first(where: { !$0.isDefault }) { account = personal.directory }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { focused = true }
        }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use folder"
        NSApp.activate()
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}
