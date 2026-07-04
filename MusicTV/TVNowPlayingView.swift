import SwiftUI

/// Shared Now Playing chrome state — cinema mode (nav bar hides while a video plays and the remote
/// is idle).
@MainActor
@Observable
final class TVNowPlayingUI {
    static let shared = TVNowPlayingUI()

    /// While a music video plays and the remote is idle, the nav bar hides (cinema mode) — any
    /// interaction brings it back. `chromeVisible` only ever goes false while a video is active.
    private(set) var chromeVisible = true
    @ObservationIgnored private var chromeIdle: Task<Void, Never>?

    /// Show the chrome and restart the idle countdown. Call on ANY remote interaction. The hide only
    /// fires if a video is still playing when the countdown lands (audio-only never hides the bar).
    func bumpChrome() {
        chromeVisible = true
        chromeIdle?.cancel()
        chromeIdle = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if TVVideoController.shared.activeVideo != nil { chromeVisible = false }
        }
    }

    private init() {}
}

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

    /// A remote session's Now Playing — SEAMLESS: the SAME skeuomorphic centrepiece as local playback.
    /// The nav bar's Transfer pill is the only tell; play/pause & skips ride the root's global handler
    /// and the sessions API.
    private func remoteMirror(_ remote: SessionHub.RemoteSession) -> some View {
        TVFlowCover(item: remote.item,
                    size: 400,
                    discOut: true,
                    spinning: !remote.isPaused,
                    showReflection: true,
                    emphasized: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { TVBackdrop(item: remote.item) }
    }
}
