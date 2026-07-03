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
                            .font(emphasized ? .headline : .caption)
                            .fontWeight(emphasized ? .semibold : .regular)
                            .foregroundStyle(emphasized ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                        if emphasized {
                            Text(item.primaryArtist)
                                .font(.caption)
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

// MARK: - Corner "channel bug" (the TV's mini bar)

/// The TV's mini bar: a full-width band pinned to the bottom of every page. A black gradient fills the
/// whole bottom and fades UP to transparent around the track title, so whatever's behind (a grid, or a
/// playing music video) is covered at the bottom and clean above. On the left, the skeuomorphic
/// reflective cover + slid-out spinning CD; to its right, the track title / artist / album.
struct TVNowPlayingBug: View {
    let item: MediaItem
    var artistLine: String? = nil
    var albumLine: String? = nil
    var spinning = true

    private let cover: CGFloat = 128

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // The whole bottom is a black gradient fading UP to clear, so it covers content at the
            // bottom (a grid, or a playing video) and fades out around the track title.
            LinearGradient(colors: [.black, .black.opacity(0.9), .clear],
                           startPoint: .bottom, endPoint: .top)
                .frame(height: 340)
                .frame(maxWidth: .infinity)
                .allowsHitTesting(false)

            // Reflective cover + CD (left) and track text, pinned to the bottom.
            HStack(alignment: .top, spacing: 34) {
                // The mini bar carries its own text, so hide the cover's built-in label.
                TVFlowCover(item: item, size: cover, discOut: true, spinning: spinning,
                            showReflection: true, showLabel: false)
                    .padding(.trailing, cover * TVSpinningDisc.pullOutRatio)   // room for the slid-out disc

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.name)
                        .font(.title3).fontWeight(.semibold)
                        .lineLimit(1)
                    if let artistLine, !artistLine.isEmpty {
                        Text(artistLine).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let albumLine, !albumLine.isEmpty {
                        Text(albumLine).font(.callout).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
                .padding(.top, 6)
            }
            .padding(.horizontal, 70)
            .padding(.bottom, 36)
        }
        .frame(maxWidth: .infinity, alignment: .bottom)
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
        Group {
            if let item = player.currentItem {
                TVFlowCover(item: item,
                            size: coverSize,
                            discOut: discOut && !nearEnd,
                            spinning: player.isPlaying,
                            showReflection: true,
                            emphasized: true)
                    // Unique per queue-slot (the same song can sit in the queue twice) so a track
                    // change swaps the view and the transition below runs.
                    .id("\(player.queue.currentIndex)-\(item.id)")
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.easeInOut(duration: 0.32), value: player.queue.currentIndex)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .scaleEffect(focused ? 1.02 : 1.0)   // breathes subtly when the remote is on it
        .onMoveCommand { direction in
            switch direction {
            case .left:  step(-1)
            case .right: step(+1)
            case .up, .down:
                focused = false   // hand focus back to the rest of the screen (tab bar)
            default:
                break
            }
        }
        .onTapGesture { player.togglePlayPause() }   // remote click = play/pause
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
