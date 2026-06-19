import SwiftUI

/// Content of the `tabViewBottomAccessory`. Shows the current track with a spinning CD thumb and
/// transport; tapping the track opens the full Now Playing (zoom-expanding from here). Long-press
/// (3D-touch) anywhere on the bar and drag to scrub — the CD keeps spinning through the scrub and a
/// progress fill tracks the playhead. Renders nothing when idle so the accessory collapses.
struct MiniPlayer: View {
    let namespace: Namespace.ID
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    @State private var width: CGFloat = 1
    @State private var scrubbing = false
    @State private var scrubStart: Double = 0
    @State private var dragProgress: Double = 0
    @State private var tick = 0
    @State private var scrubWasPlaying = false

    private var progress: Double {
        player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
    }
    private var displayProgress: Double { scrubbing ? dragProgress : progress }
    // Keep the disc turning *through* a scrub (if it was playing) instead of freezing the instant the
    // user grabs the playhead — scrubbing pauses the audio, but stopping/restarting the spin looked buggy.
    private var shouldSpin: Bool { player.isPlaying || (scrubbing && scrubWasPlaying) }

    var body: some View {
        if let item = player.currentItem {
            content(for: item)
                .matchedTransitionSource(id: "np", in: namespace)
        }
    }

    private func content(for item: MediaItem) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 11) {
                SpinningDisc(artURL: artURL(item), size: 36, spinning: shouldSpin)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name)
                        .font(.subheadline).fontWeight(.semibold).lineLimit(1)
                    Text(item.primaryArtist)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .onTapGesture { player.showNowPlaying = true }

            playPause
            if placement == .expanded {
                control("forward.fill") { player.nextTrack() }
                    .disabled(!player.queue.hasNext)
                    .opacity(player.queue.hasNext ? 1 : 0.3)
            }
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        // Progress fill behind the content (subtle), magnified while scrubbing.
        .background(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(scrubbing ? 0.14 : 0.07))
                .frame(width: max(0, width * displayProgress))
                .animation(scrubbing ? nil : .linear(duration: 0.5), value: displayProgress)
                .allowsHitTesting(false)
        }
        .background {
            GeometryReader { g in
                Color.clear.onChange(of: g.size.width, initial: true) { _, w in width = w }
            }
        }
        .scaleEffect(scrubbing ? 1.04 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scrubbing)
        .simultaneousGesture(scrubGesture)
        .sensoryFeedback(trigger: scrubbing) { _, now in now ? .impact(weight: .heavy, intensity: 1.0) : nil }
        .sensoryFeedback(.selection, trigger: tick)
    }

    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.18, maximumDistance: 30)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard player.duration > 0 else { return }
                if case .second(true, let drag) = value {
                    if !scrubbing {
                        scrubbing = true
                        scrubStart = progress
                        scrubWasPlaying = player.isPlaying
                        player.beginScrubbing()
                    }
                    if let drag {
                        dragProgress = min(max(scrubStart + drag.translation.width / width, 0), 1)
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

    @ViewBuilder
    private var playPause: some View {
        Button { player.togglePlayPause() } label: {
            Group {
                if player.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 32, height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func control(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 30, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func artURL(_ item: MediaItem) -> URL? { client.artworkURL(for: item, size: 120) }
}
