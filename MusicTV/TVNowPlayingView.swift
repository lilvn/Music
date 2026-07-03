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

            if player.currentItem != nil || inVideoMode {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    if !inVideoMode {
                        // ----- Centered: the carousel (names under the covers) with the playhead below -----
                        TVQueueCarousel(coverSize: 340, showReflection: true)
                        progressBar
                            .padding(.top, 8)
                        Spacer(minLength: 0)
                    } else if !videoCtl.direct {
                        // ----- Matched-video mode: the carousel docks to the bottom over the video -----
                        TVQueueCarousel(coverSize: 150, showReflection: false)
                        Color.clear.frame(height: 8)
                    }
                    // Direct video playback (the Music Videos playlist): clean fullscreen, no dock.
                }
                .animation(.spring(response: 0.6, dampingFraction: 0.85), value: inVideoMode)
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
        // Siri Remote play/pause drives whichever engine is live.
        .onPlayPauseCommand {
            inVideoMode ? videoCtl.togglePlayPause() : player.togglePlayPause()
        }
        // Direct video playback: with the carousel hidden, the screen itself takes focus so trackpad
        // swipes skip between videos in the playlist.
        .focusable(videoCtl.direct)
        .onMoveCommand { direction in
            guard videoCtl.direct else { return }
            switch direction {
            case .left:  videoCtl.skipDirect(-1, client: client, audio: player)
            case .right: videoCtl.skipDirect(+1, client: client, audio: player)
            default: break
            }
        }
        .task {
            await videoCtl.loadLibrary(client: client)
            reevaluateVideo()   // the library may load AFTER onAppear's evaluation — re-check
        }
        // The current track changed (carousel click, queue advance, video ended) — switch between
        // audio and video presentation to match it.
        .onChange(of: player.currentItem?.id) { _, _ in reevaluateVideo() }
        .onAppear { reevaluateVideo() }
        // Leaving Now Playing hands playback back to the audio queue (a direct video playlist just
        // stops — don't blast paused audio at someone who was watching videos).
        .onDisappear {
            videoCtl.exit(audio: player, resumeAudio: player.currentItem != nil && !videoCtl.direct)
        }
    }

    /// Enter video mode when the current song has a library music video; exit (resuming audio) when
    /// it doesn't. Direct playback (the Music Videos playlist) is driven by the controller, not the
    /// audio queue — leave it alone.
    private func reevaluateVideo() {
        guard !videoCtl.direct else { return }
        guard let song = player.currentItem else {
            videoCtl.exit(audio: player, resumeAudio: false)
            return
        }
        if let video = videoCtl.videoMatching(song) {
            videoCtl.enter(video: video, client: client, audio: player)
        } else {
            videoCtl.exit(audio: player, resumeAudio: true)
        }
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
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
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
