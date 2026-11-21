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

    private func askCard(_ ask: ClaudeLiveAsk) -> some View {
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
