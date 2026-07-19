import SwiftUI

struct HomeView: View {
    /// Externally-owned nav path so Now Playing can push album/artist into this tab.
    var navPath: Binding<NavigationPath>? = nil
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    @State private var recentlyAdded: [MediaItem] = []
    @State private var featured: [MediaItem] = []
    @State private var mostPlayed: [MediaItem] = []
    @State private var artists: [MediaItem] = []
    @State private var playlists: [MediaItem] = []
    @State private var loaded = false
    @State private var showSettings = false

    var body: some View {
        LibraryStack(externalPath: navPath) {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        CoverFlowShelf(title: "Featured",
                                       albums: featured,
                                       topInset: geo.safeAreaInsets.top)

                        if !recentlyAdded.isEmpty {
                            FeaturedShelf(title: "New Releases", albums: recentlyAdded)
                        }
                        if !player.recentManualPlays.isEmpty {
                            RecentlyPlayedShelf(plays: player.recentManualPlays)
                        }
                        if !mostPlayed.isEmpty {
                            MostPlayedShelf(tracks: mostPlayed)
                        }
                        if !playlists.isEmpty {
                            PlaylistsShelf(playlists: playlists)
                        }
                        if !artists.isEmpty {
                            ArtistsShelf(artists: artists)
                        }
                        if !loaded {
                            ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                        } else {
                            Button("Settings") { showSettings = true }
                                .font(.footnote)
                                .tint(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 16)
                        }
                    }
                    .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
                .scrollEdgeEffectStyle(.soft, for: .top)
                // Pull down to re-sync the home shelves with Jellyfin (main page only).
                .refreshable { await load(force: true); AudioStore.shared.refreshPinnedLibrary() }
                .ignoresSafeArea(edges: .top)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task { await load() }
        }
    }

    private func load(force: Bool = false) async {
        guard force || !loaded else { return }
        async let recent = client.fetchNewReleases(limit: 14)
        async let feat = client.fetchFeatured(limit: 8)
        async let most = client.fetchMostPlayed(limit: 16)
        async let arts = client.fetchArtists(limit: 30)
        async let lists = client.fetchPlaylists()
        recentlyAdded = (try? await recent) ?? recentlyAdded
        featured = (try? await feat) ?? featured
        mostPlayed = (try? await most) ?? mostPlayed
        artists = (try? await arts) ?? artists
        playlists = (try? await lists) ?? playlists
        loaded = true

        // Warm each shelf's artwork at the size it actually renders, so nothing pops in as you scroll.
        let store = ImageStore.shared
        store.prefetch(recentlyAdded.map { client.artworkURL(for: $0, size: 400) }, maxPixel: 400)
        store.prefetch(featured.map { client.artworkURL(for: $0, size: 600) }, maxPixel: 600)
        store.prefetch(mostPlayed.map { client.artworkURL(for: $0, size: 400) }, maxPixel: 400)
        store.prefetch(playlists.map { client.artworkURL(for: $0, size: 400) }, maxPixel: 400)
        store.prefetch(artists.map { client.artworkURL(for: $0, size: 240) }, maxPixel: 320)
        store.prefetch(player.recentManualPlays.map { client.artworkURL(for: $0.track, size: 400) }, maxPixel: 400)
    }
}

// MARK: - Featured shelf (full-width paging cards) — Recently Added

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
                        LibraryLink(route: .album(album).zoomTagged("added")) {
                            FeaturedCard(album: album)
                                .containerRelativeFrame(.horizontal)
                        }
                    }
                }
            }
            .contentMargins(.horizontal, DS.hPad, for: .scrollContent)
        }
    }
}

struct FeaturedCard: View {
    let album: MediaItem
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        let art = client.artworkURL(for: album, size: 400)
        HStack(spacing: 16) {
            LibraryImage(url: art, maxPixel: 400) { ArtworkPlaceholder() }
                .frame(width: 116, height: 116)
                .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
                .artworkShadow()

            VStack(alignment: .leading, spacing: 5) {
                Text(album.name)
                    .font(.headline).foregroundStyle(.primary).lineLimit(2)
                Text(album.albumArtist ?? album.primaryArtist)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                Text(album.overview ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .frame(height: 148)
        .frame(maxWidth: .infinity)
        // Static artwork gradient (no per-card animation — keeps the home feed smooth while scrolling).
        .background {
            ArtworkGradient(url: art, blur: 24, animated: false)
                .overlay(Color(.systemBackground).opacity(0.42))
                .overlay(LinearGradient(colors: [Color(.systemBackground).opacity(0.15),
                                                 Color(.systemBackground).opacity(0.5)],
                                        startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.primary.opacity(0.08), lineWidth: 0.5)
        )
    }
}

// MARK: - Artists shelf (circular avatars)

struct ArtistsShelf: View {
    let artists: [MediaItem]
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Artists")
                    .font(.largeTitle).fontWeight(.bold)
                Spacer()
                NavigationLink { AllArtistsView() } label: {
                    Text("See All").font(.subheadline).fontWeight(.medium).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, DS.hPad)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(artists) { artist in
                        LibraryLink(route: .artist(artist)) {
                            VStack(spacing: 8) {
                                LibraryImage(url: client.artworkURL(for: artist, size: 240), maxPixel: 320) {
                                    Color(.systemGray5)
                                        .overlay {
                                            Image(systemName: "person.fill")
                                                .font(.largeTitle)
                                                .foregroundStyle(Color(.systemGray3))
                                        }
                                }
                                .frame(width: 128, height: 128)
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.15), radius: 6, y: 3)

                                Text(artist.name)
                                    .font(.subheadline)
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                                    .frame(width: 132)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.hPad)
            }
        }
    }
}

// MARK: - Playlists shelf (horizontal covers)

struct PlaylistsShelf: View {
    let playlists: [MediaItem]
    private let cardSize: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Playlists")
                .font(.largeTitle).fontWeight(.bold)
                .padding(.horizontal, DS.hPad)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 14) {
                    ForEach(playlists) { playlist in
                        LibraryLink(route: .playlist(playlist)) {
                            PlaylistCard(playlist: playlist)
                                .frame(width: cardSize)
                        }
                    }
                }
                .padding(.horizontal, DS.hPad)
            }
            .scrollClipDisabled()   // don't clip the cards' drop shadow
        }
    }
}

// MARK: - All artists (pushed from the "See All" button)

struct AllArtistsView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var artists: [MediaItem] = []
    @State private var loaded = false

    var body: some View {
        List {
            ForEach(artists) { artist in
                LibraryLink(route: .artist(artist)) { ArtistRow(artist: artist) }
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }
        }
        .listStyle(.plain)
        .navigationTitle("Artists")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !loaded else { return }
            artists = (try? await client.fetchArtists(limit: 200)) ?? []
            loaded = true
        }
    }
}

// MARK: - Recently played shelf (horizontal track cards — tap to play)

struct RecentlyPlayedShelf: View {
    /// Manual plays only (the user explicitly chose these) — not queue / Autoplay / auto-advance.
    let plays: [ManualPlay]
    @Environment(JellyfinClient.self) private var client
    private let cardSize: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played")
                .font(.largeTitle).fontWeight(.bold)
                .padding(.horizontal, DS.hPad)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(plays) { play in
                        let album = albumItem(for: play.track)
                        // Album → album detail; song → album detail with the song highlighted.
                        LibraryLink(route: (play.isAlbum ? LibraryRoute.album(album) : .albumSong(album, play.track.id)).zoomTagged("recent")) {
                            card(track: play.track,
                                 title: play.isAlbum ? (play.track.album ?? play.track.name) : play.track.name,
                                 subtitle: play.track.primaryArtist)
                        }
                    }
                }
                .padding(.horizontal, DS.hPad)
            }
            .scrollClipDisabled()   // don't clip the cards' drop shadow at the top/bottom edges
        }
    }

    private func card(track: MediaItem, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LibraryImage(url: client.artworkURL(for: track, size: 400), maxPixel: 400) {
                ArtworkPlaceholder()
            }
            .frame(width: cardSize, height: cardSize)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
            .artworkShadow()

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.footnote).fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: cardSize, alignment: .leading)
        }
    }

    /// A minimal album item for navigation; AlbumDetailView fetches full metadata by id.
    private func albumItem(for t: MediaItem) -> MediaItem {
        MediaItem(id: t.albumId ?? t.id, name: t.album ?? t.name, type: "MusicAlbum",
                  sortName: nil, albumArtist: t.albumArtist, albumArtists: nil,
                  album: nil, albumId: nil, artistItems: t.artistItems,
                  indexNumber: nil, parentIndexNumber: nil, runTimeTicks: nil,
                  productionYear: nil, imageTags: nil, albumPrimaryImageTag: nil,
                  childCount: nil, overview: nil, playlistItemId: nil)
    }
}

// MARK: - Most Played shelf (top songs by play count)

struct MostPlayedShelf: View {
    /// The user's most-played songs, already ordered most-played first.
    let tracks: [MediaItem]
    @Environment(JellyfinClient.self) private var client
    private let cardSize: CGFloat = 150

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Most Played")
                .font(.largeTitle).fontWeight(.bold)
                .padding(.horizontal, DS.hPad)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(tracks) { track in
                        // Tap opens the album detail with this song highlighted (does NOT start playback).
                        LibraryLink(route: .albumSong(albumItem(for: track), track.id).zoomTagged("most")) {
                            card(track: track)
                        }
                    }
                }
                .padding(.horizontal, DS.hPad)
            }
            .scrollClipDisabled()   // don't clip the cards' drop shadow at the top/bottom edges
        }
    }

    private func card(track: MediaItem) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LibraryImage(url: client.artworkURL(for: track, size: 400), maxPixel: 400) {
                ArtworkPlaceholder()
            }
            .frame(width: cardSize, height: cardSize)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
            .artworkShadow()

            VStack(alignment: .leading, spacing: 2) {
                Text(track.name).font(.footnote).fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1)
                Text(track.primaryArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .frame(width: cardSize, alignment: .leading)
        }
    }

    /// A minimal album item for navigation; AlbumDetailView fetches full metadata by id.
    private func albumItem(for t: MediaItem) -> MediaItem {
        MediaItem(id: t.albumId ?? t.id, name: t.album ?? t.name, type: "MusicAlbum",
                  sortName: nil, albumArtist: t.albumArtist, albumArtists: nil,
                  album: nil, albumId: nil, artistItems: t.artistItems,
                  indexNumber: nil, parentIndexNumber: nil, runTimeTicks: nil,
                  productionYear: nil, imageTags: nil, albumPrimaryImageTag: nil,
                  childCount: nil, overview: nil, playlistItemId: nil)
    }
}
