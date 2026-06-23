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
            .frame(height: coverSize * 1.5)
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

    /// Cover + CD composition. Tapping plays the album: the cover slides left while the spinning CD
    /// slides out from behind it. Rendered twice — upright, and mirrored as the reflection.
    private var artworkStack: some View {
        ZStack {
            SpinningDisc(artURL: client.artworkURL(for: album, size: 400),
                         size: size * SpinningDisc.diameterRatio,
                         spinning: isCurrent && (player.isPlaying || player.isScrubbing),
                         scrubProgress: (isCurrent && player.isScrubbing) ? player.scrubProgress : nil)
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
                         scrubProgress: (isCurrent && player.isScrubbing) ? player.scrubProgress : nil)
                .offset(x: isCurrent ? size * SpinningDisc.pullOutRatio : 0)
                .opacity(isCurrent ? 1 : 0)

            cover(uiImage)
                .offset(x: isCurrent ? -size * 0.1 : 0)
                .contentShape(Rectangle())
                .onTapGesture { if isCurrent { push(.album(album)) } else { playAlbum() } }
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.55, dampingFraction: 0.74), value: isCurrent)
    }

    var body: some View {
        VStack(spacing: 0) {
            uprightArtwork

            // Reflection mirrors the whole artwork (cover + CD); no menu here.
            ZStack(alignment: .top) {
                artworkStack
                    .scaleEffect(y: -1)
                    .frame(height: size * 0.5, alignment: .top)
                    .mask(
                        LinearGradient(colors: [.white.opacity(0.18), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(width: size * 2.4, height: size * 0.5)
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
            if let cached = ImageStore.shared.cached(url) { uiImage = cached }
            else { uiImage = await ImageStore.shared.load(url, maxPixel: 600) }
        }
    }

    private func playAlbum() {
        Task {
            let tracks = (try? await client.fetchTracks(parentId: album.id)) ?? []
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

struct SpinningDisc: View {
    let artURL: URL?
    let size: CGFloat
    let spinning: Bool
    /// When set (0…1), the disc angle TRACKS the scrub position instead of free-spinning, so dragging
    /// the playhead turns the disc. Folds back into the free spin continuously when the scrub ends.
    var scrubProgress: Double? = nil

    /// Disc geometry, shared by the cover-flow and the mini player so both pull out the same way:
    /// the disc is `diameterRatio` of the artwork and its centre slides out by `pullOutRatio`.
    static let diameterRatio: CGFloat = 0.9
    static let pullOutRatio: CGFloat = 0.3

    /// Shared so the mini-bar CD and the carousel CD turn at exactly the same rate.
    static let spinSpeed: Double = 48             // degrees / second
    private static let scrubTurns: Double = 540   // degrees across the full scrub range

    // Free spin is a pure function of (spinBase, spinRef): angle = spinBase + elapsed·speed, but only
    // while a segment is open (spinRef != nil). Stopping the spin or starting a scrub folds the elapsed
    // rotation into spinBase and closes the segment, so the visible angle never jumps — and the result
    // is independent of onChange ordering (the earlier cause of the disc "jumping randomly").
    @State private var spinBase: Double = 0
    @State private var spinRef: Date? = nil
    @State private var scrubAnchorAngle: Double = 0
    @State private var scrubAnchorProgress: Double = 0
    @State private var lastScrub: Double = 0

    private var freeSpinning: Bool { spinning && scrubProgress == nil }

    private func angle(at date: Date) -> Double {
        if let p = scrubProgress {
            return scrubAnchorAngle + (p - scrubAnchorProgress) * Self.scrubTurns
        }
        if spinning, let ref = spinRef {
            return spinBase + date.timeIntervalSince(ref) * Self.spinSpeed
        }
        return spinBase
    }

    /// Open or close the free-spin segment to match the current state, folding any elapsed rotation
    /// into `spinBase` so the displayed angle is continuous across the transition.
    private func reconcile(_ now: Date) {
        if freeSpinning, spinRef == nil {
            spinRef = now
        } else if !freeSpinning, let ref = spinRef {
            spinBase += now.timeIntervalSince(ref) * Self.spinSpeed
            spinRef = nil
        }
    }

    var body: some View {
        TimelineView(.animation(paused: !freeSpinning)) { context in
            disc.rotationEffect(.degrees(angle(at: context.date)))
        }
        .onAppear { reconcile(Date()) }
        .onChange(of: spinning) { _, _ in reconcile(Date()) }
        .onChange(of: scrubProgress) { old, new in
            let now = Date()
            if old == nil, new != nil {            // scrub began — close the spin at the current angle
                reconcile(now)
                scrubAnchorAngle = spinBase
                scrubAnchorProgress = new ?? 0
            } else if old != nil, new == nil {     // scrub ended — resume the spin from where it landed
                spinBase = scrubAnchorAngle + (lastScrub - scrubAnchorProgress) * Self.scrubTurns
                reconcile(now)
            }
            if let new { lastScrub = new }
        }
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
