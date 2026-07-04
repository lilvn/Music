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

    // The playhead footer fades out after a few idle seconds (like a tvOS transport) and returns on any
    // remote input, track change, or play/pause.
    @State private var footerVisible = true
    @State private var footerIdle: Task<Void, Never>?

    // The transport buttons in the footer block. While one is focused the footer must NOT auto-hide —
    // removing a focused view makes the tvOS focus engine jump unpredictably (usually to the tab bar).
    private enum ControlButton: Hashable { case previous, playPause, next, lyrics, queue }
    @FocusState private var controlFocus: ControlButton?

    /// The open side pane. While one is showing the artwork docks bottom-left (like video mode) and
    /// the pane fills the centre.
    private enum NPPane { case lyrics, queue }
    @State private var pane: NPPane?

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
                } else if SessionHub.shared.yieldedToRemote, let remote = SessionHub.shared.remote {
                    // Another device took over playback (exclusive-playback rule) — mirror it.
                    remoteMirror(remote)
                } else if let remote = SessionHub.shared.remote, !remote.isPaused, !player.isPlaying {
                    // Another device is ACTIVELY playing and we're not — its live playback outranks
                    // the locally-restored (paused) track.
                    remoteMirror(remote)
                } else if player.currentItem != nil {
                    // The skeuomorphic cover-flow carousel: cover + CD + reflection. Centred for plain
                    // audio; when a music video is the backdrop OR a pane (lyrics/queue) is open it
                    // shrinks and DOCKS bottom-left. Only the DOCK moves — the footer stays put.
                    let docked = inVideoMode || pane != nil
                    ZStack {
                        TVNowPlayingArtwork(coverSize: docked ? 150 : 400, docked: docked,
                                            onInteract: bumpFooter,
                                            onFocusControls: focusControls)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: docked ? .bottomLeading : .center)
                            .padding(.leading, docked ? 80 : 0)
                            .padding(.bottom, docked ? 24 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.86), value: docked)

                        if let pane {
                            paneView(pane)
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: pane)
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

            // The transport block — playback controls + playhead footer, pinned to the bottom. On idle
            // it slides DOWN and out of the layout (not just fades) so the content above — the
            // bottom-left docked artwork — drops into its place. Returns on interaction.
            if (player.currentItem != nil || videoCtl.direct), footerVisible {
                VStack(spacing: 20) {
                    controlsRow
                    progressFooter
                }
                // A focus SECTION: swiping down from anywhere above (the carousel, a pane) reliably
                // lands in the transport, without depending on exact button geometry.
                .focusSection()
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.4), value: footerVisible)
        .onAppear(perform: bumpFooter)
        .onDisappear { footerIdle?.cancel() }
        // Track change and play/pause both bring the bar back; keep it while a button holds focus.
        .onChange(of: player.currentItem?.id) { _, _ in bumpFooter() }
        .onChange(of: player.isPlaying) { _, _ in bumpFooter() }
        .onChange(of: controlFocus) { _, _ in bumpFooter() }
        .onChange(of: pane) { _, _ in bumpFooter() }
        .onDisappear { pane = nil }   // leaving the tab closes any open pane
        .background {
            ZStack {
                if inVideoMode, let av = videoCtl.avPlayer {
                    TVVideoLayer(player: av).ignoresSafeArea().transition(.opacity)
                } else {
                    // The artwork blurred into a colour wash — Now Playing and the detail views are
                    // the only artwork-tinted pages; browse pages stay system-theme.
                    TVBackdrop(item: player.currentItem ?? SessionHub.shared.remote?.item)
                }
                // A pane needs contrast over whatever's behind (especially a playing video).
                if pane != nil {
                    Color.black.opacity(0.45).ignoresSafeArea().allowsHitTesting(false)
                }
            }
        }
        // The tab bar stays visible here like every other page (play/pause is handled globally at the
        // root, so it works no matter where focus is).
        // Only the Music Videos PLAYLIST needs the screen to take focus (no carousel then) — for audio
        // and matched-video the docked carousel owns focus and skips tracks itself.
        .focusable(videoCtl.direct)
        .onMoveCommand { direction in
            bumpFooter()
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

    /// Show the footer and restart the idle countdown. Called on appear and on every remote input,
    /// track change, and play/pause. Never hides while a transport button is focused — pulling a
    /// focused view out of the hierarchy sends tvOS focus somewhere arbitrary.
    private func bumpFooter() {
        footerVisible = true
        footerIdle?.cancel()
        footerIdle = Task {
            try? await Task.sleep(for: .seconds(4))
            // Never hide while a button holds focus or a pane is open (the buttons are its way out).
            if !Task.isCancelled, controlFocus == nil, pane == nil { footerVisible = false }
        }
    }

    /// Swiping DOWN from the carousel lands on the transport: make sure the block is on screen first,
    /// then hand focus to the play/pause button once the insertion has settled (a same-runloop
    /// assignment can silently fail while the `if footerVisible` block is still being committed).
    private func focusControls() {
        bumpFooter()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            controlFocus = .playPause
        }
    }

    // MARK: - Chrome (minimal liquid glass)

    /// Previous / play-pause / next as Liquid Glass buttons. Direct (Music Videos playlist) drives the
    /// video controller; everything else the audio Player. Every press restarts the idle countdown.
    private var controlsRow: some View {
        let direct = videoCtl.direct
        return HStack(spacing: 40) {
            Button {
                bumpFooter()
                if direct { videoCtl.skipDirect(-1, client: client, audio: player) }
                else { player.previousTrack() }   // restart-if->5s, the standard transport semantic
            } label: {
                Image(systemName: "backward.fill").font(.title3)
            }
            .focused($controlFocus, equals: .previous)

            Button {
                bumpFooter()
                direct ? videoCtl.togglePlayPause() : player.togglePlayPause()
            } label: {
                Image(systemName: (direct ? !videoCtl.directPaused : player.isPlaying) ? "pause.fill" : "play.fill")
                    .font(.title2)
                    .contentTransition(.symbolEffect(.replace))
            }
            .focused($controlFocus, equals: .playPause)

            Button {
                bumpFooter()
                if direct { videoCtl.skipDirect(+1, client: client, audio: player) }
                else { player.nextTrack() }
            } label: {
                Image(systemName: "forward.fill").font(.title3)
            }
            .focused($controlFocus, equals: .next)
            .disabled(!direct && !player.canGoNext)

            // Lyrics / Queue panes — audio + matched-video only (the direct playlist has no
            // audio queue, and its video IS the content).
            if !direct {
                Button {
                    bumpFooter()
                    pane = (pane == .lyrics) ? nil : .lyrics
                } label: {
                    Image(systemName: pane == .lyrics ? "quote.bubble.fill" : "quote.bubble").font(.title3)
                }
                .focused($controlFocus, equals: .lyrics)
                .padding(.leading, 24)

                Button {
                    bumpFooter()
                    pane = (pane == .queue) ? nil : .queue
                } label: {
                    Image(systemName: "list.triangle").font(.title3)
                }
                .focused($controlFocus, equals: .queue)
            }
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
    }

    /// The open pane, centred in the free area while the artwork docks bottom-left. Bottom padding
    /// keeps its content clear of the docked cover + reflection.
    @ViewBuilder
    private func paneView(_ pane: NPPane) -> some View {
        Group {
            switch pane {
            case .lyrics: TVLyricsPane()
            case .queue:  TVQueuePane { self.pane = nil }
            }
        }
        .frame(maxWidth: 1040)
        .frame(maxWidth: .infinity)
        .padding(.top, 30)
        .padding(.bottom, 210)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

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

                // LIVE playhead — extrapolated between session polls, so it moves in real time.
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let dur = max(remote.durationSeconds, 1)
                    let pos = min(remote.livePosition(at: ctx.date), dur)
                    VStack(spacing: 6) {
                        ProgressView(value: pos / dur)
                        HStack {
                            Text(pos.formattedDuration)
                            Spacer()
                            Text(dur.formattedDuration)
                        }
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 560)

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

                if remote.item.type != "MusicVideo" {   // a video can't transfer as local audio
                    Button { SessionHub.shared.transferHere() } label: {
                        Label("Play on this TV", systemImage: "tv")
                    }
                    .disabled(SessionHub.shared.transferring)
                }
            }
        }
        .padding(80)
    }
}
