import SwiftUI

// The tvOS port of the app's ONE bespoke element: the skeuomorphic iTunes-style cover flow, here as
// the Now Playing queue carousel. 3D-rotated covers, the current track's cover slides aside with a
// reflective spinning CD pulled out, and a faded reflection below — same visual language and geometry
// as the iPhone's Featured shelf (CoverFlow.swift), rebuilt focus-first for the 10-foot UI.

// MARK: - Spinning CD

struct TVSpinningDisc: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    let size: CGFloat
    let spinning: Bool

    // Same geometry + speed as the iPhone disc, so the two feel like the same object.
    static let diameterRatio: CGFloat = 0.9
    static let pullOutRatio: CGFloat = 0.3
    static let spinSpeed: Double = 48   // degrees / second

    @State private var base: Double = 0
    @State private var ref: Date?

    private var artURL: URL? { client.artworkURL(for: item, size: 400) }

    var body: some View {
        // Branch instead of `.animation(paused:)`: a paused animation TimelineView didn't render at
        // all on tvOS in testing — the still disc draws directly, the TimelineView only while spinning.
        Group {
            if spinning {
                TimelineView(.animation) { context in
                    disc.rotationEffect(.degrees(angle(at: context.date)))
                }
            } else {
                disc.rotationEffect(.degrees(base))
            }
        }
        .onAppear { reconcile(Date()) }
        .onChange(of: spinning) { _, _ in reconcile(Date()) }
    }

    private func angle(at date: Date) -> Double {
        if spinning, let ref { return base + date.timeIntervalSince(ref) * Self.spinSpeed }
        return base
    }

    /// Fold elapsed rotation into `base` when the spin starts/stops so the angle never jumps.
    private func reconcile(_ now: Date) {
        if spinning, ref == nil {
            ref = now
        } else if !spinning, let r = ref {
            base += now.timeIntervalSince(r) * Self.spinSpeed
            ref = nil
        }
    }

    private var disc: some View {
        let rim = max(0.5, size * 0.012)
        return ZStack {
            // Disc body: the artwork blurred into a soft colour wash (the TV equivalent of
            // ArtworkGradient, which lives in the iOS-only Components file).
            LibraryImage(url: artURL, maxPixel: 200) { Color(white: 0.16) }
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .blur(radius: size * 0.14, opaque: true)
                .saturation(1.4)
                .clipShape(Circle())

            // Doming + edge vignette so it reads as a physical disc.
            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: .white.opacity(0.22), location: 0.0),
                    .init(color: .white.opacity(0.0),  location: 0.40),
                    .init(color: .clear,               location: 0.72),
                    .init(color: .black.opacity(0.28), location: 1.0),
                ], center: .center, startRadius: 0, endRadius: size * 0.5))

            Circle().strokeBorder(.white.opacity(0.28), lineWidth: rim)
            Circle().strokeBorder(.black.opacity(0.22), lineWidth: rim).padding(rim)

            // Crisp centre label.
            LibraryImage(url: artURL, maxPixel: 240) { TVPlaceholder() }
                .frame(width: size * 0.42, height: size * 0.42)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: rim))

            // Hub + spindle hole.
            Circle().fill(.black).frame(width: size * 0.14, height: size * 0.14)
            Circle().strokeBorder(.white.opacity(0.28), lineWidth: max(0.5, rim * 0.7))
                .frame(width: size * 0.14, height: size * 0.14)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: size * 0.025, y: size * 0.012)
    }
}

// MARK: - One carousel cover (cover + slide-out CD + reflection)

struct TVFlowCover: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    let size: CGFloat
    /// Whether the CD is slid out of this cover. Driven by the carousel's choreography — retracted
    /// BEFORE the flow moves, popped back out once the new centre settles — not by "is current" alone.
    var discOut = false
    var spinning = false
    /// Reflection is shown in the big centered mode, trimmed off in the docked (video) mode.
    var showReflection = true

    private var artworkStack: some View {
        ZStack {
            TVSpinningDisc(item: item, size: size * TVSpinningDisc.diameterRatio, spinning: spinning)
                .offset(x: discOut ? size * TVSpinningDisc.pullOutRatio : 0)
                .opacity(discOut ? 1 : 0)

            cover
                .offset(x: discOut ? -size * 0.1 : 0)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: discOut)
    }

    /// Center cover gets title + artist; side covers a dimmer title — like the iPhone shelf's labels.
    var emphasized = false
    /// The mini bar reuses the reflective cover but supplies its OWN text alongside — so it hides this
    /// built-in label to avoid printing the track name twice.
    var showLabel = true

    var body: some View {
        VStack(spacing: 0) {
            artworkStack

            if showReflection {
                let fraction: CGFloat = 0.30
                ZStack(alignment: .top) {
                    artworkStack
                        .scaleEffect(y: -1)
                        .frame(height: size * fraction, alignment: .top)
                        .mask(
                            LinearGradient(colors: [.white.opacity(0.18), .clear],
                                           startPoint: .top, endPoint: .bottom)
                                .frame(width: size * 2.4, height: size * fraction)
                        )
                        .allowsHitTesting(false)

                    // Track name floats over the reflection, following the cover's slide.
                    if showLabel {
                    VStack(spacing: 3) {
                        Text(item.name)
                            .font(emphasized ? .subheadline : .caption)
                            .fontWeight(emphasized ? .semibold : .regular)
                            .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                        if emphasized {
                            Text(item.primaryArtist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    .frame(width: size * 1.15)
                    .padding(.top, 14)
                    .offset(x: discOut ? -size * 0.1 : 0)
                    .animation(.spring(response: 0.42, dampingFraction: 0.72), value: discOut)
                    }
                }
            }
        }
        .frame(width: size)
    }

    private var cover: some View {
        LibraryImage(url: client.artworkURL(for: item, size: 600), maxPixel: 600) { TVPlaceholder() }
            .aspectRatio(1, contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: TVDS.cover, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: TVDS.cover, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 0.5)
            )
            .overlay(alignment: .top) {
                // Glass-catch light along the top edge — same as the phone's covers.
                LinearGradient(colors: [.white.opacity(0.28), .clear],
                               startPoint: .top, endPoint: .center)
                    .clipShape(RoundedRectangle(cornerRadius: TVDS.cover, style: .continuous))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }
}

// MARK: - The nav bar's mini pill (the Now Playing item — its OWN pill, like iOS)

/// What the mini bar mirrors — same priority as the accessory on iOS: direct video, an ACTIVELY
/// playing remote session, the local track, any remote session, else nothing.
struct TVPillModel {
    let item: MediaItem
    let sub: String?
    let spinning: Bool
    let remote: SessionHub.RemoteSession?   // non-nil → live-extrapolate the fill

    @MainActor
    static func current(_ player: Player) -> TVPillModel? {
        let videoCtl = TVVideoController.shared
        if videoCtl.direct, let video = videoCtl.activeVideo {
            return TVPillModel(item: video, sub: video.primaryArtist, spinning: !videoCtl.directPaused, remote: nil)
        }
        if let r = SessionHub.shared.remote, !r.isPaused, !player.isPlaying {
            return TVPillModel(item: r.item, sub: r.deviceName, spinning: true, remote: r)
        }
        if let item = player.currentItem {
            return TVPillModel(item: item, sub: item.primaryArtist, spinning: player.isPlaying, remote: nil)
        }
        if let r = SessionHub.shared.remote {
            return TVPillModel(item: r.item, sub: r.deviceName, spinning: !r.isPaused, remote: r)
        }
        return nil
    }

    @MainActor
    func progress(at date: Date, _ player: Player) -> Double {
        if let remote {
            let dur = max(remote.durationSeconds, 1)
            return min(max(remote.livePosition(at: date) / dur, 0), 1)
        }
        let ctl = TVVideoController.shared
        if ctl.direct { return ctl.directProgress }
        return player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
    }
}

/// The COMPACT mini bar: its own Liquid Glass pill in the nav bar — spinning CD (like the iPhone bar)
/// + title/artist with the artwork-wash progress fill. Focus grows it; CLICK hands off to the caller,
/// which opens Now Playing and (for local playback) expands this pill into the transport.
struct TVNavMiniPill: View {
    let selected: Bool
    /// Called on click; `engage` is true when local playback exists (the pill can become the transport).
    let action: (_ engage: Bool) -> Void

    @Environment(Player.self) private var player
    @FocusState private var focused: Bool
    @State private var width: CGFloat = 1

    var body: some View {
        let model = TVPillModel.current(player)
        Button {
            let videoCtl = TVVideoController.shared
            action(player.currentItem != nil || videoCtl.direct)
        } label: {
            if let m = model {
                HStack(spacing: 12) {
                    // The round CD itself, spinning — the iOS mini bar look.
                    TVSpinningDisc(item: m.item, size: 38, spinning: m.spinning)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(m.item.name).font(.caption).fontWeight(.semibold).lineLimit(1)
                        if let sub = m.sub, !sub.isEmpty {
                            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 240, alignment: .leading)
                }
                .padding(.leading, 8)
                .padding(.trailing, 18)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(selected && !focused ? AnyShapeStyle(.white.opacity(0.16))
                                                        : AnyShapeStyle(.clear))
                )
                // Progress fill, live: the artwork wash revealed left→right as the track plays.
                .background(alignment: .leading) {
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        TVArtworkFill(item: m.item)
                            .frame(width: width)
                            .frame(maxHeight: .infinity)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: max(0, width * m.progress(at: ctx.date, player)))
                            }
                    }
                    .allowsHitTesting(false)
                }
                // Single instance — safe GeometryReader, just measures the pill for the fill mask.
                .background {
                    GeometryReader { g in
                        Color.clear.onChange(of: g.size.width, initial: true) { _, w in width = w }
                    }
                }
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.95 : 0), lineWidth: 2))
                // "Expands on top" when the remote lands on it.
                .scaleEffect(focused ? 1.08 : 1.0, anchor: .top)
            } else {
                // Nothing playing anywhere — a plain text tab like its siblings.
                Text("Now Playing")
                    .font(.callout).fontWeight(.medium)
                    .foregroundStyle(focused ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                    .padding(.horizontal, 26)
                    .padding(.vertical, 12)
                    .background(
                        Capsule().fill(focused ? AnyShapeStyle(.white)
                                       : selected ? AnyShapeStyle(.white.opacity(0.16))
                                       : AnyShapeStyle(.clear))
                    )
            }
        }
        .buttonStyle(.tvBare)
        .focused($focused)
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

// MARK: - The EXPANDED mini bar: the transport pill

/// The mini bar grown into the full transport (click the compact pill to get here): CD + track text,
/// previous / play-pause / next, lyrics + queue toggles, and a focusable scrub bar — all inside ONE
/// glass pill at the top, exactly like the iOS mini bar owning playback. Menu (back) collapses it and
/// returns focus to the nav bar.
struct TVNavTransportPill: View {
    @Binding var engaged: Bool

    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    private enum Ctl: Hashable { case prev, play, next, lyrics, queue, scrub }
    @FocusState private var focus: Ctl?

    private var videoCtl: TVVideoController { TVVideoController.shared }

    var body: some View {
        let direct = videoCtl.direct
        let item = direct ? videoCtl.activeVideo : player.currentItem
        VStack(spacing: 12) {
            HStack(spacing: 16) {
                if let item {
                    TVSpinningDisc(item: item, size: 44,
                                   spinning: direct ? !videoCtl.directPaused : player.isPlaying)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(item.name).font(.caption).fontWeight(.semibold).lineLimit(1)
                        Text(item.primaryArtist).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: 230, alignment: .leading)
                }

                Spacer(minLength: 16)

                controlButton(.prev, "backward.fill") {
                    if direct { videoCtl.skipDirect(-1, client: client, audio: player) }
                    else { player.previousTrack() }
                }
                controlButton(.play, (direct ? !videoCtl.directPaused : player.isPlaying) ? "pause.fill" : "play.fill") {
                    direct ? videoCtl.togglePlayPause() : player.togglePlayPause()
                }
                controlButton(.next, "forward.fill") {
                    if direct { videoCtl.skipDirect(+1, client: client, audio: player) }
                    else { player.nextTrack() }
                }

                if !direct {
                    controlButton(.lyrics, TVNowPlayingUI.shared.pane == .lyrics ? "quote.bubble.fill" : "quote.bubble") {
                        TVNowPlayingUI.shared.toggle(.lyrics)
                    }
                    .padding(.leading, 10)
                    controlButton(.queue, "list.triangle") {
                        TVNowPlayingUI.shared.toggle(.queue)
                    }
                }
            }

            scrubBar(direct: direct)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 14)
        .frame(width: 980)
        // The artwork wash fills the whole transport (it IS the now-playing surface).
        .background {
            if let item {
                TVArtworkFill(item: item).opacity(0.55).allowsHitTesting(false)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 34, style: .continuous))
        .glassEffect(.regular, in: .rect(cornerRadius: 34))
        .focusSection()
        // Menu/back collapses the transport and hands the nav bar back.
        .onExitCommand { engaged = false }
        .onAppear {
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(80))
                focus = .play
            }
        }
    }

    /// One round transport control: white circle + black glyph when focused, quiet wash otherwise.
    private func controlButton(_ id: Ctl, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(focus == id ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                .frame(width: 50, height: 50)
                .background(Circle().fill(focus == id ? AnyShapeStyle(.white)
                                                      : AnyShapeStyle(.white.opacity(0.10))))
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.tvBare)
        .focused($focus, equals: id)
        .animation(.easeOut(duration: 0.12), value: focus)
    }

    /// The progress bar — FOCUSABLE for audio: land on it and swipe left/right to scrub (±10s a step,
    /// the tvOS equivalent of the iPhone's hold-and-drag). Direct video shows progress read-only.
    @ViewBuilder
    private func scrubBar(direct: Bool) -> some View {
        let scrubFocused = focus == .scrub
        HStack(spacing: 14) {
            Text((direct ? 0 : player.currentTime).formattedDuration)
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)

            GeometryReader { g in
                let frac: Double = direct
                    ? videoCtl.directProgress
                    : (player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0)
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.22))
                    Capsule().fill(.white.opacity(scrubFocused ? 1.0 : 0.75))
                        .frame(width: max(6, g.size.width * frac))
                }
            }
            .frame(height: scrubFocused ? 10 : 5)
            .animation(.easeOut(duration: 0.15), value: scrubFocused)

            Text((direct ? 0 : player.duration).formattedDuration)
                .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .focusable(!direct)
        .focused($focus, equals: .scrub)
        .onMoveCommand { dir in
            guard focus == .scrub else { return }
            switch dir {
            case .left:  player.seek(to: max(0, player.currentTime - 10))
            case .right: player.seek(to: min(player.duration, player.currentTime + 10))
            case .up:    focus = .play   // onMoveCommand consumes ALL moves — route up out manually
            default: break
            }
        }
    }
}

/// A blurred wash of the artwork — the tvOS stand-in for the iPhone's ArtworkGradient (iOS-only). Fills
/// the mini shelf left→right to show progress.
private struct TVArtworkFill: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    var body: some View {
        LibraryImage(url: client.artworkURL(for: item, size: 160), maxPixel: 160) { Color(white: 0.2) }
            .aspectRatio(contentMode: .fill)
            .blur(radius: 30, opaque: true)
            .saturation(1.4)
            .overlay(Color.black.opacity(0.28))   // tone it down so the white text stays legible
    }
}

// MARK: - The queue carousel

/// The Now Playing queue as an iTunes-style cover flow driven directly by the remote — the exact feel
/// of the iPhone's Featured shelf. The CENTER cover IS the now-playing track (centre = selected, so no
/// focus platter/highlight): swiping left/right on the remote changes tracks, the flow springs across,
/// and the CD stays slid out under the centre cover. Select toggles play/pause.
///
/// No per-cover Buttons: positions derive from each item's distance to the current index, so the
/// carousel is a pure function of the queue — nothing for the focus engine to decorate.
struct TVNowPlayingArtwork: View {
    @Environment(Player.self) private var player
    let coverSize: CGFloat
    /// Docked (video backdrop): the label sits to the RIGHT of the cover, and the whole thing hugs the
    /// left. Undocked (audio): big centred cover with its title/artist in the reflection below.
    var docked = false
    /// Called on any remote input here so the parent can keep the playhead footer awake.
    var onInteract: () -> Void = {}
    /// Swiping DOWN hands focus to the transport controls below (Now Playing supplies this); nil →
    /// down releases focus like up does.
    var onFocusControls: (() -> Void)? = nil
    @FocusState private var focused: Bool

    // ---- Track-change choreography -------------------------------------------------------------
    // Every transition plays the same three beats: the CD tucks back INTO the cover, the artwork
    // swaps to the new track, and only then does the new CD pop out and start spinning.
    /// Whether the CD is out. Never flip this directly mid-transition — the worker owns it.
    @State private var discOut = true
    /// The single running choreography worker (swipe or auto-advance); nil when settled.
    @State private var transition: Task<Void, Never>?
    /// Where the user is heading. Updated by every swipe; drained by the worker one step at a time,
    /// so queued-up swipes play out sequentially instead of being lost.
    @State private var targetIndex: Int?

    /// The song is in its final second — begin tucking the CD in now, so the artwork is ready to swap
    /// the instant the track changes and the next CD pops out as the next song starts.
    private var nearEnd: Bool {
        player.isPlaying && player.duration > 1 && player.duration - player.currentTime < 1.0
    }

    var body: some View {
        // Just the current track: reflective, CD out and spinning, choreographed on change. (Swiping
        // still steps prev/next tracks — the neighbour covers just aren't drawn.)
        Group {
            if let item = player.currentItem {
                cover(item)
                    // Unique per queue-slot (the same song can sit in the queue twice) so a track
                    // change swaps the view and the transition below runs.
                    .id("\(player.queue.currentIndex)-\(item.id)")
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.32), value: player.queue.currentIndex)
        .frame(maxWidth: .infinity, alignment: docked ? .leading : .center)
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .scaleEffect(focused ? 1.02 : 1.0)   // breathes subtly when the remote is on it
        .onMoveCommand { direction in
            onInteract()
            switch direction {
            case .left:  step(-1)
            case .right: step(+1)
            case .up:
                focused = false   // hand focus back to the rest of the screen (tab bar)
            case .down:
                // Down = the transport controls (deterministic — the bare geometric re-resolve after
                // releasing focus could land on the tab bar instead).
                if let onFocusControls { focused = false; onFocusControls() }
                else { focused = false }
            default:
                break
            }
        }
        .onTapGesture { onInteract(); player.togglePlayPause() }   // remote click = play/pause
        // The track changed underneath us (natural end, remote command, another device): the retract
        // already happened via `nearEnd` — commit it and pop the new CD once the swap settles.
        .onChange(of: player.queue.currentIndex) { _, _ in
            startWorker(preRetracted: true)
        }
        .onDisappear {
            transition?.cancel(); transition = nil
            targetIndex = nil
            discOut = true
        }
        .animation(.easeOut(duration: 0.2), value: focused)
    }

    /// The cover + CD, with the label below (audio) or to the right (docked over a video).
    @ViewBuilder
    private func cover(_ item: MediaItem) -> some View {
        let art = TVFlowCover(item: item,
                              size: coverSize,
                              // In the small dock keep the CD permanently out — the tuck-in choreography
                              // isn't needed there, and a track-change retract could otherwise leave it
                              // hidden (the "missing CD" in the corner).
                              discOut: docked ? true : (discOut && !nearEnd),
                              spinning: player.isPlaying,
                              showReflection: true,
                              emphasized: !docked,
                              showLabel: !docked)
        if docked {
            HStack(alignment: .center, spacing: 22) {
                art.padding(.trailing, coverSize * TVSpinningDisc.pullOutRatio)   // room for the slid-out CD
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.subheadline).fontWeight(.semibold).lineLimit(2)
                    Text(item.primaryArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: 300, alignment: .leading)
                // Legible over the video behind it.
                .shadow(color: .black.opacity(0.7), radius: 5, y: 2)
            }
        } else {
            art
        }
    }

    // MARK: Choreography

    /// A trackpad swipe: head one step left/right from wherever we're already heading.
    private func step(_ delta: Int) {
        let base = targetIndex ?? player.queue.currentIndex
        let next = base + delta
        guard (0..<player.queue.items.count).contains(next) else { return }
        targetIndex = next
        startWorker(preRetracted: false)
    }

    /// The one transition worker. Beats: tuck the CD in → swap the artwork (draining any queued swipe
    /// targets one at a time) → pop the CD back out. A second call while running is a no-op — the
    /// running worker picks up the new `targetIndex` in its drain loop.
    private func startWorker(preRetracted: Bool) {
        guard transition == nil else { return }
        transition = Task {
            discOut = false
            // Swipes wait for the tuck-in to read before the swap; for a natural end the tuck already
            // played during the song's final second — just let the swap settle so the pop lands right
            // as the new song starts.
            try? await Task.sleep(for: .milliseconds(preRetracted ? 380 : 280))
            while !Task.isCancelled, let t = targetIndex {
                targetIndex = nil
                if t != player.queue.currentIndex { player.play(at: t) }
                try? await Task.sleep(for: .milliseconds(400))
            }
            if !Task.isCancelled { discOut = true }
            transition = nil
        }
    }
}
