// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import Combine
import SwiftUI

// The stage: a little black room that drops out of the bottom of the notch,
// as if the notch grew, for the companion to perform in now and then, and
// to play a mini game in. It is its own window, under the island's, so it
// never changes how the island lays out its pages.

enum NotchStageAct: CaseIterable {
    case flyBy, dance, juggle, magic, nap

    var length: TimeInterval { self == .nap ? 5.5 : 4.5 }
}

private final class NotchStagePanel: NSPanel {
    var allowsKey = false
    override var canBecomeKey: Bool { allowsKey }
    override var canBecomeMain: Bool { false }
}

final class NotchStageModel: ObservableObject {
    enum Mode: Equatable { case hidden, act(NotchStageAct), game }

    @Published var mode: Mode = .hidden
    @Published var open = false
    @Published var tick = 0
    var started = Date()
    let game = NotchFireflyGame()
}

/// Owns the stage window and decides when the companion performs.
final class NotchStageController {
    static let shared = NotchStageController()

    let model = NotchStageModel()
    private var panel: NotchStagePanel?
    private var scheduler: Timer?
    private var lastShow = Date()
    private var closeWork: DispatchWorkItem?
    private var keyMonitor: Any?

    static let actSize = CGSize(width: 340, height: 96)
    static let gameSize = CGSize(width: 460, height: 170)

    /// Checks once a minute whether it is a good moment for a show.
    func start() {
        guard scheduler == nil else { return }
        lastShow = Date()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in self?.considerShow() }
        timer.tolerance = 15
        RunLoop.main.add(timer, forMode: .common)
        scheduler = timer
    }

    private var showsEnabled: Bool {
        NotchMascotSupport.isEnabled() && UserDefaults.standard.object(forKey: DefaultsKey.notchMascotShows) as? Bool ?? true
    }

    /// The island is closed, on screen and quiet: nothing would be covered.
    private var quietMoment: Bool {
        let notch = NotchService.shared
        return notch.running && !notch.expanded && !notch.fullscreenCompact && model.mode == .hidden
    }

    private func considerShow() {
        guard showsEnabled, quietMoment else { return }
        // About every half hour, give or take, never sooner than 20 minutes.
        let since = Date().timeIntervalSince(lastShow)
        guard since > 20 * 60, Double.random(in: 0..<1) < min(1, (since - 20 * 60) / (20 * 60)) else { return }
        perform(NotchStageAct.allCases.randomElement() ?? .dance)
    }

    /// Something worth a little show happened, such as an agent finishing.
    func celebrate() {
        guard showsEnabled, quietMoment, Date().timeIntervalSince(lastShow) > 8 * 60 else { return }
        perform(.dance)
    }

    func perform(_ act: NotchStageAct) {
        guard model.mode == .hidden || model.mode != .game else { return }
        lastShow = Date()
        present(.act(act), size: Self.actSize, interactive: false)
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.close() }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + act.length, execute: work)
    }

    func startGame() {
        closeWork?.cancel()
        // The open island folds away first, so the stage drops out of the notch.
        if NotchService.shared.expanded { NotchService.shared.collapse() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self else { return }
            self.model.game.reset()
            self.present(.game, size: Self.gameSize, interactive: true)
            self.model.game.begin(panelFrame: { [weak self] in self?.panel?.frame ?? .zero },
                                  stageSize: Self.gameSize) { [weak self] in self?.gameEnded() }
        }
    }

    private func gameEnded() {
        closeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard self?.model.game.phase == .over else { return }
            self?.close()
        }
        closeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: work)
    }

    func close() {
        closeWork?.cancel()
        model.game.stop()
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        withAnimation(.easeIn(duration: 0.22)) { model.open = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) { [weak self] in
            guard let self, !self.model.open else { return }
            self.model.mode = .hidden
            self.panel?.orderOut(nil)
        }
    }

    private func present(_ mode: NotchStageModel.Mode, size: CGSize, interactive: Bool) {
        let geometry = NotchService.shared.geometry
        let center = geometry.physicalCamera?.midX ?? geometry.screen.midX
        let top = geometry.screen.maxY - geometry.stripHeight
        let frame = CGRect(x: center - size.width / 2, y: top - size.height, width: size.width, height: size.height)
        let panel = self.panel ?? makePanel()
        panel.setFrame(frame, display: false)
        panel.allowsKey = interactive
        panel.ignoresMouseEvents = !interactive
        model.mode = mode
        model.started = Date()
        model.open = false
        panel.orderFrontRegardless()
        if interactive {
            panel.makeKey()
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.model.mode == .game else { return event }
                switch event.keyCode {
                case 53: self.close(); return nil                       // Escape
                case 49, 126: self.model.game.flap(); return nil         // Space, up arrow
                case 123: self.model.game.nudge(-1); return nil          // left arrow
                case 124: self.model.game.nudge(1); return nil           // right arrow
                default: return event
                }
            }
        }
        DispatchQueue.main.async {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.72)) { self.model.open = true }
        }
    }

    private func makePanel() -> NotchStagePanel {
        let panel = NotchStagePanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = NotchPanel.normalLevel
        panel.collectionBehavior = NotchPanel.overlayCollectionBehavior
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        let host = NSHostingView(rootView: NotchStageView(model: model, notchWidth: NotchService.shared.geometry.cameraWidth))
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        self.panel = panel
        return panel
    }
}

// MARK: The room

/// Black like the notch, as wide as the camera where it meets it, flaring
/// out with soft shoulders into the room below.
struct NotchStageShape: Shape {
    var neck: CGFloat
    func path(in rect: CGRect) -> Path {
        let neck = min(neck, rect.width)
        let shoulder: CGFloat = min(16, rect.height / 3)
        let radius: CGFloat = min(26, rect.height / 2)
        let left = (rect.width - neck) / 2, right = left + neck
        var path = Path()
        path.move(to: CGPoint(x: left, y: 0))
        path.addLine(to: CGPoint(x: right, y: 0))
        path.addCurve(to: CGPoint(x: rect.maxX, y: shoulder + 4),
                      control1: CGPoint(x: right + 2, y: shoulder), control2: CGPoint(x: rect.maxX - 10, y: shoulder))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: radius, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: 0, y: rect.maxY - radius), control: CGPoint(x: 0, y: rect.maxY))
        path.addLine(to: CGPoint(x: 0, y: shoulder + 4))
        path.addCurve(to: CGPoint(x: left, y: 0),
                      control1: CGPoint(x: 10, y: shoulder), control2: CGPoint(x: left - 2, y: shoulder))
        path.closeSubpath()
        return path
    }
}

struct NotchStageView: View {
    @ObservedObject var model: NotchStageModel
    let notchWidth: CGFloat

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                NotchStageShape(neck: max(120, notchWidth - 20))
                    .fill(Color.black)
                    .overlay {
                        NotchStageShape(neck: max(120, notchWidth - 20))
                            .stroke(LinearGradient(colors: [.clear, .white.opacity(0.14)], startPoint: .top, endPoint: .bottom),
                                    lineWidth: 1)
                    }
                Group {
                    switch model.mode {
                    case .act(let act): NotchStageActView(act: act, started: model.started)
                    case .game: NotchFireflyGameView(game: model.game) { NotchStageController.shared.close() }
                    case .hidden: Color.clear
                    }
                }
                .padding(.top, 16)
                .opacity(model.open ? 1 : 0)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .scaleEffect(x: 1, y: model.open ? 1 : 0.02, anchor: .top)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// Draws the companion's sprite, crisp, at any size.
struct NotchPixelSprite: View {
    var state: NotchPixelHoo.State
    var flipped = false

    var body: some View {
        if let image = NotchPixelHoo.image(state) {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaleEffect(x: flipped ? -1 : 1, y: 1)
        }
    }
}

private func currentLook() -> (palette: NotchMascotPalette, accessory: NotchMascotAccessory) {
    let look = NotchMascotSupport.look()
    var accessory = NotchMascotAccessory.current()
    if accessory == .auto {
        accessory = NotchMascotAccessory.automatic(musicPlaying: NotchMusicService.shared.playback?.isPlaying == true)
    }
    return (look.palette, accessory)
}

// MARK: Acts

struct NotchStageActView: View {
    let act: NotchStageAct
    let started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 1 / NotchPixelHoo.fps)) { context in
            let t = context.date.timeIntervalSince(started)
            let frame = Int(t * NotchPixelHoo.fps)
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    scene(t: t, frame: frame, size: proxy.size)
                }
            }
        }
    }

    @ViewBuilder private func scene(t: TimeInterval, frame: Int, size: CGSize) -> some View {
        let look = currentLook()
        let sprite: CGFloat = 48
        let floor = size.height - sprite - 4
        let mid = (size.width - sprite) / 2
        switch act {
        case .flyBy:
            let p = min(1, t / (act.length - 0.4))
            let x = -sprite + (size.width + sprite) * p
            let y = floor - 14 - sin(p * .pi * 3) * 10
            ForEach(0..<6, id: \.self) { k in
                let back = Double(k) * 0.035
                if p - back > 0 {
                    Rectangle().fill(Color.yellow.opacity(0.7 - Double(k) * 0.1)).frame(width: 3, height: 3)
                        .offset(x: x - CGFloat(k) * 12 + sprite / 2, y: floor + 6 - sin((p - back) * .pi * 3) * 10 + sprite / 2)
                }
            }
            NotchPixelSprite(state: .init(mood: .happy, frame: frame, accessory: look.accessory, palette: look.palette))
                .frame(width: sprite, height: sprite).offset(x: x, y: y)
        case .dance:
            let hop = abs(sin(t * 5)) * 10
            let mood: NotchMascotMood = frame % 16 < 8 ? .happy : .love
            ForEach(0..<4, id: \.self) { k in
                let phase = (t * 0.7 + Double(k) / 4).truncatingRemainder(dividingBy: 1)
                Image(systemName: k % 2 == 0 ? "music.note" : "music.quarternote.3")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(.pink.opacity(1 - phase))
                    .offset(x: mid + (k % 2 == 0 ? -26 : sprite + 14) + sin(phase * 6) * 4, y: floor + 10 - phase * 40)
            }
            NotchPixelSprite(state: .init(mood: mood, frame: frame, accessory: look.accessory, palette: look.palette),
                             flipped: frame % 8 < 4)
                .frame(width: sprite, height: sprite).offset(x: mid, y: floor - hop)
        case .juggle:
            ForEach(0..<3, id: \.self) { k in
                let a = t * 4 + Double(k) * 2.094
                Circle().fill([Color.red, .orange, .purple][k]).frame(width: 8, height: 8)
                    .offset(x: mid + sprite / 2 - 4 + cos(a) * 26, y: floor - 10 - abs(sin(a)) * 30)
            }
            NotchPixelSprite(state: .init(mood: .determined, frame: frame, accessory: look.accessory, palette: look.palette))
                .frame(width: sprite, height: sprite).offset(x: mid, y: floor)
        case .magic:
            let burst = t > 1.6
            ForEach(0..<10, id: \.self) { k in
                let a = Double(k) / 10 * 2 * .pi, r = burst ? min(60, (t - 1.6) * 70) : 0
                Image(systemName: "sparkle").font(.system(size: 9)).foregroundStyle(.yellow.opacity(burst ? max(0, 1 - (t - 1.6) / 2.4) : 0))
                    .offset(x: mid + sprite / 2 - 4 + cos(a) * r, y: floor + sprite / 2 - 8 + sin(a) * r * 0.5)
            }
            NotchPixelSprite(state: .init(mood: burst ? .surprised : .thinking, frame: frame, accessory: .wizard, palette: look.palette))
                .frame(width: sprite, height: sprite).offset(x: mid, y: floor - (burst ? 6 : 0))
        case .nap:
            let awake = t > 3.6
            NotchPixelSprite(state: .init(mood: awake ? (t > 4.3 ? .happy : .surprised) : .sleepy, frame: frame,
                                          accessory: awake ? look.accessory : .beanie, palette: look.palette))
                .frame(width: sprite, height: sprite).offset(x: mid, y: floor)
        }
    }
}

// MARK: Firefly Catch

/// Fireflies drift down through the room; the owlet follows the pointer
/// along the floor and catches them. Gold ones count three. Raindrops knock
/// a second off the clock. Thirty seconds a round.
final class NotchFireflyGame: ObservableObject {
    enum Phase { case ready, playing, over }
    struct Thing: Identifiable {
        enum Kind { case firefly, gold, rain }
        let id = UUID()
        var kind: Kind
        var x: CGFloat
        var y: CGFloat
        var speed: CGFloat
        var sway: CGFloat
        var born: TimeInterval
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var things: [Thing] = []
    @Published private(set) var owlX: CGFloat = 200
    @Published private(set) var owlY: CGFloat = 0
    @Published private(set) var score = 0
    @Published private(set) var timeLeft: TimeInterval = 30
    @Published private(set) var frame = 0
    @Published private(set) var lastCatch: (x: CGFloat, y: CGFloat, text: String, at: TimeInterval)?
    @Published private(set) var best = UserDefaults.standard.integer(forKey: DefaultsKey.notchMascotGameBest)
    private var timer: Timer?
    private var clock: TimeInterval = 0
    private var velocity: CGFloat = 0
    private var nudgeTarget: CGFloat?
    private var panelFrame: () -> CGRect = { .zero }
    private var size = CGSize(width: 460, height: 170)
    private var onEnd: () -> Void = {}
    private var spawnDebt: TimeInterval = 0

    static let owl: CGFloat = 40
    var floor: CGFloat { size.height - 16 - Self.owl - 8 }

    func reset() {
        stop()
        phase = .ready; things = []; score = 0; timeLeft = 30; clock = 0; owlY = 0; velocity = 0
        best = UserDefaults.standard.integer(forKey: DefaultsKey.notchMascotGameBest)
    }

    func begin(panelFrame: @escaping () -> CGRect, stageSize: CGSize, onEnd: @escaping () -> Void) {
        self.panelFrame = panelFrame
        self.size = stageSize
        self.onEnd = onEnd
        owlX = (stageSize.width - Self.owl) / 2
        phase = .playing
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in self?.step(1 / 60) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// A hop, to reach a firefly a little higher up.
    func flap() {
        if phase == .over { return }
        if owlY == 0 { velocity = -260 }
    }

    func nudge(_ direction: CGFloat) {
        nudgeTarget = max(0, min(size.width - Self.owl, (nudgeTarget ?? owlX) + direction * 40))
    }

    private func step(_ dt: TimeInterval) {
        guard phase == .playing else { return }
        clock += dt
        frame = Int(clock * NotchPixelHoo.fps)
        timeLeft = max(0, timeLeft - dt)
        // Follow the pointer across the room.
        let mouse = NSEvent.mouseLocation, box = panelFrame()
        var target = owlX
        if box.width > 0, box.insetBy(dx: -80, dy: -60).contains(mouse) {
            target = mouse.x - box.minX - Self.owl / 2
            nudgeTarget = nil
        } else if let nudgeTarget { target = nudgeTarget }
        owlX += (max(0, min(size.width - Self.owl, target)) - owlX) * min(1, CGFloat(dt) * 12)
        // Hop.
        if owlY < 0 || velocity < 0 {
            velocity += 900 * CGFloat(dt)
            owlY = min(0, owlY + velocity * CGFloat(dt))
            if owlY == 0 { velocity = 0 }
        }
        // New things fall in faster as the round goes on.
        spawnDebt += dt * (1.6 + clock / 12)
        while spawnDebt >= 1 {
            spawnDebt -= 1
            let roll = Double.random(in: 0..<1)
            let kind: Thing.Kind = roll < 0.12 ? .gold : roll < 0.3 ? .rain : .firefly
            things.append(Thing(kind: kind, x: .random(in: 10...(size.width - 10)), y: -6,
                                speed: kind == .rain ? .random(in: 70...100) : .random(in: 26...46),
                                sway: .random(in: 8...20), born: clock))
        }
        let owlBox = CGRect(x: owlX + 4, y: floor + owlY + 6, width: Self.owl - 8, height: Self.owl - 8)
        var kept: [Thing] = []
        for var thing in things {
            thing.y += thing.speed * CGFloat(dt)
            let x = thing.x + sin(CGFloat(clock - thing.born) * 2.4) * (thing.kind == .rain ? 0 : thing.sway)
            if owlBox.contains(CGPoint(x: x, y: thing.y)) {
                switch thing.kind {
                case .firefly: score += 1; lastCatch = (x, thing.y, "+1", clock)
                case .gold: score += 3; lastCatch = (x, thing.y, "+3", clock)
                case .rain: timeLeft = max(0, timeLeft - 1); lastCatch = (x, thing.y, "−1s", clock)
                }
                continue
            }
            if thing.y < size.height { kept.append(thing) }
        }
        things = kept
        if timeLeft <= 0 { finish() }
    }

    func position(of thing: Thing) -> CGPoint {
        CGPoint(x: thing.x + sin(CGFloat(clock - thing.born) * 2.4) * (thing.kind == .rain ? 0 : thing.sway), y: thing.y)
    }

    var catchFresh: Bool { lastCatch.map { clock - $0.at < 0.6 } ?? false }

    private func finish() {
        phase = .over
        stop()
        if score > best {
            best = score
            UserDefaults.standard.set(score, forKey: DefaultsKey.notchMascotGameBest)
        }
        onEnd()
    }
}

struct NotchFireflyGameView: View {
    @ObservedObject var game: NotchFireflyGame
    let close: () -> Void

    var body: some View {
        let look = currentLook()
        ZStack(alignment: .topLeading) {
            ForEach(game.things) { thing in
                let p = game.position(of: thing)
                switch thing.kind {
                case .firefly:
                    Circle().fill(Color(red: 1, green: 0.95, blue: 0.5)).frame(width: 5, height: 5)
                        .shadow(color: .yellow, radius: 5).position(p)
                case .gold:
                    Image(systemName: "sparkle").font(.system(size: 11, weight: .bold)).foregroundStyle(.orange)
                        .shadow(color: .orange, radius: 6).position(p)
                case .rain:
                    Capsule().fill(Color(red: 0.5, green: 0.75, blue: 1)).frame(width: 2.5, height: 8).position(p)
                }
            }
            NotchPixelSprite(state: .init(mood: game.phase == .over ? (game.score >= game.best ? .love : .happy)
                                          : game.catchFresh ? .happy : .idle,
                                          frame: game.frame, accessory: look.accessory, palette: look.palette, walking: true))
                .frame(width: NotchFireflyGame.owl, height: NotchFireflyGame.owl)
                .offset(x: game.owlX, y: game.floor + game.owlY)
            if let hit = game.lastCatch, game.catchFresh {
                Text(hit.text).font(.system(size: 11, weight: .heavy, design: .rounded))
                    .foregroundStyle(hit.text.hasPrefix("−") ? .cyan : .yellow)
                    .position(x: hit.x, y: hit.y - 14)
            }
            HStack {
                Label("\(game.score)", systemImage: "sparkles").font(.system(size: 12, weight: .bold, design: .rounded))
                Spacer()
                Text("\(Int(game.timeLeft.rounded(.up)))s")
                    .font(.system(size: 12, weight: .bold, design: .rounded)).monospacedDigit()
                    .foregroundStyle(game.timeLeft < 6 ? .orange : .white.opacity(0.8))
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22).notchGlassChip(radius: 11)
                }
                .buttonStyle(NotchSquishButtonStyle())
                .help("Close (Esc)")
            }
            .padding(.horizontal, 18)
            .foregroundStyle(.white)
            if game.phase == .over {
                VStack(spacing: 6) {
                    Text(game.score >= game.best && game.score > 0 ? "New best! \(game.score)" : "Caught \(game.score)")
                        .font(.system(size: 16, weight: .heavy, design: .rounded))
                    Text("Best \(game.best)").font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.6))
                    Button("Play again") { NotchStageController.shared.startGame() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 14).frame(height: 28)
                        .notchGlassChip(radius: 14, fill: 0.2)
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 30)
            } else if game.timeLeft > 28.5 {
                Text("Catch the fireflies · move the pointer · click or Space to hop")
                    .font(.system(size: 10.5, weight: .medium)).foregroundStyle(.white.opacity(0.55))
                    .frame(maxWidth: .infinity).padding(.top, 26)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { game.flap() }
    }
}
