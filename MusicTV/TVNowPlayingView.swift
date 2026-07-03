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
                Group {
                    if !inVideoMode {
                        // ----- The skeuomorphic centrepiece: cover + CD + reflection, playhead below -----
                        VStack(spacing: 8) {
                            TVNowPlayingArtwork(coverSize: 400)
                            progressBar
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(.opacity)
                    } else {
                        // ----- Video mode: the artwork shrinks into a bottom-left "channel bug" -----
                        videoCornerBug
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .bottomLeading)
                            .padding(.leading, 70)
                            .padding(.bottom, 60)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
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

    // MARK: - Video "channel bug" (bottom-left, old-school music-video-channel style)

    /// The item whose info the bug shows: the song (matched mode) or the video itself (direct mode).
    private var bugItem: MediaItem? {
        videoCtl.direct ? videoCtl.activeVideo : player.currentItem
    }

    /// Small cover + CD in the corner over a black gradient panel, with track / artist / album to the
    /// right — the way skeuomorphic music-video channels captioned what was on.
    private var videoCornerBug: some View {
        HStack(spacing: 28) {
            if let bugItem {
                TVFlowCover(item: bugItem, size: 150,
                            discOut: true, spinning: true, showReflection: false)
                    .padding(.trailing, 26)   // room for the slid-out disc

                VStack(alignment: .leading, spacing: 5) {
                    Text(bugItem.name)
                        .font(.headline)
                        .lineLimit(1)
                    Text(bugItem.primaryArtist)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    if let album = bugItem.album, !album.isEmpty {
                        Text(album)
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.vertical, 24)
        .padding(.leading, 24)
        .padding(.trailing, 44)
        .background {
            // Black gradient panel fading to the right, like an old channel lower-third.
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [.black.opacity(0.88), .black.opacity(0.30)],
                                     startPoint: .leading, endPoint: .trailing))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(.white.opacity(0.12), lineWidth: 0.5)
                )
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
