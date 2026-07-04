import SwiftUI

enum TVTab: Hashable { case home, albums, playlists, nowPlaying, search }

/// Top-level TV navigation: the tvOS tab bar with focus-driven browse tabs and Now Playing.
struct TVRootView: View {
    @Environment(Player.self) private var player
    @State private var tab: TVTab = .home

    var body: some View {
        TabView(selection: $tab) {
            // Browse tabs reserve top clearance while the mini bar is showing, so pages START below
            // it (nav bar → mini bar → page) and scroll under its glass. Now Playing has no bar.
            Tab("Home", systemImage: "house.fill", value: TVTab.home) { TVHomeView().tvMiniBarClearance() }
            Tab("Albums", systemImage: "square.stack.fill", value: TVTab.albums) { TVAlbumsView().tvMiniBarClearance() }
            Tab("Playlists", systemImage: "music.note.list", value: TVTab.playlists) { TVPlaylistsView().tvMiniBarClearance() }
            Tab("Now Playing", systemImage: "waveform", value: TVTab.nowPlaying) { TVNowPlayingView() }
            Tab("Search", systemImage: "magnifyingglass", value: TVTab.search, role: .search) { TVSearchView().tvMiniBarClearance() }
        }
        // Starting playback anywhere jumps straight to Now Playing.
        .environment(\.tvOpenNowPlaying) { tab = .nowPlaying }
        // The Siri Remote play/pause button toggles playback from ANY tab / focus — including a track
        // restored (paused) at launch, where focus sits on the tab bar and never reached Now Playing's
        // own handler. The direct Music Videos playlist toggles the video; everything else the audio.
        .onPlayPauseCommand {
            let v = TVVideoController.shared
            v.direct ? v.togglePlayPause() : player.togglePlayPause()
        }
        // "Transfer to this device" floats top-right whenever another device is the one playing.
        .overlay(alignment: .topTrailing) {
            TransferButton()
                .padding(.trailing, 60)
                .padding(.top, 20)
        }
        // The mini bar: an iOS-MiniPlayer-style Liquid Glass bar top-CENTER, directly below the tvOS
        // tab bar and roughly its width. Hidden on the Now Playing tab, which has the full carousel
        // instead. Non-focusable chrome — no Buttons, so it never steals focus from the tab bar above.
        .overlay(alignment: .top) {
            let videoCtl = TVVideoController.shared
            Group {
                if tab == .nowPlaying {
                    EmptyView()
                } else if videoCtl.direct, let video = videoCtl.activeVideo {
                    TVNowPlayingBug(item: video, artistLine: video.primaryArtist, spinning: true)
                } else if let item = player.currentItem {
                    TVNowPlayingBug(item: item,
                                    artistLine: item.primaryArtist,
                                    albumLine: item.album,
                                    spinning: player.isPlaying || videoCtl.activeVideo != nil)
                } else if let remote = SessionHub.shared.remote {
                    TVNowPlayingBug(item: remote.item,
                                    artistLine: remote.item.primaryArtist,
                                    albumLine: "Playing on \(remote.deviceName)",
                                    spinning: !remote.isPaused)
                }
            }
            // ~57% of the screen matches the 5-item tab bar's span; 126pt clears the bar (~y40-110).
            .containerRelativeFrame(.horizontal) { length, _ in length * 0.57 }
            .padding(.top, 126)
            .allowsHitTesting(false)
        }
    }
}

/// Whether the mini bar is currently showing (mirrors TVRootView's overlay branches, minus the tab check).
@MainActor
func tvMiniBarShowing(_ player: Player) -> Bool {
    let videoCtl = TVVideoController.shared
    if videoCtl.direct, videoCtl.activeVideo != nil { return true }
    if player.currentItem != nil { return true }
    return SessionHub.shared.remote != nil
}

/// Reserves the mini bar's slot at the top of a browse page: the page lays out BELOW the bar (nav bar →
/// mini bar → content) and its content scrolls under the bar's glass, exactly like a nav bar.
private struct TVMiniBarClearance: ViewModifier {
    @Environment(Player.self) private var player
    func body(content: Content) -> some View {
        let showing = tvMiniBarShowing(player)
        content
            // Bar bottom sits at ~194 (126 top + 68 height); pages' own top safe area is ~60, so ~150
            // more puts the first row just under the bar with a small gap. contentMargins propagates
            // INTO the page's ScrollView (outer safeAreaPadding/safeAreaInset never reached it through
            // the NavigationStack), and content still scrolls under the bar's glass.
            .contentMargins(.top, showing ? 150 : 0, for: .scrollContent)
            .animation(.easeInOut(duration: 0.25), value: showing)
    }
}

extension View {
    func tvMiniBarClearance() -> some View { modifier(TVMiniBarClearance()) }
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
    @State private var showSettings = false

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
                                HStack(alignment: .top, spacing: 40) {
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
                    if !loaded {
                        ProgressView().frame(maxWidth: .infinity).padding(60)
                    } else {
                        // Same as the iPhone home: a quiet Settings entry at the very bottom.
                        Button("Settings") { showSettings = true }
                            .font(.callout)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 20)
                            .padding(.bottom, 40)
                    }
                }
                .padding(.horizontal, 60)
            }
            .background { TVBackdrop(item: player.currentItem) }
            .navigationDestination(item: $route) { tvDestination(for: $0) }
            .sheet(isPresented: $showSettings) { TVSettingsView() }
            .task {
                guard !loaded else { return }
                async let feat = client.fetchFeatured(limit: 8)
                async let recent = client.fetchRecentlyAdded(limit: 12)
                async let most = client.fetchMostPlayed(limit: 12)
                async let lists = client.fetchPlaylists()
                async let arts = client.fetchArtists(limit: 24)
                // Gather everything FIRST, then commit in one mutation: six staggered state flips
                // (plus the spinner's removal) landing mid-first-layout tripped SwiftUI's
                // DynamicContainerInfo.tryRemovingItem assert (the flaky launch crash on Home).
                let f = (try? await feat) ?? []
                let r = (try? await recent) ?? []
                let m = (try? await most) ?? []
                let p = (try? await lists) ?? []
                let a = (try? await arts) ?? []
                featured = f
                recentlyAdded = r
                mostPlayed = m
                playlists = p
                artists = a
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
                    TVGradientTile(title: "Liked Songs",
                                   subtitle: "\(client.favoriteIds.count) songs",
                                   icon: "heart.fill",
                                   top: Color(red: 0.30, green: 0.30, blue: 0.32)) { route = .liked }

                    // All the library's music videos as one playlist.
                    if !TVVideoController.shared.videos.isEmpty {
                        TVGradientTile(title: "Music Videos",
                                       subtitle: "\(TVVideoController.shared.videos.count) videos",
                                       icon: "play.rectangle.fill",
                                       top: Color(red: 0.16, green: 0.18, blue: 0.30)) { route = .musicVideos }
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

// MARK: - Gradient tile (Liked Songs / Music Videos)

/// A synthetic playlist tile (gradient + icon) that focuses exactly like a TVCoverCard: bare button
/// (no system white platter), 1.08 magnification + shadow.
struct TVGradientTile: View {
    let title: String
    let subtitle: String
    let icon: String
    let top: Color
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button(action: action) {
                ZStack {
                    LinearGradient(colors: [top, Color(red: 0.03, green: 0.03, blue: 0.05)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: icon)
                        .font(.system(size: 72))
                        .foregroundStyle(.white.opacity(0.9))
                }
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: TVDS.cover, style: .continuous))
            }
            .buttonStyle(.tvBare)
            .focused($focused)
            .scaleEffect(focused ? 1.08 : 1.0)
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: focused ? 22 : 0, y: focused ? 14 : 0)
            .animation(.easeOut(duration: 0.18), value: focused)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)
        }
    }
}
