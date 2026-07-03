import SwiftUI

/// Full-screen Now Playing for the TV: big art over a blurred wash, progress, and remote-friendly
/// transport controls. The Siri Remote's play/pause button works from anywhere in the app via the
/// shared Player's remote-command wiring; here it's also wired to the focus context.
struct TVNowPlayingView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    var body: some View {
        ZStack {
            TVBackdrop(item: player.currentItem)

            if let item = player.currentItem {
                HStack(spacing: 80) {
                    LibraryImage(url: client.artworkURL(for: item, size: 800), maxPixel: 800) {
                        TVPlaceholder()
                    }
                    .frame(width: 560, height: 560)
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    .shadow(color: .black.opacity(0.5), radius: 30, y: 14)

                    VStack(alignment: .leading, spacing: 28) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(item.name)
                                .font(.title2).fontWeight(.bold)
                                .lineLimit(2)
                            Text(item.primaryArtist)
                                .font(.title3).foregroundStyle(.secondary)
                            if let album = item.album {
                                Text(album).font(.callout).foregroundStyle(.tertiary)
                            }
                        }

                        // Progress
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: player.duration > 0 ? min(player.currentTime / player.duration, 1) : 0)
                                .tint(.white)
                            HStack {
                                Text(player.currentTime.formattedDuration)
                                Spacer()
                                Text(player.duration.formattedDuration)
                            }
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: 700)

                        HStack(spacing: 40) {
                            Button { player.previousTrack() } label: {
                                Image(systemName: "backward.fill")
                            }
                            Button { player.togglePlayPause() } label: {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            }
                            Button { player.nextTrack() } label: {
                                Image(systemName: "forward.fill")
                            }
                            Button { player.toggleShuffle() } label: {
                                Image(systemName: "shuffle")
                                    .foregroundStyle(player.queue.isShuffled ? .primary : .secondary)
                            }
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(80)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "music.note")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                    Text("Nothing playing")
                        .font(.title3).foregroundStyle(.secondary)
                    Text("Pick an album or playlist to start listening.")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
        .onPlayPauseCommand { player.togglePlayPause() }
    }
}
