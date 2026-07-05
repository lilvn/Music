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

    /// Model-side rotation target; a repeating one-revolution animation carries the presentation.
    @State private var rotation: Double = 0
    /// When the current spin segment started (nil while stopped) — lets a stop freeze the disc at
    /// its CURRENT presented angle instead of snapping to the settled target.
    @State private var spinStart: Date?
    /// Bumped on every start/stop so a deferred start can tell it's been superseded.
    @State private var spinEpoch = 0

    private var artURL: URL? { client.artworkURL(for: item, size: 400) }

    var body: some View {
        // One-revolution repeatForever cycles (NOT a single day-long animation: huge durations
        // quantize the interpolator's float steps into visible judder; NOT TimelineView either —
        // that froze outright on real hardware).
        disc
            .rotationEffect(.degrees(rotation))
            .onAppear { if spinning { start() } }
            .onChange(of: spinning) { _, s in s ? start() : stop() }
    }

    private func start() {
        guard spinStart == nil else { return }
        spinEpoch += 1
        let epoch = spinEpoch
        // Deferred a frame: an animation kicked off during view insertion gets folded into the
        // insertion transition and never runs.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(50))
            guard epoch == spinEpoch, spinStart == nil else { return }
            spinStart = Date()
            withAnimation(.linear(duration: 360 / Self.spinSpeed).repeatForever(autoreverses: false)) {
                rotation += 360
            }
        }
    }

    private func stop() {
        spinEpoch += 1
        guard let started = spinStart else { return }
        spinStart = nil
        // Freeze exactly where the disc IS: the model settled at +360, the presentation loops from
        // the old base — rewind to base plus the elapsed spin, no animation.
        let presented = rotation - 360 + Self.spinSpeed * Date().timeIntervalSince(started)
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { rotation = presented.truncatingRemainder(dividingBy: 360) }
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
                let fraction: CGFloat = 0.36
                ZStack(alignment: .top) {
                    // Strong enough to READ on the true-black background: bright at the seam,
                    // falling off in two stops like glass on a dark table.
                    artworkStack
                        .scaleEffect(y: -1)
                        .frame(height: size * fraction, alignment: .top)
                        .mask(
                            LinearGradient(stops: [
                                .init(color: .white.opacity(0.70), location: 0.0),
                                .init(color: .white.opacity(0.28), location: 0.50),
                                .init(color: .clear,               location: 1.0),
                            ], startPoint: .top, endPoint: .bottom)
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
                    .padding(.top, 26)   // let the bright seam of the reflection show above the label
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
    /// False → pure visual: never joins the focus graph (Now Playing uses the transport bar for all
    /// input, so focus travels nav bar → bar directly instead of stopping on the artwork).
    var interactive = true
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
        .focusable(interactive)
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

// MARK: - The Featured carousel (Home)

/// The iPhone's Featured section on the TV: a skeuomorphic cover-flow shelf. Each album is a
/// reflective cover; the one that's PLAYING slides its spinning CD out. Click plays the album —
/// click it again (while current) to open its detail.
struct TVFeaturedCarousel: View {
    let items: [MediaItem]
    /// Called with the album and whether it's already the playing one.
    let onTap: (MediaItem, Bool) -> Void
    @Environment(Player.self) private var player

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Featured").font(.title3).fontWeight(.semibold)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 56) {
                    ForEach(items) { album in
                        TVFeaturedCell(album: album) {
                            onTap(album, player.currentItem?.albumId == album.id)
                        }
                    }
                }
                .padding(.vertical, 24)      // room for the focus lift
                .padding(.trailing, 100)     // room for the slid-out disc on the last cover
            }
            .scrollClipDisabled()
        }
    }
}

private struct TVFeaturedCell: View {
    @Environment(Player.self) private var player
    let album: MediaItem
    let action: () -> Void
    @FocusState private var focused: Bool

    private var isCurrent: Bool { player.currentItem?.albumId == album.id }

    var body: some View {
        Button(action: action) {
            TVFlowCover(item: album,
                        size: 260,
                        discOut: isCurrent,
                        spinning: isCurrent && player.isPlaying,
                        showReflection: true,
                        emphasized: true)
        }
        .buttonStyle(.tvBare)   // no white platter — the lift below is the focus cue
        .focused($focused)
        .scaleEffect(focused ? 1.06 : 1.0)
        .shadow(color: .black.opacity(focused ? 0.4 : 0), radius: focused ? 20 : 0, y: focused ? 12 : 0)
        .animation(.easeOut(duration: 0.18), value: focused)
        // The slid-out CD needs breathing room so it doesn't sit under the next cover.
        .padding(.trailing, isCurrent ? 260 * TVSpinningDisc.pullOutRatio : 0)
        .animation(.spring(response: 0.5, dampingFraction: 0.8), value: isCurrent)
    }
}
