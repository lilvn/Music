import SwiftUI

/// Now Playing for the TV — the NATIVE system player (AVPlayerViewController: real scrubber, real
/// swipe-down Lyrics / Up Next panels) with our skeuomorphic CD + music-video visuals riding its
/// content overlay. See TVNativePlayer. Remote sessions mirror seamlessly with the same centrepiece.
struct TVNowPlayingView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    private var videoCtl: TVVideoController { TVVideoController.shared }

    var body: some View {
        Group {
            if SessionHub.shared.yieldedToRemote, let remote = SessionHub.shared.remote {
                remoteMirror(remote)
            } else if let remote = SessionHub.shared.remote, !remote.isPaused, !player.isPlaying {
                // Another device is ACTIVELY playing and we're not — its live playback outranks
                // the locally-restored (paused) track.
                remoteMirror(remote)
            } else if player.currentItem != nil || videoCtl.direct {
                TVNativePlayer()
                    .ignoresSafeArea()
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
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background { TVBackdrop(item: nil) }
            }
        }
    }

    /// A remote session's Now Playing — SEAMLESS: the SAME skeuomorphic centrepiece as local playback,
    /// with the Transfer button beneath it as the one tell (and the one focusable thing on the page).
    private func remoteMirror(_ remote: SessionHub.RemoteSession) -> some View {
        VStack(spacing: 40) {
            TVFlowCover(item: remote.item,
                        size: 400,
                        discOut: true,
                        spinning: !remote.isPaused,
                        showReflection: true,
                        emphasized: true)
            TransferButton()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { TVBackdrop(item: remote.item) }
    }
}
