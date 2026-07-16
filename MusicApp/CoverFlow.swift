import SwiftUI

// =====================================================================================
// THE ONE BESPOKE ELEMENT: a skeuomorphic iTunes-style Cover Flow. 3D-rotated covers; tapping
// one plays the album as the cover slides aside and a reflective CD slides out spinning; the
// reflection mirrors BOTH the cover and the CD. Everything else in the app is standard SwiftUI.
// =====================================================================================

struct CoverFlowShelf: View {
    let title: String
    let albums: [MediaItem]
    let topInset: CGFloat
    @Environment(Player.self) private var player
    private let coverSize: CGFloat = 204

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title)
                .font(.largeTitle).fontWeight(.bold)
                .padding(.horizontal, DS.hPad)

            GeometryReader { geo in
                let center = geo.size.width / 2
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 4) {
                        ForEach(albums) { album in
                            ReflectedCover(album: album, size: coverSize)
                                .visualEffect { content, proxy in
                                    let d = proxy.frame(in: .named("coverflow")).midX - center
                                    let t = max(-1, min(1, d / center))
                                    return content
                                        .rotation3DEffect(.degrees(Double(-t) * 55),
                                                          axis: (x: 0, y: 1, z: 0),
                                                          anchor: .center, perspective: 0.55)
                                        .scaleEffect(1 - abs(t) * 0.16)
                                }
                                .zIndex(player.currentItem?.albumId == album.id ? 3 : 1)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, center - coverSize / 2)
                }
                .scrollTargetBehavior(.viewAligned)
                .scrollClipDisabled()
                .coordinateSpace(.named("coverflow"))
            }
            .frame(height: coverSize * 1.30)   // cover + the (trimmed) reflection zone below — see reflectionFraction
        }
        .padding(.top, topInset + 34)
        .padding(.bottom, -6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct ReflectedCover: View {
    let album: MediaItem
    let size: CGFloat
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    private var isCurrent: Bool { player.currentItem?.albumId == album.id }

    @State private var uiImage: UIImage?
    @Environment(\.libraryPush) private var push
    /// ONE spin state shared by the upright disc and its reflection, so both render the identical
    /// angle (two independent per-view states anchored at slightly different instants and drifted).
    @State private var spin = DiscSpinState()

    /// Cover + CD composition. Tapping plays the album: the cover slides left while the spinning CD
    /// slides out from behind it. Rendered twice — upright, and mirrored as the reflection.
    private var artworkStack: some View {
        ZStack {
            SpinningDisc(artURL: client.artworkURL(for: album, size: 400),
                         size: size * SpinningDisc.diameterRatio,
                         spinning: isCurrent && (player.isPlaying || player.isScrubbing),
                         scrubProgress: (isCurrent && player.isScrubbing) ? player.scrubProgress : nil,
                         persistentSpin: spin)
                .offset(x: isCurrent ? size * SpinningDisc.pullOutRatio : 0)
                .opacity(isCurrent ? 1 : 0)

            cover(uiImage)
                .offset(x: isCurrent ? -size * 0.1 : 0)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.55, dampingFraction: 0.74), value: isCurrent)
    }

    /// Upright artwork (cover + CD). The cover carries the tap + 3D-touch menu, so the press lifts a
    /// clean square — the slid-out CD no longer gets clipped during the hold.
    private var uprightArtwork: some View {
        ZStack {
            SpinningDisc(artURL: client.artworkURL(for: album, size: 400),
                         size: size * SpinningDisc.diameterRatio,
                         spinning: isCurrent && (player.isPlaying || player.isScrubbing),
                         scrubProgress: (isCurrent && player.isScrubbing) ? player.scrubProgress : nil,
                         persistentSpin: spin)
                .offset(x: isCurrent ? size * SpinningDisc.pullOutRatio : 0)
                .opacity(isCurrent ? 1 : 0)

            cover(uiImage)
                .offset(x: isCurrent ? -size * 0.1 : 0)
                .artworkShadow()   // lift the upright cover off the page
                .contentShape(Rectangle())
                .onTapGesture { if isCurrent { push(.album(album)) } else { playAlbum() } }
                // 3D-touch (long-press) a Featured cover → open its album detail directly (no menu).
                .onLongPressGesture(minimumDuration: 0.4) {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    push(.album(album))
                }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.55, dampingFraction: 0.74), value: isCurrent)
    }

    var body: some View {
        VStack(spacing: 0) {
            uprightArtwork

            // Reflection mirrors the whole artwork (cover + CD); no menu here. We only reserve the part
            // that's actually visible — the gradient has faded to clear by `reflectionFraction` down, so
            // reserving the full half just left dead space under the shelf. Keep in sync with the shelf
            // frame (coverSize * (1 + reflectionFraction)).
            ZStack(alignment: .top) {
                let reflectionFraction: CGFloat = 0.30
                artworkStack
                    .scaleEffect(y: -1)
                    .frame(height: size * reflectionFraction, alignment: .top)
                    .mask(
                        LinearGradient(colors: [.white.opacity(0.18), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(width: size * 2.4, height: size * reflectionFraction)
                    )

                VStack(spacing: 1) {
                    Text(album.name)
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(album.albumArtist ?? album.primaryArtist)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.top, 5)
                .frame(width: size)
                .offset(x: isCurrent ? -size * 0.1 : 0)
                .animation(.spring(response: 0.55, dampingFraction: 0.74), value: isCurrent)
            }
        }
        .frame(width: size)
        .task(id: album.id) {
            guard uiImage == nil, let url = client.artworkURL(for: album, size: 600) else { return }
            if let cached = ImageStore.shared.cached(url, maxPixel: 600) { uiImage = cached }
            else { uiImage = await ImageStore.shared.load(url, maxPixel: 600) }
        }
    }

    private func playAlbum() {
        Task {
            let tracks = (try? await client.fetchAlbumTracks(albumId: album.id)) ?? []
            if !tracks.isEmpty { player.play(items: tracks, from: 0) }
        }
    }

    @ViewBuilder
    private func cover(_ image: UIImage?) -> some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(1, contentMode: .fill)
            } else {
                ArtworkPlaceholder()
            }
        }
        .frame(width: size, height: size)
        // Rounded corners consistent with the album cards elsewhere in the app.
        .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 0.5)
        )
        .overlay(alignment: .top) {
            LinearGradient(colors: [.white.opacity(0.28), .clear],
                           startPoint: .top, endPoint: .center)
                .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Spinning CD (shared by the cover flow and the mini player)

/// Spin anchor for a `SpinningDisc`, held as a reference so it can OUTLIVE the view. The mini bar uses
/// the shared `.miniBar` instance, so its CD keeps spinning across tab switches (the bottom accessory's
/// view is re-created each switch, which would otherwise reset per-view `@State` back to angle 0). The
/// cover flow keeps its own per-view instance.
@MainActor final class DiscSpinState {
    var base: Double = 0        // angle at the start of the current free-spin segment, or the frozen angle
    var ref: Date? = nil        // when that segment started; nil = not currently free-spinning
    var scrubAnchorAngle: Double = 0
    var scrubAnchorProgress: Double = 0
    var lastScrub: Double = 0
    var isScrubbing = false

    static let miniBar = DiscSpinState()

    /// The angle on screen right now. The free spin is a plain LINEAR Core Animation started from `base`
    /// at `ref`, so this analytical value matches the presentation exactly — anchoring a scrub to it
    /// can't skip. (The old wall-clock-vs-frame-clock mismatch that made the CD jump is gone.)
    func angle(_ now: Date) -> Double {
        if isScrubbing { return scrubAnchorAngle + (lastScrub - scrubAnchorProgress) * SpinningDisc.scrubTurns }
        if let ref { return base + now.timeIntervalSince(ref) * SpinningDisc.spinSpeed }
        return base
    }

    /// Fold elapsed spin into `base` and close the segment, so `angle` stays continuous across it.
    func freeze(_ now: Date) {
        if let r = ref { base += now.timeIntervalSince(r) * SpinningDisc.spinSpeed; ref = nil }
    }

    /// Anchor a scrub to the angle on screen. Idempotent — the gesture calls it synchronously and a
    /// later reactive call is a no-op.
    func beginScrub(progress: Double, now: Date) {
        guard !isScrubbing else { return }
        freeze(now)                                              // free spin resumes from here on release
        scrubAnchorAngle = base
        scrubAnchorProgress = progress
        lastScrub = progress
        isScrubbing = true
    }

    /// Fold the scrubbed rotation back into `base` so the free spin resumes from where it landed.
    func endScrub() {
        guard isScrubbing else { return }
        base = scrubAnchorAngle + (lastScrub - scrubAnchorProgress) * SpinningDisc.scrubTurns
        ref = nil
        isScrubbing = false
    }
}

struct SpinningDisc: View {
    let artURL: URL?
    let size: CGFloat
    let spinning: Bool
    /// When set (0…1), the disc angle TRACKS the scrub position instead of free-spinning, so dragging
    /// the playhead turns the disc. Folds back into the free spin continuously when the scrub ends.
    var scrubProgress: Double? = nil
    /// Pass a persistent state (the mini bar's) so the spin survives the view being re-created on a tab
    /// switch; nil → per-view state (cover flow).
    var persistentSpin: DiscSpinState? = nil
    /// When false the rotation TimelineView is paused — used for the mini bar's off-screen neighbour
    /// discs so they don't animate while hidden.
    var animating: Bool = true

    /// Disc geometry, shared by the cover-flow and the mini player so both pull out the same way:
    /// the disc is `diameterRatio` of the artwork and its centre slides out by `pullOutRatio`.
    static let diameterRatio: CGFloat = 0.9
    static let pullOutRatio: CGFloat = 0.3

    /// Shared so the mini-bar CD and the carousel CD turn at exactly the same rate.
    static let spinSpeed: Double = 48             // degrees / second
    static let scrubTurns: Double = 540           // degrees across the full scrub range

    // The presented rotation. The free spin is ONE repeating Core Animation — the GPU turns the
    // (once-rendered) disc layer while the CPU stays idle and the artwork blur is composited a single
    // time. Scrubbing and pausing set the angle directly. No TimelineView means no per-frame redraw,
    // which is the whole energy win.
    @State private var rotation: Double = 0
    /// Bumped whenever the spin is (re)started or stopped, so a deferred spin start can tell it's stale.
    @State private var spinToken = 0
    @State private var localSpin = DiscSpinState()
    private var s: DiscSpinState { persistentSpin ?? localSpin }

    private var freeSpinning: Bool { spinning && scrubProgress == nil }

    var body: some View {
        disc
            .rotationEffect(.degrees(rotation))
            .onAppear { apply() }
            .onChange(of: freeSpinning) { _, _ in apply() }
            .onChange(of: animating) { _, _ in apply() }
            .onChange(of: scrubProgress) { old, new in
                let now = Date()
                if old == nil, new != nil { s.beginScrub(progress: new ?? 0, now: now) }
                if let new { s.lastScrub = new }
                if old != nil, new == nil { s.endScrub() }
                apply()
            }
    }

    /// Point `rotation` where it belongs for the current state, and (re)start the GPU spin when free.
    private func apply() {
        let now = Date()
        if let p = scrubProgress {
            // Scrubbing: the angle follows the finger, set directly (no animation).
            if !s.isScrubbing { s.beginScrub(progress: p, now: now) }
            s.lastScrub = p
            freezeRotation(s.scrubAnchorAngle + (p - s.scrubAnchorProgress) * Self.scrubTurns)
        } else if freeSpinning && animating {
            // Land at the current visible angle, then hand a single repeating rotation to Core Animation.
            let cur = s.angle(now)
            s.base = cur; s.ref = now
            freezeRotation(cur)                 // commit the angle (also cancels any prior spin)
            spinToken += 1
            let token = spinToken
            // Deferred a tick so the freeze above commits first — otherwise SwiftUI coalesces the two
            // and the spin animates from the OLD angle (a big sweep on first appear).
            Task { @MainActor in
                guard token == spinToken, scrubProgress == nil, freeSpinning, animating else { return }
                withAnimation(.linear(duration: 360 / Self.spinSpeed).repeatForever(autoreverses: false)) {
                    rotation = cur + 360
                }
            }
        } else {
            // Paused, or an off-screen neighbour: freeze at the current angle. Only an on-screen disc
            // folds the SHARED segment (a hidden neighbour must not disturb the spin others are showing).
            spinToken += 1                      // supersede any pending/running spin
            if animating { s.freeze(now) }
            freezeRotation(s.angle(now))
        }
    }

    /// Set the presented angle with no implicit animation — this also cancels an in-flight spin.
    private func freezeRotation(_ value: Double) {
        var t = Transaction(); t.disablesAnimations = true
        withTransaction(t) { rotation = value }
    }

    private var disc: some View {
        let rim = max(0.5, size * 0.012)
        return ZStack {
            // The disc body IS the album's own artwork, blurred into a soft colour gradient. Static
            // here (animated: false) — the disc's own spin provides the motion, and the static branch
            // avoids the large drift offsets bugging out at this small size.
            ArtworkGradient(url: artURL, blur: size * 0.14, animated: false)
                .frame(width: size, height: size)
                .clipShape(Circle())

            // Gentle doming + edge vignette so it still reads as a physical disc.
            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: .white.opacity(0.22), location: 0.0),
                    .init(color: .white.opacity(0.0),  location: 0.40),
                    .init(color: .clear,               location: 0.72),
                    .init(color: .black.opacity(0.28), location: 1.0),
                ], center: .center, startRadius: 0, endRadius: size * 0.5))

            // Outer rim.
            Circle().strokeBorder(.white.opacity(0.28), lineWidth: rim)
            Circle().strokeBorder(.black.opacity(0.22), lineWidth: rim).padding(rim)

            // Center label = crisp album art, or the heart placeholder (clipped to the circle) when
            // the track has no artwork — so the CD matches the rectangular art's missing-art look.
            LibraryImage(url: artURL, maxPixel: 240) { ArtworkPlaceholder() }
                .frame(width: size * 0.42, height: size * 0.42)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: rim))

            // Hub + spindle hole.
            Circle().fill(Color(.systemBackground)).frame(width: size * 0.14, height: size * 0.14)
            Circle().strokeBorder(.black.opacity(0.28), lineWidth: max(0.5, rim * 0.7))
                .frame(width: size * 0.14, height: size * 0.14)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: size * 0.025, y: size * 0.012)
    }
}
