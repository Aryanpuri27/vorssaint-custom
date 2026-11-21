// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

// "Frost": the island as a pane of frosted glass. Controls are glass chips
// with a light catch along their top edge, presses squish and spring back,
// and the player is a stack of covers you swipe through like cards.

/// A press squishes the control down and lets it spring back.
struct NotchSquishButtonStyle: ButtonStyle {
    var pressedScale: CGFloat = 0.86
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(enabled ? 1 : 0.4)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.55), value: configuration.isPressed)
    }
}

/// A transport glyph that hops when it is pressed.
struct NotchFrostGlyph: View {
    let symbol: String
    let size: CGFloat
    var taps = 0

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(.white)
            .symbolEffect(.bounce.down.byLayer, value: taps)
    }
}

// MARK: Swipe stack

/// The song's cover on top of a little deck. Drag it aside to skip, the way
/// it leaves telling which way; tap it to play or pause. The cards behind
/// are the next songs when the queue is known, the same cover otherwise.
struct NotchSwipeStack: View {
    let image: NSImage?
    var behind: [NSImage] = []
    var source: RadialNowPlayingSnapshot? = nil
    let size: CGFloat
    let playing: Bool
    var canSkipNext = true
    var canSkipPrevious = true
    /// Changes with the song, so a new one deals in.
    let trackKey: String
    let onToggle: () -> Void
    let onSkip: (_ forward: Bool) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var drag: CGFloat = 0
    @State private var dealt = true
    @State private var hovering = false

    private var radius: CGFloat { size * 0.2 }

    var body: some View {
        ZStack {
            card(behind.count > 1 ? behind[1] : behind.first ?? image)
                .scaleEffect(0.84)
                .rotationEffect(.degrees(10))
                .offset(x: size * 0.16 + min(0, drag) * -0.05, y: -size * 0.06)
                .brightness(-0.18)
                .opacity(0.65)
            card(behind.first ?? image)
                .scaleEffect(0.92 + min(1, abs(drag) / (size * 1.4)) * 0.08)
                .rotationEffect(.degrees(5 - min(5, abs(drag) / 12)))
                .offset(x: size * 0.08 * (1 - min(1, abs(drag) / (size * 1.4))), y: -size * 0.03)
                .brightness(-0.08)
            card(image)
                .overlay { pauseBadge }
                .scaleEffect(dealt ? (hovering && !reduceMotion ? 1.03 : 1) : 0.9)
                .opacity(dealt ? 1 : 0)
                .rotationEffect(.degrees(Double(drag / 10)))
                .offset(x: drag)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
                .onHover { hovering = $0 }
                .onTapGesture(perform: onToggle)
                .gesture(swipe)
                .accessibilityElement()
                .accessibilityLabel(playing ? "Pause" : "Play")
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Next song") { onSkip(true) }
                .accessibilityAction(named: "Previous song") { onSkip(false) }
        }
        .frame(width: size * 1.22, height: size * 1.12, alignment: .leading)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.72), value: hovering)
        .onChange(of: trackKey) {
            guard !reduceMotion else { return }
            var quiet = Transaction()
            quiet.disablesAnimations = true
            withTransaction(quiet) { dealt = false; drag = 0 }
            withAnimation(.spring(response: 0.45, dampingFraction: 0.7)) { dealt = true }
        }
    }

    private func card(_ cover: NSImage?) -> some View {
        NotchArtwork(image: cover, size: size, source: source)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay { NotchGlassHighlight(shape: RoundedRectangle(cornerRadius: radius, style: .continuous), strength: 0.8) }
    }

    @ViewBuilder private var pauseBadge: some View {
        if !playing {
            Image(systemName: "play.fill")
                .font(.system(size: size * 0.2, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: size * 0.38, height: size * 0.38)
                .background(.black.opacity(0.38), in: Circle())
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        }
    }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                let width = value.translation.width
                // A song with no neighbour that way resists the pull.
                let blocked = (width < 0 && !canSkipNext) || (width > 0 && !canSkipPrevious)
                drag = blocked ? width * 0.25 : width
            }
            .onEnded { value in
                let width = value.translation.width + (value.predictedEndTranslation.width - value.translation.width) * 0.3
                let threshold = size * 0.45
                let forward = width < -threshold && canSkipNext
                let back = width > threshold && canSkipPrevious
                guard forward || back else {
                    withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.6)) { drag = 0 }
                    return
                }
                withAnimation(reduceMotion ? nil : .easeIn(duration: 0.16)) { drag = forward ? -size * 2.4 : size * 2.4 }
                DispatchQueue.main.asyncAfter(deadline: .now() + (reduceMotion ? 0 : 0.16)) {
                    onSkip(forward)
                    // The player may not answer with a new song; the card comes back then.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                        if drag != 0 { withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) { drag = 0 } }
                    }
                }
            }
    }
}

// MARK: Song pop

/// What a new song pops the island open to: the deck, the song, and the two
/// buttons wanted most, dealt in one after another.
struct NotchSongPopView: View {
    let playback: NotchPlayback
    @ObservedObject var service: NotchService
    let onOpen: () -> Void
    @ObservedObject private var music = NotchMusicService.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false
    @State private var nextTaps = 0

    private var canCommand: Bool {
        playback.canSendCommandsDirectly || music.automationAvailability?.access == .granted
    }

    var body: some View {
        HStack(spacing: 16) {
            NotchSwipeStack(image: music.artwork, source: playback.track, size: 56, playing: playback.isPlaying,
                            canSkipNext: canCommand && !music.lacksTrackSkipping(.next),
                            canSkipPrevious: canCommand && !music.lacksTrackSkipping(.previous),
                            trackKey: (playback.track.title ?? "") + "|" + (playback.track.artist ?? ""),
                            onToggle: { _ = music.send(.toggle, context: playback.commandContext) },
                            onSkip: { forward in _ = music.send(forward ? .next : .previous, context: playback.commandContext) })
                .offset(x: shown || reduceMotion ? 0 : -12)
                .opacity(shown ? 1 : 0)
            VStack(alignment: .leading, spacing: 3) {
                Text("NOW PLAYING")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1.4)
                    .foregroundStyle(.white.opacity(0.6))
                Text(playback.track.title ?? "")
                    .font(.system(size: 15, weight: .semibold))
                    .lineLimit(1)
                Text(playback.track.artist ?? playback.track.album ?? "")
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.72))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .offset(x: shown || reduceMotion ? 0 : 10)
            .opacity(shown ? 1 : 0)
            if canCommand, !music.lacksTrackSkipping(.next) {
                Button {
                    nextTaps += 1
                    _ = music.send(.next, context: playback.commandContext)
                } label: {
                    NotchFrostGlyph(symbol: "forward.fill", size: 15, taps: nextTaps)
                        .frame(width: 42, height: 34)
                        .notchGlassChip(radius: 17)
                        .contentShape(Capsule())
                }
                .buttonStyle(NotchSquishButtonStyle())
                .accessibilityLabel("Next song")
                .scaleEffect(shown || reduceMotion ? 1 : 0.7)
                .opacity(shown ? 1 : 0)
            }
        }
        .frame(height: NotchSongPopLayout.contentHeight)
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onAppear {
            guard !reduceMotion else { shown = true; return }
            withAnimation(.spring(response: 0.5, dampingFraction: 0.72).delay(0.05)) { shown = true }
        }
    }
}
