import SwiftUI

/// Content of the `tabViewBottomAccessory`. Shows the current track with a spinning CD thumb and
/// transport; tapping the track opens the full Now Playing (zoom-expanding from here). Renders
/// nothing when idle so the accessory collapses. Reads the placement for an inline-vs-expanded layout.
struct MiniPlayer: View {
    let namespace: Namespace.ID
    @Environment(Player.self) private var player
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement

    var body: some View {
        if let item = player.currentItem {
            content(for: item)
                .matchedTransitionSource(id: "np", in: namespace)
        }
    }

    @ViewBuilder
    private func content(for item: MediaItem) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 11) {
                SpinningDisc(artURL: artURL(item), size: 36, spinning: player.isPlaying)
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

    @Environment(JellyfinClient.self) private var client
    private func artURL(_ item: MediaItem) -> URL? { client.artworkURL(for: item, size: 120) }
}
