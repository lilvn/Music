import SwiftUI

/// Album / playlist / Liked Songs detail: big cover on the left, focusable track list on the right —
/// the classic tvOS two-pane layout.
struct TVCollectionDetailView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @Environment(\.tvOpenNowPlaying) private var openNowPlaying
    let collection: TVCollection
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true

    private var headerItem: MediaItem? {
        switch collection {
        case .album(let a): a
        case .artist(let a): a
        case .playlist(let p): p
        case .liked, .musicVideos: nil
        }
    }
    private var title: String {
        switch collection {
        case .album(let a): a.name
        case .artist(let a): a.name
        case .playlist(let p): p.name
        case .liked: "Liked Songs"
        case .musicVideos: "Music Videos"
        }
    }
    private var subtitle: String {
        switch collection {
        case .album(let a): a.albumArtist ?? a.primaryArtist
        case .artist: "Artist"
        case .playlist: "Playlist"
        case .liked: "\(tracks.count) songs"
        case .musicVideos: "\(tracks.count) videos"
        }
    }
    /// Icon for the coverless header tile (Liked Songs / Music Videos).
    private var placeholderIcon: String {
        if case .musicVideos = collection { "play.rectangle.fill" } else { "heart.fill" }
    }
    private var isVideos: Bool { if case .musicVideos = collection { true } else { false } }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            // Left pane: cover + play controls.
            VStack(spacing: 24) {
                Group {
                    if let headerItem {
                        LibraryImage(url: client.artworkURL(for: headerItem, size: 800), maxPixel: 800) {
                            TVPlaceholder()
                        }
                    } else {
                        ZStack {
                            LinearGradient(colors: [Color(red: 0.30, green: 0.30, blue: 0.32),
                                                    Color(red: 0.03, green: 0.03, blue: 0.05)],
                                           startPoint: .top, endPoint: .bottom)
                            Image(systemName: placeholderIcon)
                                .font(.system(size: 96))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
                .frame(width: 480, height: 480)
                .clipShape(RoundedRectangle(cornerRadius: TVDS.artwork, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)

                VStack(spacing: 6) {
                    Text(title).font(.title3).fontWeight(.bold)
                        .multilineTextAlignment(.center).lineLimit(2)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                .frame(width: 480)

                HStack(spacing: 20) {
                    Button {
                        if isVideos {
                            TVVideoController.shared.playDirect(tracks, from: 0, client: client, audio: player)
                        } else {
                            player.play(items: tracks, from: 0)
                        }
                        openNowPlaying()
                    } label: { Label("Play", systemImage: "play.fill") }
                    Button {
                        if isVideos {
                            TVVideoController.shared.playDirect(tracks.shuffled(), from: 0, client: client, audio: player)
                        } else {
                            player.play(items: tracks, from: 0, shuffled: true)
                        }
                        openNowPlaying()
                    } label: { Label("Shuffle", systemImage: "shuffle") }
                }
                .disabled(tracks.isEmpty)
            }

            // Right pane: the tracks.
            ScrollView {
                LazyVStack(spacing: 6) {
                    if isLoading {
                        ProgressView().padding(60)
                    } else if tracks.isEmpty {
                        Text("No songs here yet.")
                            .foregroundStyle(.secondary).padding(60)
                    } else {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                            TVSongRow(song: track, showArt: !isAlbum) {
                                if isVideos {
                                    TVVideoController.shared.playDirect(tracks, from: i, client: client, audio: player)
                                } else {
                                    player.play(items: tracks, from: i)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 40)
        .background { TVBackdrop(item: headerItem ?? tracks.first) }
        .task { await load() }
    }

    private var isAlbum: Bool { if case .album = collection { true } else { false } }

    private func load() async {
        switch collection {
        case .album(let a):    tracks = (try? await client.fetchAlbumTracks(albumId: a.id)) ?? []
        case .artist(let a):   tracks = (try? await client.fetchArtistSongs(artistId: a.id)) ?? []
        case .playlist(let p): tracks = (try? await client.fetchPlaylistItems(playlistId: p.id)) ?? []
        case .musicVideos:
            await TVVideoController.shared.loadLibrary(client: client)
            tracks = TVVideoController.shared.videos
        case .liked:
            let fetched = (try? await client.fetchFavoriteSongs()) ?? []
            client.favoriteIds = Set(fetched.map(\.id))
            client.reconcileLikedOrder(with: fetched.map(\.id))
            let rank = client.likeRank
            tracks = fetched.enumerated().sorted {
                let a = rank[$0.element.id] ?? Int.max
                let b = rank[$1.element.id] ?? Int.max
                return a != b ? a < b : $0.offset < $1.offset
            }.map(\.element)
        }
        isLoading = false
    }
}

// MARK: - Artist detail (avatar + albums grid)

/// Routes a TVCollection to the right detail — artists get the albums grid, everything else the
/// two-pane tracklist.
@ViewBuilder
func tvDestination(for collection: TVCollection) -> some View {
    if case .artist(let artist) = collection {
        TVArtistDetailView(artist: artist)
    } else {
        TVCollectionDetailView(collection: collection)
    }
}

struct TVArtistDetailView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @Environment(\.tvOpenNowPlaying) private var openNowPlaying
    let artist: MediaItem
    @State private var albums: [MediaItem] = []
    @State private var isLoading = true
    @State private var route: TVCollection?

    private let cols = [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 48)]

    var body: some View {
        ScrollView {
            VStack(spacing: 36) {
                // Header: circular avatar + name + play-all.
                VStack(spacing: 18) {
                    LibraryImage(url: client.artworkURL(for: artist, size: 600), maxPixel: 600) {
                        ZStack {
                            Color(white: 0.18)
                            Image(systemName: "music.mic")
                                .font(.system(size: 64, weight: .light))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 300, height: 300)
                    .clipShape(Circle())
                    .shadow(color: .black.opacity(0.4), radius: 24, y: 12)

                    Text(artist.name)
                        .font(.title3).fontWeight(.bold)

                    HStack(spacing: 20) {
                        Button { playAll(shuffled: false) } label: { Label("Play", systemImage: "play.fill") }
                        Button { playAll(shuffled: true) } label: { Label("Shuffle", systemImage: "shuffle") }
                    }
                }
                .padding(.top, 20)

                if isLoading {
                    ProgressView().padding(40)
                } else if !albums.isEmpty {
                    LazyVGrid(columns: cols, spacing: 48) {
                        ForEach(albums) { album in
                            TVCoverCell(item: album) { route = .album(album) }
                        }
                    }
                }
            }
            .padding(.horizontal, 60)
        }
        .background { TVBackdrop(item: artist) }
        .navigationDestination(item: $route) { tvDestination(for: $0) }
        .task {
            albums = (try? await client.fetchAlbums(artistId: artist.id)) ?? []
            isLoading = false
        }
    }

    private func playAll(shuffled: Bool) {
        Task {
            let songs = (try? await client.fetchArtistSongs(artistId: artist.id)) ?? []
            guard !songs.isEmpty else { return }
            player.play(items: songs, from: 0, shuffled: shuffled)
            openNowPlaying()
        }
    }
}
