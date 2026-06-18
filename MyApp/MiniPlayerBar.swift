import SwiftUI

struct MiniPlayerBar: View {
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var api: JellyfinAPI

    @State private var scrubbing = false
    @State private var scrubStart: Double = 0
    @State private var dragProgress: Double = 0
    @State private var tick = 0

    private var progress: Double {
        player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
    }
    private var displayProgress: Double { scrubbing ? dragProgress : progress }
    private var shouldSpin: Bool { player.isPlaying && !scrubbing }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle()
                    .fill(Color.primary.opacity(scrubbing ? 0.14 : 0.08))
                    .frame(width: geo.size.width * CGFloat(displayProgress))
                    .animation(scrubbing ? nil : .linear(duration: 0.5), value: displayProgress)

                HStack(spacing: 10) {
                    HStack(spacing: 11) {
                        SpinningDisc(
                            artURL: api.artworkURL(for: player.currentItem ?? .placeholder, size: 120),
                            size: 38,
                            spinning: shouldSpin
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(player.currentItem?.name ?? "")
                                .font(.subheadline).fontWeight(.semibold).lineLimit(1)
                            Text(player.currentItem?.primaryArtist ?? "")
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { player.showNowPlaying = true }

                    control("backward.fill", size: 14) { player.previousTrack() }
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
                        .frame(width: 30, height: 38)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    control("forward.fill", size: 14) { player.nextTrack() }
                        .disabled(!player.queue.hasNext)
                        .opacity(player.queue.hasNext ? 1 : 0.3)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.16, maximumDistance: 40)
                    .sequenced(before: DragGesture(minimumDistance: 0))
                    .onChanged { value in
                        guard player.duration > 0 else { return }
                        if case .second(true, let drag) = value {
                            if !scrubbing { scrubbing = true; scrubStart = progress; player.beginScrubbing() }
                            if let drag {
                                dragProgress = min(max(scrubStart + drag.translation.width / geo.size.width, 0), 1)
                                let t = Int(dragProgress * 40)
                                if t != tick { tick = t }
                            }
                        }
                    }
                    .onEnded { _ in
                        if scrubbing { player.endScrubbing(to: dragProgress * player.duration) }
                        scrubbing = false
                    }
            )
        }
        .frame(height: 52)
        .glassEffect(.regular, in: .capsule)
        .clipShape(.capsule)
        .scaleEffect(scrubbing ? 1.05 : 1.0)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: scrubbing)
        .sensoryFeedback(trigger: scrubbing) { _, now in now ? .impact(weight: .heavy, intensity: 1.0) : nil }
        .sensoryFeedback(.selection, trigger: tick)
    }

    private func control(_ system: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 28, height: 38)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
