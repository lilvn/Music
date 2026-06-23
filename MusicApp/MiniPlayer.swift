import SwiftUI

/// A custom Liquid-Glass mini bar (shown above the tab bar only while a track is loaded — see
/// RootTabView). Apple-Music-style: the album art is a rounded RECTANGLE; a spinning CD pops out
/// from behind it while playing (and during a scrub, where it tracks the drag) and retracts when
/// paused. Long-press anywhere and drag to scrub; tap to open Now Playing.
struct MiniPlayer: View {
    let namespace: Namespace.ID
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client

    @State private var width: CGFloat = 1
    @State private var scrubbing = false
    @State private var scrubStart: Double = 0
    @State private var dragProgress: Double = 0
    @State private var scrubWasPlaying = false
    @State private var tick = 0
    /// Set the instant a scrub engages, so a horizontal flick is ignored after a scrub (the two
    /// gestures' `onEnded` can fire in either order).
    @State private var didScrubThisDrag = false
    /// The title follows the finger during a skip-swipe (Apple-Music feel).
    @State private var swipeOffset: CGFloat = 0
    /// Direction the NEXT title slides in from (set on each skip).
    @State private var skipEdge: Edge = .trailing

    private var progress: Double {
        player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
    }
    private var displayProgress: Double { scrubbing ? dragProgress : progress }
    private var cdOut: Bool { player.isPlaying || scrubbing }

    var body: some View {
        let item = player.currentItem ?? .placeholder
        ZStack {
            // The title sits BEHIND the artwork + controls. It's masked to be fully opaque only in the
            // gap between them and to fade out UNDER the artwork (left) and controls (right) — so the
            // resting title isn't clipped at its start, and a swipe slides it away behind them (the
            // next/prev title emerges from behind, never on top of the art or buttons).
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                Text(item.primaryArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.leading, 60)
            .padding(.trailing, 116)
            .frame(maxWidth: .infinity, alignment: .leading)
            .id(item.id)
            .transition(.asymmetric(
                insertion: .offset(x: skipEdge == .trailing ? 40 : -40).combined(with: .opacity),
                removal: .offset(x: skipEdge == .trailing ? -40 : 40).combined(with: .opacity)))
            .offset(x: swipeOffset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .compositingGroup()
            .mask(titleEdgeMask)
            .animation(.easeInOut(duration: 0.32), value: item.id)

            HStack(spacing: 8) {
                thumb(item)
                Spacer(minLength: 0)
                control("backward.fill") { skipEdge = .leading; player.previousTrack() }
                playPause
                control("forward.fill") { skipEdge = .trailing; player.nextTrack() }
                    .disabled(!player.canGoNext)
                    .opacity(player.canGoNext ? 1 : 0.3)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        // Fill the bottom-accessory's bounds so the progress fill spans the whole glass pill.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Progress fill = the dynamic artwork gradient, toned toward the system background so it
        // adapts to light/dark, revealed left→right as the track plays.
        .background(alignment: .leading) {
            ArtworkGradient(url: client.artworkURL(for: item, size: 160), blur: 20)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .overlay(Color(.systemBackground).opacity(0.34))
                .opacity(scrubbing ? 0.95 : 0.82)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: max(0, width * displayProgress))
                        .animation(scrubbing ? nil : .linear(duration: 0.5), value: displayProgress)
                }
                .allowsHitTesting(false)
        }
        .background { GeometryReader { g in Color.clear.onChange(of: g.size.width, initial: true) { _, w in width = w } } }
        // The tabViewBottomAccessory already supplies the Liquid Glass; we only clip our own progress
        // fill to the pill shape (no second glass layer).
        .clipShape(Capsule())
        .contentShape(Capsule())
        .matchedTransitionSource(id: "np", in: namespace)
        .onTapGesture { player.showNowPlaying = true }
        .simultaneousGesture(scrubGesture)
        .simultaneousGesture(swipeGesture)
        .sensoryFeedback(trigger: scrubbing) { _, now in now ? .impact(weight: .heavy, intensity: 1.0) : nil }
        .sensoryFeedback(.selection, trigger: tick)
    }

    /// Rectangle album art with the CD sliding out from behind it (right) when playing / scrubbing —
    /// same disc Ø and pull-out ratio as the cover-flow CD, so the two pop out by the same amount.
    private func thumb(_ item: MediaItem) -> some View {
        let art: CGFloat = 40
        return ZStack(alignment: .leading) {
            SpinningDisc(artURL: client.artworkURL(for: item, size: 160),
                         size: art * SpinningDisc.diameterRatio,
                         spinning: cdOut, scrubProgress: scrubbing ? dragProgress : nil)
                .offset(x: cdOut ? art * SpinningDisc.pullOutRatio : 0)
                .opacity(cdOut ? 1 : 0)
                .animation(.spring(response: 0.55, dampingFraction: 0.74), value: cdOut)

            LibraryImage(url: client.artworkURL(for: item, size: 160), maxPixel: 160) {
                ArtworkPlaceholder()
            }
            .frame(width: art, height: art)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerMini, style: .continuous))
        }
        .frame(width: art * 1.25, height: art, alignment: .leading)
    }

    // Opaque only in the gap between artwork and controls; fades to clear over the artwork (left) and
    // the controls (right) so the title disappears UNDER them rather than at a hard edge.
    private var titleEdgeMask: some View {
        LinearGradient(stops: [
            .init(color: .clear, location: 0.0),
            .init(color: .clear, location: 0.10),
            .init(color: .black, location: 0.15),
            .init(color: .black, location: 0.65),
            .init(color: .clear, location: 0.71),
            .init(color: .clear, location: 1.0),
        ], startPoint: .leading, endPoint: .trailing)
    }

    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.2, maximumDistance: 22)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard player.duration > 0 else { return }
                if case .second(true, let drag) = value {
                    if !scrubbing {
                        scrubbing = true
                        didScrubThisDrag = true
                        scrubStart = progress
                        dragProgress = progress
                        scrubWasPlaying = player.isPlaying
                        player.beginScrubbing()
                    }
                    if let drag {
                        dragProgress = min(max(scrubStart + drag.translation.width / width, 0), 1)
                        player.updateScrubbing(progress: dragProgress)   // keep the cover-flow CD in sync
                        let t = Int(dragProgress * 40)
                        if t != tick { tick = t }
                    }
                }
            }
            .onEnded { _ in
                if scrubbing { player.endScrubbing(to: dragProgress * player.duration) }
                scrubbing = false
            }
    }

    /// A quick horizontal flick skips tracks (left → next, right → previous). A deliberate hold-then-
    /// drag is a scrub instead — `didScrubThisDrag` (set the moment a scrub engages) suppresses the
    /// flick in that case, and a fast flick fails the scrub's long-press so the two don't collide.
    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 18)
            .onChanged { value in
                guard !scrubbing, !didScrubThisDrag else { return }
                if abs(value.translation.width) > abs(value.translation.height) {
                    swipeOffset = max(-80, min(80, value.translation.width * 0.55))   // title trails the finger
                }
            }
            .onEnded { value in
                let wasScrub = didScrubThisDrag
                didScrubThisDrag = false
                let dx = value.translation.width, dy = value.translation.height
                if !wasScrub, !scrubbing, abs(dx) > 44, abs(dx) > abs(dy) * 1.4 {
                    if dx < 0 { skipEdge = .trailing; player.nextTrack() }
                    else { skipEdge = .leading; player.previousTrack() }
                    swipeOffset = 0   // the push transition carries the new title in
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { swipeOffset = 0 }
                }
            }
    }

    @ViewBuilder
    private var playPause: some View {
        Button { player.togglePlayPause() } label: {
            Group {
                if player.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 34, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func control(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
