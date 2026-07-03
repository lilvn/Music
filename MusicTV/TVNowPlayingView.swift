import SwiftUI

/// Now Playing for the TV — the skeuomorphic centrepiece.
///
/// **Audio mode:** the queue as a big centered cover-flow carousel (3D covers, the current track's CD
/// slid out and spinning, reflection below) over the artwork wash, with minimal glass chrome for the
/// track info and progress.
///
/// **Video mode:** when the library has a music video for the current song, playback switches to the
/// video (its own audio) — the video fills the screen and the carousel docks to the bottom like a dock.
struct TVNowPlayingView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    private var videoCtl: TVVideoController { TVVideoController.shared }
    private var inVideoMode: Bool { videoCtl.activeVideo != nil }

    var body: some View {
        ZStack {
            // ----- Backdrop: the music video, or the artwork wash -----
            if inVideoMode, let av = videoCtl.avPlayer {
                TVVideoLayer(player: av)
                    .ignoresSafeArea()
                    .transition(.opacity)
            } else {
                TVBackdrop(item: player.currentItem ?? SessionHub.shared.remote?.item)
            }

            if inVideoMode {
                // Video fills the screen; the mini-bar band (mounted at the app root) captions it at
                // the bottom. Nothing else here.
                Color.clear
            } else if player.currentItem != nil {
                // ----- The skeuomorphic centrepiece: cover + CD + reflection, playhead below. Lifted
                // above the bottom mini-bar band so the track sits in the middle. -----
                VStack(spacing: 8) {
                    TVNowPlayingArtwork(coverSize: 400)
                    progressBar
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.bottom, 220)   // clear the mini-bar band
                .transition(.opacity)
            } else if let remote = SessionHub.shared.remote {
                // Another device of this account is playing — mirror it and offer remote control.
                remoteMirror(remote)
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
        .toolbar(.hidden, for: .tabBar)   // hide the top tab bar on Now Playing (swipe up to reveal)
        // Siri Remote play/pause: the direct playlist toggles the video (it's the sound); everything
        // else toggles the audio Player (a matched backdrop follows via setPlaying).
        .onPlayPauseCommand {
            videoCtl.direct ? videoCtl.togglePlayPause() : player.togglePlayPause()
        }
        // Video mode: the screen itself takes focus so trackpad swipes skip — between playlist videos
        // (direct) or between queue tracks (matched).
        .focusable(inVideoMode)
        .onMoveCommand { direction in
            guard inVideoMode else { return }
            let delta: Int
            switch direction {
            case .left: delta = -1
            case .right: delta = +1
            default: return
            }
            if videoCtl.direct {
                videoCtl.skipDirect(delta, client: client, audio: player)
            } else {
                let next = player.queue.currentIndex + delta
                if player.queue.items.indices.contains(next) { player.play(at: next) }
            }
        }
        // NOTE: video mode is owned by the APP ROOT (MusicTVApp evaluates on track/play changes), not
        // this view — so the video keeps playing in the background when you browse other pages. This
        // view only renders the current state; the fullscreen layer reattaches when you come back.
    }

    // MARK: - Chrome (minimal liquid glass)

    /// The playhead, sitting right under the carousel.
    private var progressBar: some View {
        VStack(spacing: 8) {
            ProgressView(value: player.duration > 0 ? min(player.currentTime / player.duration, 1) : 0)
                .tint(.white)
            HStack {
                Text(player.currentTime.formattedDuration)
                Spacer()
                Text(player.duration.formattedDuration)
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 14)
        .frame(width: 640)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 22))
    }

    /// Mirror of a remote session: its artwork + track, with controls that drive THAT device.
    private func remoteMirror(_ remote: SessionHub.RemoteSession) -> some View {
        HStack(spacing: 80) {
            LibraryImage(url: client.artworkURL(for: remote.item, size: 800), maxPixel: 800) {
                TVPlaceholder()
            }
            .frame(width: 480, height: 480)
            .clipShape(RoundedRectangle(cornerRadius: TVDS.artwork, style: .continuous))
            .shadow(color: .black.opacity(0.5), radius: 30, y: 14)

            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Playing on \(remote.deviceName)", systemImage: "airplayaudio")
                        .font(.callout).foregroundStyle(.secondary)
                    Text(remote.item.name)
                        .font(.title2).fontWeight(.bold).lineLimit(2)
                    Text(remote.item.primaryArtist)
                        .font(.title3).foregroundStyle(.secondary)
                }

                HStack(spacing: 40) {
                    Button { SessionHub.shared.previousRemote() } label: {
                        Image(systemName: "backward.fill")
                    }
                    Button { SessionHub.shared.playPauseRemote() } label: {
                        Image(systemName: remote.isPaused ? "play.fill" : "pause.fill")
                    }
                    Button { SessionHub.shared.nextRemote() } label: {
                        Image(systemName: "forward.fill")
                    }
                }
                .buttonStyle(.borderless)

                Button { SessionHub.shared.transferHere() } label: {
                    Label("Play on this TV", systemImage: "tv")
                }
                .disabled(SessionHub.shared.transferring)
            }
        }
        .padding(80)
    }
}
