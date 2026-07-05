import SwiftUI

enum TVTab: Hashable { case home, albums, playlists, nowPlaying, search }

/// Top-level TV navigation — the NATIVE tvOS tab bar, nothing custom: five tabs, system Liquid
/// Glass, system focus/auto-hide behavior. Now Playing is a plain tab (the native player lives
/// inside it); no mini bar.
struct TVRootView: View {
    @Environment(Player.self) private var player
    @Environment(\.colorScheme) private var colorScheme
    @State private var tab: TVTab = .home

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: TVTab.home) { TVHomeView() }
            Tab("Albums", systemImage: "square.stack.fill", value: TVTab.albums) { TVAlbumsView() }
            Tab("Playlists", systemImage: "music.note.list", value: TVTab.playlists) { TVPlaylistsView() }
            Tab("Now Playing", systemImage: "waveform", value: TVTab.nowPlaying) { TVNowPlayingView() }
            Tab("Search", systemImage: "magnifyingglass", value: TVTab.search, role: .search) { TVSearchView() }
        }
        // Dark mode = TRUE BLACK (OLED), not the system's dark gray; light mode stays system.
        .background {
            if colorScheme == .dark {
                Color.black.ignoresSafeArea()
            }
        }
        // Starting playback anywhere jumps straight to Now Playing.
        .environment(\.tvOpenNowPlaying) { tab = .nowPlaying }
        // The Siri Remote play/pause button toggles playback from ANY tab / focus — including a track
        // restored (paused) at launch. The direct Music Videos playlist toggles the video; everything
        // else the audio.
        .onPlayPauseCommand {
            let v = TVVideoController.shared
            v.direct ? v.togglePlayPause() : player.togglePlayPause()
        }
        // HOLD the Menu button anywhere → Transfer Here (same rules as the button: another device is
        // playing, we're not, and it's not a video-only session). Jumps to Now Playing when it lands.
        .background {
            TVMenuHoldTransfer {
                let hub = SessionHub.shared
                guard let remote = hub.remote, !hub.transferring,
                      !player.isPlaying, remote.item.type != "MusicVideo" else { return }
                hub.transferHere()
                tab = .nowPlaying
            }
            .frame(width: 0, height: 0)
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
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !featured.isEmpty {
                        // The iPhone's Featured section: skeuomorphic covers, the playing album's CD
                        // slid out and spinning. Click plays; click the current one to open it.
                        TVFeaturedCarousel(items: featured) { album, isCurrent in
                            if isCurrent {
                                route = .album(album)
                            } else {
                                Task {
                                    let tracks = (try? await client.fetchAlbumTracks(albumId: album.id)) ?? []
                                    if !tracks.isEmpty { player.play(items: tracks, from: 0) }
                                }
                            }
                        }
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
                        // Same as the iPhone home: a quiet Settings entry at the very bottom — its own
                        // focus section so swiping DOWN from the artists shelf lands on it directly.
                        Button { showSettings = true } label: {
                            Label("Settings", systemImage: "gearshape.fill")
                                .font(.callout)
                        }
                        .buttonStyle(.glass)
                        .buttonBorderShape(.capsule)
                        .frame(maxWidth: .infinity)
                        .focusSection()
                        .padding(.top, 24)
                        .padding(.bottom, 48)
                    }
                }
                .padding(.horizontal, 60)
            }
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

// MARK: - Hold Menu → Transfer Here

/// Installs a window-level long-press recognizer for the Siri Remote's MENU button: holding it down
/// anywhere in the app pulls the remote session onto this TV ("Transfer Here") — the couch shortcut
/// for the button on the remote-mirror page. A short Menu press keeps its normal back behavior.
struct TVMenuHoldTransfer: UIViewRepresentable {
    let action: () -> Void

    func makeUIView(context: Context) -> InstallerView {
        let v = InstallerView()
        v.isUserInteractionEnabled = false
        v.onWindow = { window in
            guard context.coordinator.recognizer == nil else { return }
            let r = UILongPressGestureRecognizer(target: context.coordinator,
                                                 action: #selector(Coordinator.fire(_:)))
            r.allowedPressTypes = [NSNumber(value: UIPress.PressType.menu.rawValue)]
            r.minimumPressDuration = 0.7
            window.addGestureRecognizer(r)
            context.coordinator.recognizer = r
        }
        return v
    }

    func updateUIView(_ uiView: InstallerView, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    static func dismantleUIView(_ uiView: InstallerView, coordinator: Coordinator) {
        if let r = coordinator.recognizer { r.view?.removeGestureRecognizer(r) }
        coordinator.recognizer = nil
    }

    final class Coordinator: NSObject {
        var action: () -> Void
        var recognizer: UILongPressGestureRecognizer?
        init(action: @escaping () -> Void) { self.action = action }
        @objc func fire(_ r: UILongPressGestureRecognizer) {
            if r.state == .began { action() }
        }
    }

    /// A zero-size helper that hands us the window the moment it joins one.
    final class InstallerView: UIView {
        var onWindow: ((UIWindow) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let window { onWindow?(window) }
        }
    }
}
