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
        // VStack, NOT a ZStack: the fixed footer is the bottom row and the moving carousel fills the row
        // above it, so the footer is always on-screen. (A bottom-aligned child of a ZStack whose backdrop
        // ignoresSafeArea gets pushed off the visible bottom.) The backdrop is a full-bleed `.background`
        // so the video still fills the screen behind the footer.
        VStack(spacing: 0) {
            Group {
                if videoCtl.direct {
                    // Music Videos playlist: the video IS the content (its own audio). No audio carousel.
                    Color.clear
                } else if player.currentItem != nil {
                    // The skeuomorphic cover-flow carousel: cover + CD + reflection with the prev/next
                    // tracks flanking it. Centred for plain audio; when a music video is the backdrop it
                    // shrinks and DOCKS toward the footer. Only the DOCK moves — the footer stays put.
                    let docked = inVideoMode
                    TVNowPlayingArtwork(coverSize: docked ? 150 : 400)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: docked ? .bottom : .center)
                        .padding(.bottom, docked ? 24 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: docked)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // The fixed full-width playhead footer.
            if player.currentItem != nil || videoCtl.direct { progressFooter }
        }
        .background {
            if inVideoMode, let av = videoCtl.avPlayer {
                TVVideoLayer(player: av).ignoresSafeArea().transition(.opacity)
            } else {
                TVBackdrop(item: player.currentItem ?? SessionHub.shared.remote?.item)
            }
        }
        // The tab bar stays visible here like every other page (play/pause is handled globally at the
        // root, so it works no matter where focus is).
        // Only the Music Videos PLAYLIST needs the screen to take focus (no carousel then) — for audio
        // and matched-video the docked carousel owns focus and skips tracks itself.
        .focusable(videoCtl.direct)
        .onMoveCommand { direction in
            guard videoCtl.direct else { return }
            switch direction {
            case .left:  videoCtl.skipDirect(-1, client: client, audio: player)
            case .right: videoCtl.skipDirect(+1, client: client, audio: player)
            default: break
            }
        }
        // NOTE: video mode is owned by the APP ROOT (MusicTVApp evaluates on track/play changes), not
        // this view — so the video keeps playing in the background when you browse other pages. This
        // view only renders the current state; the fullscreen layer reattaches when you come back.
    }

    // MARK: - Chrome (minimal liquid glass)

    /// The playhead as a fixed full-width footer pinned to the bottom of the screen — the default tvOS
    /// progress bar, spanning the width like a footer. Stays put while the carousel/dock moves above it.
    private var progressFooter: some View {
        let direct = videoCtl.direct
        return VStack(spacing: 6) {
            ProgressView(value: playFraction)
            if !direct {
                HStack {
                    Text(player.currentTime.formattedDuration)
                    Spacer()
                    Text(player.duration.formattedDuration)
                }
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 80)
        .padding(.bottom, 40)
        .frame(maxWidth: .infinity)
    }

    private var playFraction: Double {
        if videoCtl.direct { return videoCtl.directProgress }
        return player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
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
