import SwiftUI

/// Now Playing for the TV — ours again, built around two pieces:
///
/// **The centrepiece:** the skeuomorphic cover + slid-out spinning CD with the track title/artist
/// under it (TVNowPlayingArtwork). It owns the remote while focused: LEFT/RIGHT SKIPS the song
/// (with the tuck-in choreography), click toggles play/pause. With a matched music video it docks
/// bottom-left over the video; with a pane (Lyrics / Up Next) open it docks the same way.
///
/// **The playback bar:** a Liquid Glass mini bar along the bottom — previous / play-pause / next,
/// Lyrics + Up Next toggles, and the playhead whose artwork-wash fill IS the progress. Scrubbing
/// happens ONLY there: focus the playhead, then swipe left/right to scrub.
struct TVNowPlayingView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    private var videoCtl: TVVideoController { TVVideoController.shared }
    private var inVideoMode: Bool { videoCtl.activeVideo != nil }

    enum Pane { case lyrics, queue }
    @State private var pane: Pane?

    enum BarCtl: Hashable { case prev, play, next, lyrics, queue, scrub }
    @FocusState private var barFocus: BarCtl?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if videoCtl.direct {
                    // Music Videos playlist: the video IS the content; the bar below drives it.
                    Color.clear
                } else if SessionHub.shared.yieldedToRemote, let remote = SessionHub.shared.remote {
                    remoteMirror(remote)
                } else if let remote = SessionHub.shared.remote, !remote.isPaused, !player.isPlaying {
                    // Another device is ACTIVELY playing and we're not — its live playback outranks
                    // the locally-restored (paused) track.
                    remoteMirror(remote)
                } else if player.currentItem != nil {
                    // The centrepiece: centred for plain audio; docks bottom-left when a music video
                    // is the backdrop OR a pane is open.
                    let docked = inVideoMode || pane != nil
                    ZStack {
                        TVNowPlayingArtwork(coverSize: docked ? 150 : 400,
                                            docked: docked,
                                            onFocusControls: { barFocus = .play })
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: docked ? .bottomLeading : .center)
                            .padding(.leading, docked ? 80 : 0)
                            .padding(.bottom, docked ? 20 : 0)
                            .animation(.spring(response: 0.5, dampingFraction: 0.86), value: docked)

                        if let pane {
                            paneView(pane)
                        }
                    }
                    .animation(.easeInOut(duration: 0.3), value: pane)
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

            // The playback bar — only when THIS device is the one playing.
            if player.currentItem != nil || videoCtl.direct {
                TVPlaybackBar(pane: $pane, focus: $barFocus)
                    .padding(.bottom, 36)
            }
        }
        .onDisappear { pane = nil }   // leaving the tab closes any open pane
        .background {
            ZStack {
                // System theme like the browse pages — the only non-system background here is a
                // playing music video. (Detail views keep their artwork wash.)
                if inVideoMode, let av = videoCtl.avPlayer {
                    TVVideoLayer(player: av).ignoresSafeArea().transition(.opacity)
                }
                // A pane needs contrast over a playing video.
                if pane != nil {
                    Color.black.opacity(0.45).ignoresSafeArea().allowsHitTesting(false)
                }
            }
        }
        // NOTE: video mode is owned by the APP ROOT (MusicTVApp evaluates on track/play changes), not
        // this view — the video keeps playing while you browse; this view just renders the state.
    }

    /// The open pane, centred while the artwork docks bottom-left.
    @ViewBuilder
    private func paneView(_ pane: Pane) -> some View {
        Group {
            switch pane {
            case .lyrics: TVLyricsPane()
            case .queue:  TVQueuePane { self.pane = nil }
            }
        }
        .frame(maxWidth: 1040)
        .frame(maxWidth: .infinity)
        .padding(.top, 40)
        .padding(.bottom, 30)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
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
    }
}

// MARK: - The playback bar (the mini bar, grown into the page's transport)

/// A Liquid Glass capsule bottom-center: previous / play-pause / next, Lyrics + Up Next toggles, and
/// the playhead — a wide capsule whose artwork-wash fill IS the progress. Focus the playhead and
/// swipe left/right to scrub (±5s per pan tick); everywhere else on the page, left/right skips songs.
struct TVPlaybackBar: View {
    @Binding var pane: TVNowPlayingView.Pane?
    var focus: FocusState<TVNowPlayingView.BarCtl?>.Binding

    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    private var videoCtl: TVVideoController { TVVideoController.shared }
    private var scrubbing: Bool { focus.wrappedValue == .scrub }

    var body: some View {
        let direct = videoCtl.direct
        let playing = direct ? !videoCtl.directPaused : player.isPlaying
        let item = direct ? videoCtl.activeVideo : player.currentItem

        HStack(spacing: 14) {
            controlButton(.prev, "backward.fill") {
                if direct { videoCtl.skipDirect(-1, client: client, audio: player) }
                else { player.previousTrack() }
            }
            controlButton(.play, playing ? "pause.fill" : "play.fill") {
                direct ? videoCtl.togglePlayPause() : player.togglePlayPause()
            }
            controlButton(.next, "forward.fill") {
                if direct { videoCtl.skipDirect(+1, client: client, audio: player) }
                else { player.nextTrack() }
            }

            if !direct {
                controlButton(.lyrics, pane == .lyrics ? "quote.bubble.fill" : "quote.bubble") {
                    pane = (pane == .lyrics) ? nil : .lyrics
                }
                .padding(.leading, 10)
                controlButton(.queue, "list.triangle") {
                    pane = (pane == .queue) ? nil : .queue
                }
            }

            // The playhead: elapsed · fill-as-progress · total. Focus it to scrub.
            playhead(direct: direct, item: item)
                .padding(.leading, 14)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .glassEffect(.regular, in: .capsule)
    }

    /// One round transport control: white circle + black glyph when focused, quiet wash otherwise.
    private func controlButton(_ id: TVNowPlayingView.BarCtl, _ icon: String,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(focus.wrappedValue == id ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                .frame(width: 50, height: 50)
                .background(Circle().fill(focus.wrappedValue == id ? AnyShapeStyle(.white)
                                                                   : AnyShapeStyle(.white.opacity(0.10))))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.tvBare)
        .focused(focus, equals: id)
        .animation(.easeOut(duration: 0.12), value: focus.wrappedValue)
    }

    /// The scrub surface. Left/right seeks ONLY while this is focused (the page's left/right skips).
    @ViewBuilder
    private func playhead(direct: Bool, item: MediaItem?) -> some View {
        let videoDur = videoCtl.activeVideo?.durationSeconds ?? 0
        HStack(spacing: 12) {
            Text((direct ? videoCtl.directProgress * videoDur : player.currentTime).formattedDuration)
                .font(.caption2).monospacedDigit()
                .foregroundStyle(scrubbing ? .primary : .secondary)

            GeometryReader { g in
                let frac: Double = direct
                    ? videoCtl.directProgress
                    : (player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    // The artwork wash IS the progress — the app's signature fill. Hard-clipped to
                    // the bar's own frame (an unconstrained aspect-fill image bleeds a tall stripe).
                    if let item {
                        TVArtworkProgressFill(item: item)
                            .frame(width: g.size.width, height: g.size.height)
                            .clipped()
                            .mask(alignment: .leading) {
                                Capsule().frame(width: max(6, g.size.width * frac),
                                                height: g.size.height)
                            }
                    } else {
                        Capsule().fill(.white.opacity(0.8))
                            .frame(width: max(6, g.size.width * frac))
                    }
                }
                .clipShape(Capsule())
            }
            .frame(width: 380, height: scrubbing ? 12 : 7)
            .animation(.easeOut(duration: 0.15), value: scrubbing)

            Text((direct ? videoDur : player.duration).formattedDuration)
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .focusable(!direct)   // the direct video's progress is display-only
        .focused(focus, equals: .scrub)
        .onMoveCommand { dir in
            switch dir {
            case .left:  player.seek(to: max(0, player.currentTime - 5))
            case .right: player.seek(to: min(player.duration, player.currentTime + 5))
            case .up, .down: focus.wrappedValue = .play   // onMoveCommand consumes ALL moves — route out
            @unknown default: break
            }
        }
        .onTapGesture { focus.wrappedValue = .play }
    }
}

/// A blurred wash of the artwork for the playhead fill.
struct TVArtworkProgressFill: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    var body: some View {
        LibraryImage(url: client.artworkURL(for: item, size: 160), maxPixel: 160) { Color(white: 0.6) }
            .aspectRatio(contentMode: .fill)
            .blur(radius: 16, opaque: true)
            .saturation(1.5)
            .brightness(0.15)   // reads as the LIT part of the track
    }
}
