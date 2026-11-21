// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

enum NotchTool: String, CaseIterable, Identifiable {
    case terminal, github, focus, reminders, weather, qr, claudeTask, claudeSessions, firefly, hoot
    var id: String { rawValue }

    var title: String {
        switch self {
        case .terminal: return "Terminal"
        case .github: return "GitHub"
        case .focus: return "Focus"
        case .reminders: return "Reminders"
        case .weather: return "Weather"
        case .qr: return "QR Code"
        case .claudeTask: return "Claude Task"
        case .claudeSessions: return "Sessions"
        case .firefly: return "Fireflies"
        case .hoot: return "Hoot!"
        }
    }

    var symbol: String {
        switch self {
        case .terminal: return "apple.terminal"
        case .github: return "arrow.triangle.pull"
        case .focus: return "brain.head.profile"
        case .reminders: return "checklist"
        case .weather: return "cloud.sun"
        case .qr: return "qrcode"
        case .claudeTask: return "plus.bubble"
        case .claudeSessions: return "sparkles.rectangle.stack"
        case .firefly: return "gamecontroller"
        case .hoot: return "bolt"
        }
    }

    var color: Color {
        switch self {
        case .terminal: return Color(white: 0.22)
        case .github: return NotchApple.purple
        case .focus: return NotchApple.orange
        case .reminders: return NotchApple.blue
        case .weather: return NotchApple.cyan
        case .qr: return NotchApple.indigo
        case .claudeTask, .claudeSessions: return NotchApple.claude
        case .firefly: return NotchApple.green
        case .hoot: return NotchApple.yellow
        }
    }

    var size: CGSize {
        switch self {
        case .terminal: return CGSize(width: 580, height: 300)
        case .github: return CGSize(width: 500, height: 280)
        case .focus: return CGSize(width: 420, height: 150)
        case .reminders: return CGSize(width: 440, height: 250)
        case .weather: return CGSize(width: 500, height: 210)
        case .qr: return CGSize(width: 440, height: 230)
        default: return CGSize(width: 440, height: 200)
        }
    }
}

/// The toolbox: every tool as an app icon, the way the Home Screen lays them out.
struct NotchToolboxView: View {
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Toolbox").font(.system(size: 17, weight: .bold))
                Spacer()
                NotchStageCloseButton(action: close)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 5), spacing: 12) {
                ForEach(NotchTool.allCases) { tool in
                    Button { NotchStageController.shared.open(tool) } label: {
                        VStack(spacing: 6) {
                            NotchAppIcon(symbol: tool.symbol, color: tool.color, size: 46)
                            Text(tool.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(0.92)).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(NotchSquishButtonStyle(pressedScale: 0.9))
                }
            }
        }
        .padding(.horizontal, 20)
        .foregroundStyle(.white)
    }
}

struct NotchStageCloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                .frame(width: 22, height: 22).notchGlassChip(radius: 11)
        }
        .buttonStyle(NotchSquishButtonStyle())
        .help("Close (Esc)")
    }
}

/// A tool's header: its icon, name, and the way back to the toolbox.
struct NotchToolHeader<Trailing: View>: View {
    let tool: NotchTool
    let close: () -> Void
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Button { NotchStageController.shared.openToolbox() } label: {
                Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold)).frame(width: 22, height: 22).notchGlassChip(radius: 11)
            }
            .buttonStyle(NotchSquishButtonStyle())
            .help("Toolbox")
            NotchAppIcon(symbol: tool.symbol, color: tool.color, size: 22)
            Text(tool.title).font(.system(size: 15, weight: .bold))
            Spacer()
            trailing()
            NotchStageCloseButton(action: close)
        }
    }
}

// MARK: Terminal

struct NotchTerminalView: View {
    let close: () -> Void
    @ObservedObject private var terminal = NotchTerminal.shared
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchToolHeader(tool: .terminal, close: close) {
                Text(terminal.folderName).font(.system(size: 11, design: .monospaced)).foregroundStyle(.white.opacity(0.55)).lineLimit(1)
                    .truncationMode(.head).frame(maxWidth: 180, alignment: .trailing)
                Button("Ask Claude") { terminal.askClaude() }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 9).frame(height: 22).background(NotchClaudeStyle.accent.opacity(0.8), in: Capsule())
                    .help("Send the last command and its output to Claude to explain")
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(terminal.lines) { line in
                            Text(line.kind == .command ? "❯ " + line.text : line.text)
                                .font(.system(size: 11.5, design: .monospaced))
                                .foregroundStyle(color(line.kind))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: terminal.lines.last?.id) { _, last in if let last { proxy.scrollTo(last, anchor: .bottom) } }
            }
            .background(Color(white: 0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.white.opacity(0.08)) }
            HStack(spacing: 6) {
                Text("❯").font(.system(size: 12, weight: .bold, design: .monospaced)).foregroundStyle(NotchApple.green)
                TextField(terminal.running ? "running… (Ctrl-C to stop)" : "command", text: $terminal.input)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12, design: .monospaced))
                    .focused($focused)
                    .onSubmit { terminal.submit() }
                    .onKeyPress(.upArrow) { terminal.recall(older: true); return .handled }
                    .onKeyPress(.downArrow) { terminal.recall(older: false); return .handled }
                    .onKeyPress(characters: .init(charactersIn: "c"), phases: .down) { press in
                        guard press.modifiers.contains(.control) else { return .ignored }
                        terminal.interrupt(); return .handled
                    }
                if terminal.running {
                    Button("Stop") { terminal.interrupt() }.buttonStyle(.plain).font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(NotchApple.red)
                } else {
                    Button { terminal.submit() } label: {
                        Image(systemName: "return").font(.system(size: 11, weight: .bold))
                            .frame(width: 24, height: 20).background(NotchApple.green.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.defaultAction)
                    .help("Run")
                }
            }
            .padding(.horizontal, 10).frame(height: 30)
            .notchGlassChip(radius: 10, fill: 0.08)
        }
        .padding(.horizontal, 18)
        .foregroundStyle(.white)
        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { focused = true } }
    }

    private func color(_ kind: NotchTerminal.Line.Kind) -> Color {
        switch kind {
        case .command: return NotchApple.cyan
        case .output: return .white.opacity(0.88)
        case .error: return Color(red: 1, green: 0.5, blue: 0.45)
        case .info: return .white.opacity(0.45)
        }
    }
}

// MARK: GitHub

struct NotchGitHubView: View {
    let close: () -> Void
    @ObservedObject private var github = NotchGitHub.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchToolHeader(tool: .github, close: close) {
                if github.loading { ProgressView().controlSize(.mini) }
                Button { github.refresh() } label: { Image(systemName: "arrow.clockwise").font(.system(size: 11, weight: .semibold)) }
                    .buttonStyle(.plain).help("Check now")
            }
            if !github.available {
                note("Install the GitHub CLI (brew install gh) and sign in with gh auth login.")
            } else if let problem = github.problem {
                note(problem)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if !github.reviewing.isEmpty {
                            label("Waiting for your review")
                            ForEach(github.reviewing) { row($0) }
                        }
                        label("Your pull requests")
                        if github.mine.isEmpty { note(github.checked == nil ? "Loading…" : "No open pull requests.") }
                        ForEach(github.mine) { row($0) }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .foregroundStyle(.white)
        .onAppear { github.start(); github.refresh() }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased()).font(.system(size: 9.5, weight: .bold)).tracking(0.8).foregroundStyle(.white.opacity(0.45)).padding(.top, 2)
    }

    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(.white.opacity(0.6)).frame(maxWidth: .infinity, minHeight: 40)
    }

    private func row(_ pr: NotchGitHub.PullRequest) -> some View {
        Button { if let url = pr.url { NSWorkspace.shared.open(url) } } label: {
            HStack(spacing: 10) {
                checks(pr.checks)
                VStack(alignment: .leading, spacing: 1) {
                    Text(pr.title).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text("\(pr.repository) #\(pr.number)" + (pr.draft ? " · draft" : ""))
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.5)).lineLimit(1)
                }
                Spacer(minLength: 6)
                if let review = pr.review { reviewBadge(review) }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .notchGlassChip(radius: 10, fill: 0.06)
            .contentShape(Rectangle())
        }
        .buttonStyle(NotchSquishButtonStyle(pressedScale: 0.97))
    }

    @ViewBuilder private func checks(_ state: String?) -> some View {
        switch state {
        case "SUCCESS": Image(systemName: "checkmark.circle.fill").foregroundStyle(NotchApple.green)
        case "FAILURE", "ERROR": Image(systemName: "xmark.circle.fill").foregroundStyle(NotchApple.red)
        case "PENDING", "EXPECTED": Image(systemName: "clock.fill").foregroundStyle(NotchApple.yellow)
        default: Image(systemName: "circle.dashed").foregroundStyle(.white.opacity(0.35))
        }
    }

    private func reviewBadge(_ review: String) -> some View {
        let (text, color): (String, Color) = review == "APPROVED" ? ("Approved", NotchApple.green)
            : review == "CHANGES_REQUESTED" ? ("Changes", NotchApple.orange) : ("Review", NotchApple.gray)
        return Text(text).font(.system(size: 9.5, weight: .bold)).padding(.horizontal, 7).frame(height: 18)
            .background(color.opacity(0.25), in: Capsule()).foregroundStyle(color)
    }
}

// MARK: Focus

struct NotchFocusView: View {
    let close: () -> Void
    @ObservedObject private var timer = NotchTimerService.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            NotchToolHeader(tool: .focus, close: close) { EmptyView() }
            if timer.session.isRunning || timer.session.isPaused {
                HStack {
                    Text(timer.session.mode == .pomodoro ? "Focusing with Hoo 🦉" : "A timer is running")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("Stop") { timer.stop() }.buttonStyle(.plain).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 28).notchGlassChip(radius: 14, fill: 0.14)
                }
                Text("The time left shows in the closed notch. Hoo cheers at every break.")
                    .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.55))
            } else {
                Text("Pomodoro: focus, then a short break; a long one every fourth round.")
                    .font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                HStack(spacing: 8) {
                    ForEach([15, 25, 50], id: \.self) { minutes in
                        Button {
                            timer.start(mode: .pomodoro, minutes: minutes)
                            NotchStageController.shared.close()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                NotchStageController.shared.say("\(minutes) minutes of focus. I’ll keep watch 🦉")
                            }
                        } label: {
                            Text("\(minutes) min").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).frame(height: 34)
                                .background(minutes == 25 ? NotchApple.orange : .clear, in: Capsule())
                                .modifier(NotchGlassChip(shape: Capsule(), fill: minutes == 25 ? 0 : 0.12))
                        }
                        .buttonStyle(NotchSquishButtonStyle())
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .foregroundStyle(.white)
    }
}

// MARK: Reminders

struct NotchRemindersView: View {
    let close: () -> Void
    @ObservedObject private var reminders = NotchReminders.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchToolHeader(tool: .reminders, close: close) {
                Button { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Reminders.app")) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain).help("Open Reminders")
            }
            if reminders.access != .fullAccess {
                VStack(spacing: 8) {
                    Text("Show today’s reminders here and tick them off.").font(.system(size: 12)).foregroundStyle(.white.opacity(0.65))
                    Button("Allow Reminders") { reminders.requestAccess() }.buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold)).padding(.horizontal, 14).frame(height: 28)
                        .background(NotchApple.blue, in: Capsule())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if reminders.items.isEmpty {
                Text("All done for today 🎉").font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 4) {
                        ForEach(reminders.items) { item in
                            HStack(spacing: 10) {
                                Button { withAnimation(.spring(response: 0.3)) { reminders.complete(item.id) } } label: {
                                    Circle().strokeBorder(item.color.map(Color.init) ?? NotchApple.blue, lineWidth: 1.5).frame(width: 18, height: 18)
                                }
                                .buttonStyle(.plain)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(item.title).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    Text(item.due.map { $0 < Date() ? "Overdue · " + $0.formatted(.dateTime.hour().minute()) : $0.formatted(.dateTime.hour().minute()) } ?? item.list)
                                        .font(.system(size: 10.5)).foregroundStyle(item.due.map { $0 < Date() } == true ? NotchApple.red : .white.opacity(0.45))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .notchGlassChip(radius: 10, fill: 0.05)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .foregroundStyle(.white)
        .onAppear { reminders.refresh() }
    }
}

// MARK: Weather and world clock

struct NotchWeatherView: View {
    let close: () -> Void
    @ObservedObject private var weather = NotchWeather.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchToolHeader(tool: .weather, close: close) { EmptyView() }
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(weather.city.isEmpty ? weather.chosenCity : weather.city).font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 8) {
                        Image(systemName: weather.symbol).symbolRenderingMode(.multicolor).font(.system(size: 30))
                        Text(weather.temperature.map { "\(Int($0.rounded()))°" } ?? "–").font(.system(size: 38, weight: .light))
                    }
                    Text(weather.problem ?? weather.condition).font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                    HStack(spacing: 10) {
                        ForEach(weather.days.dropFirst().prefix(4)) { day in
                            VStack(spacing: 3) {
                                Text(Self.weekday(day.id)).font(.system(size: 10, weight: .semibold)).foregroundStyle(.white.opacity(0.55))
                                Image(systemName: day.symbol).symbolRenderingMode(.multicolor).font(.system(size: 14))
                                Text("\(Int(day.high.rounded()))°").font(.system(size: 10.5, weight: .semibold))
                            }
                        }
                    }
                    .padding(.top, 2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(LinearGradient(colors: [NotchApple.blue.opacity(0.55), NotchApple.cyan.opacity(0.3)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    VStack(spacing: 6) {
                        ForEach(NotchWeather.clocks.prefix(3), id: \.identifier) { zone in
                            HStack {
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(zone.identifier.split(separator: "/").last.map { $0.replacingOccurrences(of: "_", with: " ") } ?? zone.identifier)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(Self.offset(zone)).font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
                                }
                                Spacer()
                                Text(context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone)))
                                    .font(.system(size: 17, weight: .light)).monospacedDigit()
                            }
                            .padding(.horizontal, 10).frame(height: 40)
                            .notchGlassChip(radius: 12, fill: 0.06)
                        }
                    }
                    .frame(width: 200)
                }
            }
        }
        .padding(.horizontal, 18)
        .foregroundStyle(.white)
        .onAppear { weather.refresh() }
    }

    static func weekday(_ iso: String) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"
        guard let date = formatter.date(from: iso) else { return "" }
        return date.formatted(.dateTime.weekday(.abbreviated))
    }

    static func offset(_ zone: TimeZone) -> String {
        let hours = Double(zone.secondsFromGMT() - TimeZone.current.secondsFromGMT()) / 3600
        if hours == 0 { return "Same time" }
        let whole = abs(hours).formatted(.number.precision(.fractionLength(0...1)))
        return (hours > 0 ? "+" : "−") + whole + "h"
    }
}

// MARK: QR

struct NotchQRView: View {
    let close: () -> Void
    @State private var text = NSPasteboard.general.string(forType: .string) ?? ""
    @State private var scanned: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NotchToolHeader(tool: .qr, close: close) { EmptyView() }
            HStack(alignment: .top, spacing: 14) {
                Group {
                    if let image = NotchQR.image(for: text.isEmpty ? " " : text) {
                        Image(nsImage: image).interpolation(.none).resizable().scaledToFit()
                            .padding(8).background(.white, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
                .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 8) {
                    Text("From what you copied").font(.system(size: 10, weight: .bold)).foregroundStyle(.white.opacity(0.45))
                    TextField("Text or link", text: $text, axis: .vertical).textFieldStyle(.plain).font(.system(size: 12)).lineLimit(3)
                        .padding(8).notchGlassChip(radius: 10, fill: 0.07)
                    HStack(spacing: 8) {
                        Button {
                            if let image = NotchQR.image(for: text, size: 600) {
                                NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
                                NotchStageController.shared.say("QR code copied")
                            }
                        } label: { Label("Copy QR", systemImage: "doc.on.doc").font(.system(size: 11.5, weight: .semibold)) }
                            .buttonStyle(.plain).padding(.horizontal, 10).frame(height: 26).background(NotchApple.indigo, in: Capsule())
                        Button {
                            NotchStageController.shared.close()
                            NotchQR.scan { result in
                                guard let result else { NotchStageController.shared.say("No QR code found there"); return }
                                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(result, forType: .string)
                                if let url = URL(string: result), url.scheme?.hasPrefix("http") == true {
                                    NotchStageController.shared.say("Copied link: \(url.host ?? result)")
                                } else { NotchStageController.shared.say("Copied: \(result.prefix(60))") }
                            }
                        } label: { Label("Scan on screen", systemImage: "viewfinder").font(.system(size: 11.5, weight: .semibold)) }
                            .buttonStyle(.plain).padding(.horizontal, 10).frame(height: 26).notchGlassChip(radius: 13, fill: 0.12)
                    }
                    Text("Scan: drag over a QR code anywhere on screen; what it says is copied.")
                        .font(.system(size: 10.5)).foregroundStyle(.white.opacity(0.45))
                }
            }
        }
        .padding(.horizontal, 18)
        .foregroundStyle(.white)
    }
}

// MARK: Meeting

struct NotchMeetingView: View {
    let title: String
    let link: URL
    let start: Date
    let close: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            NotchAppIcon(symbol: "video", color: NotchApple.green, size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 10)) { context in
                    let lead = start.timeIntervalSince(context.date)
                    Text(lead > 60 ? "Starts in \(Int(lead / 60)) min" : lead > 0 ? "Starting now" : "Started \(Int(-lead / 60)) min ago")
                        .font(.system(size: 11.5)).foregroundStyle(.white.opacity(0.6))
                }
            }
            Spacer()
            Button { NSWorkspace.shared.open(link); close() } label: {
                Text("Join").font(.system(size: 13, weight: .bold)).padding(.horizontal, 18).frame(height: 32)
                    .background(NotchApple.green, in: Capsule())
            }
            .buttonStyle(NotchSquishButtonStyle())
            NotchStageCloseButton(action: close)
        }
        .padding(.horizontal, 18)
        .foregroundStyle(.white)
    }
}
