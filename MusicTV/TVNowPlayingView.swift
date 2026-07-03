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

            if player.currentItem != nil {
                VStack(spacing: 0) {
                    if !inVideoMode {
                        trackInfo
                            .padding(.top, 30)
                        Spacer(minLength: 0)
                    } else {
                        Spacer(minLength: 0)
                    }

                    // ----- The skeuomorphic carousel: centered when listening, docked over the video -----
                    TVQueueCarousel(coverSize: inVideoMode ? 150 : 340,
                                    showReflection: !inVideoMode)

                    if !inVideoMode {
                        Spacer(minLength: 0)
                        progressBar
                            .padding(.bottom, 40)
                    } else {
                        // Dock hugs the bottom edge.
                        Color.clear.frame(height: 8)
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
        .task {
            await videoCtl.loadLibrary(client: client)
            reevaluateVideo()   // the library may load AFTER onAppear's evaluation — re-check
        }
        // The current track changed (carousel click, queue advance, video ended) — switch between
        // audio and video presentation to match it.
        .onChange(of: player.currentItem?.id) { _, _ in reevaluateVideo() }
        .onAppear { reevaluateVideo() }
        // Leaving Now Playing hands playback back to the audio queue.
        .onDisappear { videoCtl.exit(audio: player, resumeAudio: player.currentItem != nil) }
    }

    /// Enter video mode when the current song has a library music video; exit (resuming audio) when
    /// it doesn't.
    private func reevaluateVideo() {
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

    private var trackInfo: some View {
        VStack(spacing: 6) {
            Text(player.currentItem?.name ?? "")
                .font(.title3).fontWeight(.bold)
                .lineLimit(1)
            Text(player.currentItem?.primaryArtist ?? "")
                .font(.callout).foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 36)
        .padding(.vertical, 18)
        .background(.ultraThinMaterial, in: .capsule)
    }

    private var progressBar: some View {
        VStack(spacing: 10) {
            ProgressView(value: player.duration > 0 ? min(player.currentTime / player.duration, 1) : 0)
                .tint(.white)
            HStack {
                Text(player.currentTime.formattedDuration)
                Spacer()
                Text(player.duration.formattedDuration)
            }
            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
        .frame(width: 760)
        .background(.ultraThinMaterial, in: .rect(cornerRadius: 24))
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
