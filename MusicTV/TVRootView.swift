import SwiftUI

enum TVTab: Hashable { case home, albums, playlists, nowPlaying, search }

/// Top-level TV navigation: the tvOS tab bar with focus-driven browse tabs and Now Playing.
struct TVRootView: View {
    @Environment(Player.self) private var player
    @State private var tab: TVTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: TVTab.home) { TVHomeView() }
            Tab("Albums", systemImage: "square.stack.fill", value: TVTab.albums) { TVAlbumsView() }
            Tab("Playlists", systemImage: "music.note.list", value: TVTab.playlists) { TVPlaylistsView() }
            Tab("Now Playing", systemImage: "waveform", value: TVTab.nowPlaying) { TVNowPlayingView() }
            Tab("Search", systemImage: "magnifyingglass", value: TVTab.search, role: .search) { TVSearchView() }
        }
        // Starting playback anywhere jumps straight to Now Playing.
        .environment(\.tvOpenNowPlaying) { tab = .nowPlaying }
        // "Transfer to this device" floats top-right whenever another device is the one playing.
        .overlay(alignment: .topTrailing) {
            TransferButton()
                .padding(.trailing, 60)
                .padding(.top, 20)
        }
        // The channel bug IS the TV's mini bar: bottom-left on every page (Now Playing draws its own),
        // clicking it opens Now Playing. Mirrors another device's session when nothing plays here.
        .overlay(alignment: .bottomLeading) {
            if tab != .nowPlaying {
                Group {
                    if TVVideoController.shared.direct, let video = TVVideoController.shared.activeVideo {
                        // The Music Videos playlist keeps playing behind the browse UI.
                        Button { tab = .nowPlaying } label: {
                            TVNowPlayingBug(item: video,
                                            artistLine: video.primaryArtist,
                                            spinning: true)
                        }
                    } else if let item = player.currentItem {
                        Button { tab = .nowPlaying } label: {
                            TVNowPlayingBug(item: item,
                                            artistLine: item.primaryArtist,
                                            albumLine: item.album,
                                            spinning: player.isPlaying || TVVideoController.shared.activeVideo != nil)
                        }
                    } else if let remote = SessionHub.shared.remote {
                        Button { tab = .nowPlaying } label: {
                            TVNowPlayingBug(item: remote.item,
                                            artistLine: remote.item.primaryArtist,
                                            albumLine: "Playing on \(remote.deviceName)",
                                            spinning: !remote.isPaused)
                        }
                    }
                }
                .buttonStyle(.borderless)
                .padding(.leading, 70)
                .padding(.bottom, 60)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Home

struct TVHomeView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @Environment(\.tvOpenNowPlaying) private var openNowPlaying
    @State private var featured: [MediaItem] = []
    @State private var recentlyAdded: [MediaItem] = []
    @State private var mostPlayed: [MediaItem] = []
    @State private var playlists: [MediaItem] = []
    @State private var artists: [MediaItem] = []
    @State private var loaded = false
    @State private var route: TVCollection?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !featured.isEmpty {
                        TVShelf(title: "Featured", items: featured) { route = .album($0) }
                    }
                    if !recentlyAdded.isEmpty {
                        TVShelf(title: "New Releases", items: recentlyAdded) { route = .album($0) }
                    }
                    if !mostPlayed.isEmpty {
                        // Most Played is SONGS — tapping plays the run from that song and opens Now Playing.
                        TVShelf(title: "Most Played", items: mostPlayed) { song in
                            if let i = mostPlayed.firstIndex(of: song) {
                                player.play(items: mostPlayed, from: i)
                                openNowPlaying()
                            }
                        }
                    }
                    if !playlists.isEmpty {
                        TVShelf(title: "Playlists", items: playlists,
                                subtitle: { _ in "Playlist" }) { route = .playlist($0) }
                    }
                    if !artists.isEmpty {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Artists").font(.title3).fontWeight(.semibold)
                            ScrollView(.horizontal, showsIndicators: false) {
                                LazyHStack(alignment: .top, spacing: 40) {
                                    ForEach(artists) { artist in
                                        TVArtistCell(artist: artist) { route = .artist(artist) }
                                            .frame(width: 200)
                                    }
                                }
                                .padding(.vertical, 20)   // room for the focus lift
                            }
                            .scrollClipDisabled()
                        }
                    }
                    if !loaded { ProgressView().frame(maxWidth: .infinity).padding(60) }
                }
                .padding(.horizontal, 60)
            }
            .background { TVBackdrop(item: player.currentItem) }
            .navigationDestination(item: $route) { tvDestination(for: $0) }
            .task {
                guard !loaded else { return }
                async let feat = client.fetchFeatured(limit: 8)
                async let recent = client.fetchRecentlyAdded(limit: 12)
                async let most = client.fetchMostPlayed(limit: 12)
                async let lists = client.fetchPlaylists()
                async let arts = client.fetchArtists(limit: 24)
                featured = (try? await feat) ?? []
                recentlyAdded = (try? await recent) ?? []
                mostPlayed = (try? await most) ?? []
                playlists = (try? await lists) ?? []
                artists = (try? await arts) ?? []
                loaded = true
            }
        }
    }
}

// MARK: - Albums

struct TVAlbumsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var albums: [MediaItem] = []
    @State private var route: TVCollection?

    private let cols = [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 48)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 48) {
                    ForEach(albums) { album in
                        TVCoverCell(item: album) { route = .album(album) }
                    }
                }
                .padding(60)
            }
            .background { TVBackdrop(item: player.currentItem) }
            .navigationDestination(item: $route) { tvDestination(for: $0) }
            .task { if albums.isEmpty { albums = (try? await client.fetchAlbums()) ?? [] } }
        }
    }
}

// MARK: - Playlists

struct TVPlaylistsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var playlists: [MediaItem] = []
    @State private var route: TVCollection?

    private let cols = [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 48)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: cols, spacing: 48) {
                    // Liked Songs first, like the phone.
                    VStack(alignment: .leading, spacing: 12) {
                        Button { route = .liked } label: {
                            ZStack {
                                LinearGradient(colors: [Color(red: 0.30, green: 0.30, blue: 0.32),
                                                        Color(red: 0.03, green: 0.03, blue: 0.05)],
                                               startPoint: .top, endPoint: .bottom)
                                Image(systemName: "heart.fill")
                                    .font(.system(size: 72))
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            .aspectRatio(1, contentMode: .fill)
                        }
                        .buttonStyle(.borderless)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Liked Songs").font(.callout).lineLimit(1)
                            Text("\(client.favoriteIds.count) songs")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 4)
                    }

                    // All the library's music videos as one playlist.
                    if !TVVideoController.shared.videos.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Button { route = .musicVideos } label: {
                                ZStack {
                                    LinearGradient(colors: [Color(red: 0.16, green: 0.18, blue: 0.30),
                                                            Color(red: 0.03, green: 0.03, blue: 0.05)],
                                                   startPoint: .top, endPoint: .bottom)
                                    Image(systemName: "play.rectangle.fill")
                                        .font(.system(size: 72))
                                        .foregroundStyle(.white.opacity(0.9))
                                }
                                .aspectRatio(1, contentMode: .fill)
                            }
                            .buttonStyle(.borderless)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Music Videos").font(.callout).lineLimit(1)
                                Text("\(TVVideoController.shared.videos.count) videos")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 4)
                        }
                    }

                    ForEach(playlists) { p in
                        TVCoverCell(item: p, subtitle: "Playlist") { route = .playlist(p) }
                    }
                }
                .padding(60)
            }
            .background { TVBackdrop(item: player.currentItem) }
            .navigationDestination(item: $route) { tvDestination(for: $0) }
            .task {
                if playlists.isEmpty { playlists = (try? await client.fetchPlaylists()) ?? [] }
                await client.refreshFavorites()
                await TVVideoController.shared.loadLibrary(client: client)
            }
        }
    }
}

// MARK: - Search

struct TVSearchView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var route: TVCollection?

    private var albums: [MediaItem] { results.filter { $0.type == "MusicAlbum" } }
    private var songs: [MediaItem] { results.filter { $0.type == "Audio" } }

    private let cols = [GridItem(.adaptive(minimum: 260, maximum: 320), spacing: 48)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !albums.isEmpty {
                        Text("Albums").font(.title3).fontWeight(.semibold)
                        LazyVGrid(columns: cols, spacing: 48) {
                            ForEach(albums) { album in
                                TVCoverCell(item: album) { route = .album(album) }
                            }
                        }
                    }
                    if !songs.isEmpty {
                        Text("Songs").font(.title3).fontWeight(.semibold)
                        LazyVStack(spacing: 8) {
                            ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                                TVSongRow(song: song) { player.play(items: songs, from: i) }
                            }
                        }
                    }
                }
                .padding(60)
            }
            .background { TVBackdrop(item: player.currentItem) }
            .navigationDestination(item: $route) { tvDestination(for: $0) }
            .searchable(text: $query, prompt: "Artists, Albums, Songs")
            .task(id: query) {
                let q = query.trimmingCharacters(in: .whitespaces)
                guard !q.isEmpty else { results = []; return }
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
                results = (try? await client.search(query: q)) ?? []
            }
        }
    }
}
