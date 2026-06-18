import SwiftUI

struct HomeView: View {
    @EnvironmentObject var api: JellyfinAPI
    @EnvironmentObject var player: AudioPlayerManager

    @State private var recentlyAdded: [MediaItem] = []
    @State private var featured: [MediaItem] = []
    @State private var artists: [MediaItem] = []
    @State private var loaded = false

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        // Featured projects in the skeuomorphic Cover Flow carousel…
                        CoverFlowShelf(title: "Featured",
                                       albums: featured,
                                       topInset: geo.safeAreaInsets.top)

                        // …and the recently added projects in the full-width Featured-style section.
                        if !recentlyAdded.isEmpty {
                            FeaturedShelf(title: "Recently Added", albums: recentlyAdded)
                        }
                        if !artists.isEmpty {
                            ArtistsShelf(artists: artists)
                        }
                        if !loaded {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                        }
                        Color.clear.frame(height: DS.bottomClearance)
                    }
                }
                .ignoresSafeArea(edges: .top)
            }
            .toolbar(.hidden, for: .navigationBar)
            .cardNavigation()
            .refreshable { await load(force: true) }
        }
        .task { await load() }
    }

    private func load(force: Bool = false) async {
        guard !loaded || force else { return }
        async let recent = api.fetchRecentlyAdded(limit: 14)
        async let feat = api.fetchFeatured(limit: 8)
        async let arts = api.fetchArtists(limit: 30)
        recentlyAdded = (try? await recent) ?? recentlyAdded
        featured = (try? await feat) ?? featured
        artists = (try? await arts) ?? artists
        loaded = true
    }
}

// MARK: - Cover Flow Shelf (skeuomorphic iTunes-style, dark band to the top of the page)

struct CoverFlowShelf: View {
    let title: String
    let albums: [MediaItem]
    let topInset: CGFloat
    @EnvironmentObject var player: AudioPlayerManager
    private let coverSize: CGFloat = 204

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text(title)
                .font(.largeTitle).fontWeight(.bold)
                .foregroundStyle(.white)
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
        .padding(.top, topInset + 14)
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        // The dark fill extends far above the band and fades into the system background, so
        // over-scrolling at the top reveals a smooth gradient instead of a hard black/white edge.
        .background(alignment: .bottom) {
            LinearGradient(
                stops: [
                    .init(color: Color(.systemBackground), location: 0.0),
                    .init(color: Color(.systemBackground), location: 0.34),
                    .init(color: Color(white: 0.11), location: 0.62),
                    .init(color: Color(white: 0.03), location: 1.0),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: 900)
            .frame(maxWidth: .infinity)
            .ignoresSafeArea(edges: .top)
            .allowsHitTesting(false)
        }
    }
}

struct ReflectedCover: View {
    let album: MediaItem
    let size: CGFloat
    @EnvironmentObject var api: JellyfinAPI
    @EnvironmentObject var player: AudioPlayerManager

    private var isCurrent: Bool { player.currentItem?.albumId == album.id }

    var body: some View {
        AsyncImage(url: api.artworkURL(for: album, size: 600)) { phase in
            let image: Image? = {
                if case .success(let img) = phase { return img }
                return nil
            }()

            VStack(spacing: 0) {
                // Tapping plays the album: the cover slides left while a CD slides out from
                // behind it to the right and spins.
                ZStack {
                    SpinningDisc(artURL: api.artworkURL(for: album, size: 400),
                                 size: size * 0.9,
                                 spinning: isCurrent && player.isPlaying)
                        .offset(x: isCurrent ? size * 0.3 : 0)
                        .opacity(isCurrent ? 1 : 0)

                    cover(image)
                        .offset(x: isCurrent ? -size * 0.1 : 0)
                }
                .frame(width: size, height: size)
                .animation(.spring(response: 0.55, dampingFraction: 0.74), value: isCurrent)

                // Reflection with the title/artist floating in front of it, close to the cover.
                // It slides left in sync with the cover so it tracks the now-playing state.
                ZStack(alignment: .top) {
                    cover(image)
                        .scaleEffect(y: -1)
                        .frame(height: size * 0.5, alignment: .top)
                        .clipped()
                        .mask(
                            LinearGradient(colors: [.white.opacity(0.4), .clear],
                                           startPoint: .top, endPoint: .bottom)
                        )
                        .offset(x: isCurrent ? -size * 0.1 : 0)
                        .animation(.spring(response: 0.55, dampingFraction: 0.74), value: isCurrent)

                    VStack(spacing: 1) {
                        Text(album.name)
                            .font(.caption).fontWeight(.semibold)
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(album.albumArtist ?? album.primaryArtist)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                            .lineLimit(1)
                    }
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    .padding(.top, 5)
                    .frame(width: size)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { playAlbum() }
        }
        .frame(width: size)
    }

    private func playAlbum() {
        Task {
            let tracks = (try? await api.fetchTracks(parentId: album.id)) ?? []
            if !tracks.isEmpty { player.play(items: tracks, from: 0, api: api) }
        }
    }

    @ViewBuilder
    private func cover(_ image: Image?) -> some View {
        Group {
            if let image {
                image.resizable().aspectRatio(1, contentMode: .fill)
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

// MARK: - Featured Shelf (full-width paging cards)

struct FeaturedShelf: View {
    var title: String = "Featured"
    let albums: [MediaItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.largeTitle).fontWeight(.bold)
                .padding(.horizontal, DS.hPad)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(albums) { album in
                        NavCard(route: .album(album)) {
                            FeaturedCard(album: album)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, DS.hPad, for: .scrollContent)
            .scrollTargetBehavior(.paging)
        }
    }
}

struct FeaturedCard: View {
    let album: MediaItem
    @EnvironmentObject var api: JellyfinAPI

    var body: some View {
        let art = api.artworkURL(for: album, size: 600)
        HStack(spacing: 16) {
            AsyncImage(url: art) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(1, contentMode: .fill)
                } else {
                    Color.white.opacity(0.12)
                }
            }
            .frame(width: 116, height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .shadow(color: .black.opacity(0.4), radius: 8, y: 4)

            VStack(alignment: .leading, spacing: 5) {
                Text(album.name)
                    .font(.headline).foregroundStyle(.white).lineLimit(2)
                Text(album.albumArtist ?? album.primaryArtist)
                    .font(.subheadline).foregroundStyle(.white.opacity(0.7)).lineLimit(1)
                Text(album.overview ?? "")
                    .font(.caption).foregroundStyle(.white.opacity(0.6)).lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(height: 148)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                AsyncImage(url: art) { phase in
                    if case .success(let img) = phase {
                        img.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        Color(white: 0.15)
                    }
                }
                .blur(radius: 28)
                LinearGradient(colors: [.black.opacity(0.45), .black.opacity(0.7)],
                               startPoint: .top, endPoint: .bottom)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(.white.opacity(0.1), lineWidth: 0.5)
        )
    }
}

// MARK: - Artists Shelf (circular avatars)

struct ArtistsShelf: View {
    let artists: [MediaItem]
    @EnvironmentObject var api: JellyfinAPI

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Artists")
                .font(.largeTitle).fontWeight(.bold)
                .padding(.horizontal, DS.hPad)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(artists) { artist in
                        NavCard(route: .artist(artist)) {
                            VStack(spacing: 8) {
                                AsyncImage(url: api.artworkURL(for: artist, size: 200)) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().aspectRatio(1, contentMode: .fill)
                                    } else {
                                        Color(.systemGray5)
                                            .overlay {
                                                Image(systemName: "person.fill")
                                                    .font(.title)
                                                    .foregroundStyle(Color(.systemGray3))
                                            }
                                    }
                                }
                                .frame(width: 92, height: 92)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.15), radius: 5, y: 3)

                                Text(artist.name)
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: 96)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.hPad)
            }
        }
    }
}
