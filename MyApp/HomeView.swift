import SwiftUI

struct HomeView: View {
    @Environment(JellyfinClient.self) private var client

    @State private var recentlyAdded: [MediaItem] = []
    @State private var recentlyPlayed: [MediaItem] = []
    @State private var featured: [MediaItem] = []
    @State private var artists: [MediaItem] = []
    @State private var loaded = false
    @State private var showSettings = false

    var body: some View {
        LibraryStack {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        CoverFlowShelf(title: "Featured",
                                       albums: featured,
                                       topInset: geo.safeAreaInsets.top)

                        if !recentlyAdded.isEmpty {
                            FeaturedShelf(title: "Recently Added", albums: recentlyAdded)
                        }
                        if !recentlyPlayed.isEmpty {
                            RecentlyPlayedShelf(tracks: recentlyPlayed)
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
                .scrollEdgeEffectHidden(true, for: .top)
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
        async let played = client.fetchRecentlyPlayed(limit: 16)
        async let feat = client.fetchFeatured(limit: 8)
        async let arts = client.fetchArtists(limit: 30)
        recentlyAdded = (try? await recent) ?? recentlyAdded
        recentlyPlayed = (try? await played) ?? recentlyPlayed
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
            LibraryImage(url: art, maxPixel: 400) { Color.white.opacity(0.12) }
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
                LibraryImage(url: art, maxPixel: 400) { Color(white: 0.15) }
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

// MARK: - Artists shelf (circular avatars)

struct ArtistsShelf: View {
    let artists: [MediaItem]
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Artists")
                .font(.largeTitle).fontWeight(.bold)
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

// MARK: - Recently played shelf (horizontal track cards — tap to play)

struct RecentlyPlayedShelf: View {
    let tracks: [MediaItem]
    @Environment(JellyfinClient.self) private var client
    private let cardSize: CGFloat = 132

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Recently Played")
                .font(.largeTitle).fontWeight(.bold)
                .padding(.horizontal, DS.hPad)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 14) {
                    ForEach(tracks) { track in
                        // Tapping opens the track's album detail (not instant playback).
                        LibraryLink(route: .album(albumItem(for: track))) {
                            VStack(alignment: .leading, spacing: 6) {
                                LibraryImage(url: client.artworkURL(for: track, size: 400), maxPixel: 400) {
                                    Color(.systemGray6)
                                        .overlay { Image(systemName: "music.note").foregroundStyle(Color(.systemGray4)) }
                                }
                                .frame(width: cardSize, height: cardSize)
                                .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
                                .shadow(color: .black.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(track.album ?? track.name)
                                        .font(.footnote).fontWeight(.semibold)
                                        .foregroundStyle(.primary).lineLimit(1)
                                    Text(track.primaryArtist)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(width: cardSize, alignment: .leading)
                            }
                        }
                    }
                }
                .padding(.horizontal, DS.hPad)
            }
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
