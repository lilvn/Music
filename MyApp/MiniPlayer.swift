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

    private var progress: Double {
        player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
    }
    private var displayProgress: Double { scrubbing ? dragProgress : progress }
    private var cdOut: Bool { player.isPlaying || scrubbing }

    var body: some View {
        let item = player.currentItem ?? .placeholder
        HStack(spacing: 10) {
            thumb(item)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                Text(item.primaryArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            playPause
            control("forward.fill") { player.nextTrack() }
                .disabled(!player.queue.hasNext)
                .opacity(player.queue.hasNext ? 1 : 0.3)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 12)
        .frame(height: 56)
        .frame(maxWidth: .infinity)
        .background(alignment: .leading) {
            Rectangle()
                .fill(Color.primary.opacity(scrubbing ? 0.14 : 0.08))
                .frame(width: max(0, width * displayProgress))
                .animation(scrubbing ? nil : .linear(duration: 0.5), value: displayProgress)
                .allowsHitTesting(false)
        }
        .background { GeometryReader { g in Color.clear.onChange(of: g.size.width, initial: true) { _, w in width = w } } }
        .glassEffect(.regular.interactive(), in: Capsule())
        .clipShape(Capsule())
        .scaleEffect(scrubbing ? 1.03 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scrubbing)
        .contentShape(Capsule())
        .matchedTransitionSource(id: "np", in: namespace)
        .onTapGesture { player.showNowPlaying = true }
        .simultaneousGesture(scrubGesture)
        .sensoryFeedback(trigger: scrubbing) { _, now in now ? .impact(weight: .heavy, intensity: 1.0) : nil }
        .sensoryFeedback(.selection, trigger: tick)
    }

    /// Rectangle album art with the CD sliding out from behind it (right) when playing / scrubbing.
    private func thumb(_ item: MediaItem) -> some View {
        ZStack(alignment: .leading) {
            SpinningDisc(artURL: client.artworkURL(for: item, size: 120), size: 40,
                         spinning: cdOut, scrubProgress: scrubbing ? dragProgress : nil)
                .offset(x: cdOut ? 24 : 0)
                .opacity(cdOut ? 1 : 0)
                .animation(.spring(response: 0.5, dampingFraction: 0.72), value: cdOut)

            LibraryImage(url: client.artworkURL(for: item, size: 120), maxPixel: 120) {
                Color(.systemGray5)
            }
            .frame(width: 40, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .frame(width: 64, height: 40, alignment: .leading)
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
                        dragProgress = progress
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
