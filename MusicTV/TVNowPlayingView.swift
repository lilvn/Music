import SwiftUI

/// Now Playing for the TV — ours again, built around two pieces:
///
/// **The centrepiece:** the skeuomorphic cover + slid-out spinning CD with the track title/artist
/// under it (TVNowPlayingArtwork). It owns the remote while focused: LEFT/RIGHT SKIPS the song
/// (with the tuck-in choreography), click toggles play/pause. With a matched music video it docks
/// bottom-left over the video; with a pane (Lyrics / Up Next) open it docks the same way.
///
/// **The playback bar:** a Liquid Glass mini bar along the bottom — Lyrics | prev/play/next | Up
/// Next, with the artwork gradient filling the capsule AS the progress. HOLD the click on the bar to
/// scrub (it enlarges; left/right drags the playhead; click drops it back down).
struct TVNowPlayingView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    private var videoCtl: TVVideoController { TVVideoController.shared }
    private var inVideoMode: Bool { videoCtl.activeVideo != nil }

    enum Pane { case lyrics, queue }
    @State private var pane: Pane?

    enum BarCtl: Hashable { case prev, play, next, lyrics, queue, scrub }
    @FocusState private var barFocus: BarCtl?

    /// The bar hides after a few idle seconds (nav bar hides natively once focus leaves it) —
    /// only the artwork CD (and a playing video) stay on screen until the remote is touched.
    @State private var barVisible = true
    @State private var barIdle: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if videoCtl.direct {
                    // Music Videos playlist: the video IS the content; the bar below drives it.
                    Color.clear
                } else if SessionHub.shared.yieldedToRemote, let remote = SessionHub.shared.remote {
                    remoteMirror(remote)
                } else if let remote = SessionHub.shared.remote, !remote.isPaused,
                          !player.isPlaying, !videoCtl.matched {
                    // Another device is ACTIVELY playing and we're not — its live playback outranks
                    // the locally-restored (paused) track. (A matched music video IS us playing,
                    // even though the audio Player underneath sits silent.)
                    remoteMirror(remote)
                } else if player.currentItem != nil {
                    // The centrepiece: centred for plain audio; docks bottom-left when a music video
                    // is the backdrop OR a pane is open. Pure visual — never takes focus; the bar
                    // below owns the remote. geometryGroup makes the dock/undock ONE fluid move.
                    let docked = inVideoMode || pane != nil
                    ZStack {
                        // (No geometryGroup here — it froze the TimelineView-driven CD spin on
                        // device; the spring on the frame change animates the dock well enough.)
                        TVNowPlayingArtwork(coverSize: docked ? 150 : 400,
                                            docked: docked,
                                            interactive: false)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: docked ? .bottomLeading : .center)
                            .padding(.leading, docked ? 80 : 0)
                            .padding(.bottom, docked ? 20 : 0)
                            .animation(.spring(response: 0.55, dampingFraction: 0.85), value: docked)

                        if let pane {
                            paneView(pane)
                        }
                    }
                    .animation(.easeInOut(duration: 0.35), value: pane)
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

            // The playback bar — only when THIS device is the one playing, and only until idle.
            if (player.currentItem != nil || videoCtl.direct), barVisible {
                TVPlaybackBar(pane: $pane, focus: $barFocus)
                    .padding(.bottom, 36)
                    // Full-width focus section: ANY downward swipe from the nav bar lands in the
                    // transport, no matter where the buttons sit horizontally.
                    .frame(maxWidth: .infinity)
                    .focusSection()
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: barVisible)
        // The nav bar rests and wakes WITH the playback bar — idle hides all chrome at once.
        .toolbar(barVisible ? .automatic : .hidden, for: .tabBar)
        .onDisappear { pane = nil; barIdle?.cancel() }   // leaving the tab closes any open pane
        .onAppear { bumpBar() }
        // HIGHLIGHTING Lyrics/Up Next opens the pane (no click); landing back on the transport
        // closes it. Focus movement counts as interaction — but focus LEAVING the bar (f == nil,
        // e.g. the idle-hide itself ejecting it) must not, or the bar could never rest.
        .onChange(of: barFocus) { _, f in
            guard f != nil else { return }
            bumpBar()
            switch f {
            case .lyrics: pane = .lyrics
            case .queue:  pane = .queue
            case .prev, .play, .next: pane = nil
            default: break
            }
        }
        .onChange(of: pane) { _, _ in bumpBar() }
        .onChange(of: player.isPlaying) { _, _ in bumpBar() }
        // The remote catcher exists ONLY while the chrome is hidden or a direct video plays.
        // It must never sit on the page container itself: a move-command handler on an ANCESTOR
        // of the focused button intercepts every swipe, making the transport unnavigable.
        .overlay {
            if videoCtl.direct || !barVisible {
                remoteCatcher
            }
        }
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

    /// Invisible focus catcher: wakes hidden chrome on any input, and drives direct-video skipping.
    /// Inserted only while it's needed so it can't shadow normal transport navigation.
    private var remoteCatcher: some View {
        Color.clear
            .contentShape(Rectangle())
            .focusable()
            .onMoveCommand { direction in
                guard barVisible else { bumpBar(focusTransport: true); return }
                // Direct video with the bar up: left/right skip videos; a vertical swipe hands
                // focus to the transport (the catcher itself consumes every move it receives).
                switch direction {
                case .left:  videoCtl.skipDirect(-1, client: client, audio: player)
                case .right: videoCtl.skipDirect(+1, client: client, audio: player)
                case .down, .up: barFocus = .play
                default: break
                }
            }
            .onTapGesture { if !barVisible { bumpBar(focusTransport: true) } }
    }

    /// Show the bar and restart the idle countdown (never hides while a pane is open — its buttons
    /// are the way out).
    private func bumpBar(focusTransport: Bool = false) {
        let wasHidden = !barVisible
        barVisible = true
        // Waking from idle: the catcher held focus and is about to stop being focusable, which
        // ejects focus somewhere arbitrary — land it ON play once the bar is inserted (unconditional:
        // the engine sometimes grabs the lyrics button first, surprise-opening the pane).
        if focusTransport, wasHidden {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                barFocus = .play
            }
        }
        barIdle?.cancel()
        barIdle = Task {
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, pane == nil else { return }
            barVisible = false
        }
    }

    /// The open pane, to the RIGHT of the docked artwork column and clear of the bar below.
    @ViewBuilder
    private func paneView(_ pane: Pane) -> some View {
        Group {
            switch pane {
            case .lyrics: TVLyricsPane()
            case .queue:  TVQueuePane { self.pane = nil }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.leading, 430)    // clear the docked artwork + its label
        .padding(.trailing, 90)
        .padding(.top, 30)
        .padding(.bottom, 130)     // clear the playback bar
        .transition(.opacity)
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

/// A Liquid Glass capsule bottom-center: Lyrics on the left edge, Up Next on the right, the transport
/// centered between them — and NO separate progress bar: the artwork gradient filling the capsule IS
/// the progress. HOLD the click anywhere on the bar to enter scrub mode (it enlarges, left/right
/// drags the playhead, times surface at the ends); click again to drop it back down.
struct TVPlaybackBar: View {
    @Binding var pane: TVNowPlayingView.Pane?
    var focus: FocusState<TVNowPlayingView.BarCtl?>.Binding

    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    private var videoCtl: TVVideoController { TVVideoController.shared }

    /// True while hold-click scrub mode is engaged (the bar enlarges; left/right scrubs).
    @State private var scrubbing = false

    var body: some View {
        let direct = videoCtl.direct
        // Whenever a video owns playback (direct playlist OR the song's matched music video), the
        // transport drives the VIDEO — the audio Player sits silent underneath a matched track.
        let owns = videoCtl.ownsPlayback
        let playing = owns ? !videoCtl.directPaused : player.isPlaying
        let item = direct ? videoCtl.activeVideo : player.currentItem

        ZStack {
            // Lyrics on the LEFT edge, Queue on the RIGHT, transport CENTERED between them.
            HStack {
                if !direct {
                    controlButton(.lyrics, pane == .lyrics ? "quote.bubble.fill" : "quote.bubble") {
                        pane = (pane == .lyrics) ? nil : .lyrics
                    }
                }

                Spacer(minLength: 0)

                HStack(spacing: 16) {
                    controlButton(.prev, "backward.fill") {
                        if direct { videoCtl.skipDirect(-1, client: client, audio: player) }
                        else { player.previousTrack() }
                    }
                    controlButton(.play, playing ? "pause.fill" : "play.fill") {
                        owns ? videoCtl.togglePlayPause() : player.togglePlayPause()
                    }
                    controlButton(.next, "forward.fill") {
                        if direct { videoCtl.skipDirect(+1, client: client, audio: player) }
                        else { player.nextTrack() }
                    }
                }

                Spacer(minLength: 0)

                if !direct {
                    controlButton(.queue, "list.triangle") {
                        pane = (pane == .queue) ? nil : .queue
                    }
                }
            }
            .opacity(scrubbing ? 0.25 : 1)   // the bar itself becomes the scrubber
        }
        .frame(width: 620)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        // NO separate progress bar: the iOS mini bar's language — the artwork gradient fills the
        // WHOLE bar left→right as the track plays (and is what you drag in scrub mode).
        .background(alignment: .leading) {
            if let item {
                GeometryReader { g in
                    let frac: Double = owns
                        ? videoCtl.directProgress
                        : (player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0)
                    TVBarFill(item: item)
                        .frame(width: g.size.width, height: g.size.height)
                        .clipped()
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(0, g.size.width * frac), height: g.size.height)
                        }
                        .animation(.linear(duration: 0.5), value: frac)
                }
                .allowsHitTesting(false)
            }
        }
        .clipShape(Capsule())
        .glassEffect(.regular, in: .capsule)
        // Scrub-mode catcher: exists only while scrubbing, covers the whole bar — every left/right
        // pan tick drags the playhead; CLICK (or up/down) drops it back down to the controls.
        .overlay {
            if scrubbing {
                Color.clear
                    .contentShape(Capsule())
                    .focusable(true)
                    .focused(focus, equals: .scrub)
                    .onMoveCommand { dir in
                        switch dir {
                        case .left:  player.seek(to: max(0, player.currentTime - 5))
                        case .right: player.seek(to: min(player.duration, player.currentTime + 5))
                        case .up, .down: exitScrub()
                        @unknown default: break
                        }
                    }
                    .onTapGesture { exitScrub() }
                    .onExitCommand { exitScrub() }
            }
        }
        .scaleEffect(scrubbing ? 1.12 : 1.0)   // HOLD-click anywhere on the bar → it grows to scrub
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: scrubbing)
        .onChange(of: focus.wrappedValue) { _, f in
            if scrubbing, f != .scrub { scrubbing = false }   // focus escaped some other way
        }
    }

    private func enterScrub() {
        // No scrub while a video owns playback — its AVPlayer isn't the audio Player's timeline.
        guard !videoCtl.ownsPlayback, player.duration > 0 else { return }
        scrubbing = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))   // let the catcher join the hierarchy
            focus.wrappedValue = .scrub
        }
    }

    private func exitScrub() {
        scrubbing = false
        focus.wrappedValue = .play
    }

    /// One transport control: a bare glyph that ENLARGES when focused (no circle platter).
    /// HOLDING the click on any of them engages scrub mode (the release is swallowed by the guard).
    private func controlButton(_ id: TVNowPlayingView.BarCtl, _ icon: String,
                               action: @escaping () -> Void) -> some View {
        let focused = focus.wrappedValue == id
        return Button {
            guard !scrubbing else { return }   // the click-up that ends a hold isn't a press
            action()
        } label: {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(.primary.opacity(focused ? 1 : 0.65))
                .frame(width: 50, height: 50)
                .contentShape(Rectangle())
                .contentTransition(.symbolEffect(.replace))
                .scaleEffect(focused ? 1.45 : 1.0)
        }
        .buttonStyle(.tvBare)
        .focused(focus, equals: id)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in enterScrub() }
        )
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: focused)
    }
}

/// The artwork blurred into a colour wash — the bar's progress fill, toned exactly like the iOS
/// mini bar's ArtworkGradient so the two read as the same surface.
struct TVBarFill: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    var body: some View {
        LibraryImage(url: client.artworkURL(for: item, size: 160), maxPixel: 160) { Color(white: 0.2) }
            .aspectRatio(contentMode: .fill)
            .blur(radius: 24, opaque: true)
            .saturation(1.4)
            .overlay(Color.black.opacity(0.28))   // keep the white controls/text legible over it
    }
}

// MARK: - The compact mini bar (every page EXCEPT Now Playing)

/// The playback bar, compressed into the bottom-left corner while browsing: spinning CD + track
/// title/artist with the artwork gradient filling the capsule as the live progress — it "expands"
/// back into the full transport when you enter Now Playing. Pure chrome, never focusable. Mirrors
/// remote sessions seamlessly (artist line, live-extrapolated fill).
struct TVCompactNowPlaying: View {
    @Environment(Player.self) private var player
    @State private var width: CGFloat = 1

    private struct Model {
        let item: MediaItem
        let sub: String?
        let spinning: Bool
        let remote: SessionHub.RemoteSession?
    }

    private var model: Model? {
        let videoCtl = TVVideoController.shared
        if videoCtl.direct, let video = videoCtl.activeVideo {
            return Model(item: video, sub: video.primaryArtist, spinning: !videoCtl.directPaused, remote: nil)
        }
        // A matched music video owns playback: the SONG stays the identity, the video drives state.
        if videoCtl.matched, let item = player.currentItem {
            return Model(item: item, sub: item.primaryArtist, spinning: !videoCtl.directPaused, remote: nil)
        }
        if let r = SessionHub.shared.remote, !r.isPaused, !player.isPlaying {
            return Model(item: r.item, sub: r.item.primaryArtist, spinning: true, remote: r)
        }
        if let item = player.currentItem {
            return Model(item: item, sub: item.primaryArtist, spinning: player.isPlaying, remote: nil)
        }
        if let r = SessionHub.shared.remote {
            return Model(item: r.item, sub: r.item.primaryArtist, spinning: !r.isPaused, remote: r)
        }
        return nil
    }

    private func progress(at date: Date, _ m: Model) -> Double {
        if let r = m.remote {
            let dur = max(r.durationSeconds, 1)
            return min(max(r.livePosition(at: date) / dur, 0), 1)
        }
        let ctl = TVVideoController.shared
        if ctl.ownsPlayback { return ctl.directProgress }
        return player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
    }

    var body: some View {
        if let m = model {
            HStack(spacing: 12) {
                TVSpinningDisc(item: m.item, size: 38, spinning: m.spinning)
                VStack(alignment: .leading, spacing: 1) {
                    Text(m.item.name).font(.caption).fontWeight(.semibold).lineLimit(1)
                    if let sub = m.sub, !sub.isEmpty {
                        Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: 260, alignment: .leading)
            }
            .padding(.leading, 8)
            .padding(.trailing, 18)
            .padding(.vertical, 7)
            // The artwork gradient fill IS the progress — live (extrapolated for remote sessions).
            .background(alignment: .leading) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    TVBarFill(item: m.item)
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(0, width * progress(at: ctx.date, m)))
                        }
                }
                .allowsHitTesting(false)
            }
            .background {
                GeometryReader { g in
                    Color.clear.onChange(of: g.size.width, initial: true) { _, w in width = w }
                }
            }
            .clipShape(Capsule())
            .glassEffect(.regular, in: .capsule)
        }
    }
}
