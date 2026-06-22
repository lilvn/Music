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

    /// Cover + CD composition. Tapping plays the album: the cover slides left while the spinning CD
    /// slides out from behind it. Rendered twice — upright, and mirrored as the reflection.
    private var artworkStack: some View {
        ZStack {
            SpinningDisc(artURL: client.artworkURL(for: album, size: 400),
                         size: size * 0.9,
                         spinning: isCurrent && player.isPlaying)
                .offset(x: isCurrent ? size * 0.3 : 0)
                .opacity(isCurrent ? 1 : 0)

            cover(uiImage)
                .offset(x: isCurrent ? -size * 0.1 : 0)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.55, dampingFraction: 0.74), value: isCurrent)
    }

    var body: some View {
        VStack(spacing: 0) {
            artworkStack

            // Reflection mirrors the WHOLE artwork — the cover AND the spinning CD when it's out —
            // so the disc keeps its reflection instead of floating untethered. No hard clip (the
            // mask handles the fade) so a slid-out CD / rotated cover isn't cut off at the edges.
            ZStack(alignment: .top) {
                artworkStack
                    .scaleEffect(y: -1)
                    .frame(height: size * 0.5, alignment: .top)
                    // Fade gradient is wider than the artwork (which overflows its frame via the
                    // slid-out CD / rotation) so it ONLY fades vertically and never clips the sides.
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
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { playAlbum() }
        .libraryItemMenu(album)
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
                Color(white: 0.18)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.3))
                    }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(.white.opacity(0.14), lineWidth: 0.5)
        )
        .overlay(alignment: .top) {
            LinearGradient(colors: [.white.opacity(0.28), .clear],
                           startPoint: .top, endPoint: .center)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .allowsHitTesting(false)
        }
    }
}

// MARK: - Spinning CD (shared by the cover flow and the mini player)

struct SpinningDisc: View {
    let artURL: URL?
    let size: CGFloat
    let spinning: Bool

    /// Shared so the mini-bar CD and the carousel CD turn at exactly the same rate.
    static let spinSpeed: Double = 52   // degrees / second

    @State private var spinBase: Double = 0
    @State private var spinRef = Date()

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            let angle = spinning
                ? spinBase + context.date.timeIntervalSince(spinRef) * Self.spinSpeed
                : spinBase
            disc.rotationEffect(.degrees(angle))
        }
        .onChange(of: spinning) { _, now in
            if now { spinRef = Date() }
            else { spinBase += Date().timeIntervalSince(spinRef) * Self.spinSpeed }
        }
    }

    private var disc: some View {
        ZStack {
            // Shiny silver CD body (the data area).
            Circle()
                .fill(RadialGradient(
                    colors: [Color(white: 0.83), Color(white: 0.58), Color(white: 0.86), Color(white: 0.6)],
                    center: .center, startRadius: size * 0.16, endRadius: size * 0.52))

            // Iridescent rainbow sheen.
            Circle()
                .fill(AngularGradient(
                    gradient: Gradient(colors: [
                        .clear, .cyan.opacity(0.35), .clear, .pink.opacity(0.30), .clear,
                        .green.opacity(0.30), .clear, .blue.opacity(0.30), .clear, .cyan.opacity(0.35), .clear,
                    ]),
                    center: .center))
                .blendMode(.screen)
                .opacity(0.6)

            // Specular highlight streak.
            Circle()
                .fill(AngularGradient(
                    colors: [.white.opacity(0.55), .clear, .clear, .clear, .white.opacity(0.4), .clear, .clear, .clear],
                    center: .center))
                .blendMode(.screen)
                .opacity(0.5)

            // Outer rim highlight.
            Circle().strokeBorder(.white.opacity(0.3), lineWidth: max(0.5, size * 0.012))

            // Center label = album art sticker (the only place the art lives).
            LibraryImage(url: artURL, maxPixel: 200) { Color(.systemGray3) }
                .frame(width: size * 0.44, height: size * 0.44)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.5), lineWidth: max(0.5, size * 0.012)))

            // Hub + spindle hole.
            Circle().fill(Color(.systemBackground).opacity(0.92)).frame(width: size * 0.13, height: size * 0.13)
            Circle().strokeBorder(.black.opacity(0.3), lineWidth: 0.7)
                .frame(width: size * 0.13, height: size * 0.13)
        }
        .frame(width: size, height: size)
    }
}
