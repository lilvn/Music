import SwiftUI

struct HomeView: View {
    /// Externally-owned nav path so Now Playing can push album/artist into this tab.
    var navPath: Binding<NavigationPath>? = nil
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    @State private var recentlyAdded: [MediaItem] = []
    @State private var featured: [MediaItem] = []
    @State private var artists: [MediaItem] = []
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
                            FeaturedShelf(title: "Recently Added", albums: recentlyAdded)
                        }
                        if !player.recentManualPlays.isEmpty {
                            RecentlyPlayedShelf(plays: player.recentManualPlays)
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
                .ignoresSafeArea(edges: .top)
            }
            .toolbar(.hidden, for: .navigationBar)
            .sheet(isPresented: $showSettings) { SettingsView() }
            .task { await load() }
        }
    }

    private func load() async {
        guard !loaded else { return }
        async let recent = client.fetchRecentlyAdded(limit: 14)
        async let feat = client.fetchFeatured(limit: 8)
        async let arts = client.fetchArtists(limit: 30)
        recentlyAdded = (try? await recent) ?? recentlyAdded
        featured = (try? await feat) ?? featured
        artists = (try? await arts) ?? artists
        loaded = true
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
                        LibraryLink(route: .album(album)) {
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
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 8, y: 4)

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
        // Dynamic artwork gradient toned toward the system background, so the card adapts to light/dark.
        .background {
            ArtworkGradient(url: art, blur: 24)
                .overlay(Color(.systemBackground).opacity(0.42))
                .overlay(LinearGradient(colors: [Color(.systemBackground).opacity(0.15),
                                                 Color(.systemBackground).opacity(0.5)],
                                        startPoint: .top, endPoint: .bottom))
        }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
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
                                LibraryImage(url: client.artworkURL(for: artist, size: 200), maxPixel: 280) {
                                    Color(.systemGray5)
                                        .overlay {
                                            Image(systemName: "person.fill")
                                                .font(.title)
                                                .foregroundStyle(Color(.systemGray3))
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
    private let cardSize: CGFloat = 132

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
                        LibraryLink(route: play.isAlbum ? .album(album) : .albumSong(album, play.track.id)) {
                            card(track: play.track,
                                 title: play.isAlbum ? (play.track.album ?? play.track.name) : play.track.name,
                                 subtitle: play.track.primaryArtist)
                        }
                    }
                }
                .padding(.horizontal, DS.hPad)
            }
        }
    }

    private func card(track: MediaItem, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            LibraryImage(url: client.artworkURL(for: track, size: 400), maxPixel: 400) {
                ArtworkPlaceholder()
            }
            .frame(width: cardSize, height: cardSize)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
            .shadow(color: .black.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)

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
