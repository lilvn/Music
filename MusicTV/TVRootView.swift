import SwiftUI

enum TVTab: Hashable { case home, albums, playlists, nowPlaying, search }

/// Top-level TV navigation — a CUSTOM nav bar (the system tab bar is hidden): browse pills + the mini
/// bar as its own pill standing in for Now Playing (click = open it), a separated Search pill, and the
/// Transfer button — all focusable in one bar, iOS-style. The TabView below only hosts the pages.
struct TVRootView: View {
    @Environment(Player.self) private var player
    @State private var tab: TVTab = .home
    /// Focus lives INSIDE the mini bar's expanded transport (nav pills hidden, Menu collapses it).
    @State private var engaged = false

    var body: some View {
        // The bar OVERLAYS the pages (ZStack, not a VStack): page backgrounds — the Now Playing
        // artwork wash, a playing video — run full-bleed behind the glass bar instead of dying at a
        // black header band. Pages clear the bar via scroll-content margins (which DO propagate into
        // their ScrollViews, incl. detail pages), so content still starts below it and scrolls under.
        ZStack(alignment: .top) {
            TabView(selection: $tab) {
                Tab("Home", systemImage: "house.fill", value: TVTab.home) {
                    TVHomeView().toolbar(.hidden, for: .tabBar).contentMargins(.top, 110, for: .scrollContent)
                }
                Tab("Albums", systemImage: "square.stack.fill", value: TVTab.albums) {
                    TVAlbumsView().toolbar(.hidden, for: .tabBar).contentMargins(.top, 110, for: .scrollContent)
                }
                Tab("Playlists", systemImage: "music.note.list", value: TVTab.playlists) {
                    TVPlaylistsView().toolbar(.hidden, for: .tabBar).contentMargins(.top, 110, for: .scrollContent)
                }
                Tab("Now Playing", systemImage: "waveform", value: TVTab.nowPlaying) {
                    TVNowPlayingView().toolbar(.hidden, for: .tabBar)
                }
                Tab("Search", systemImage: "magnifyingglass", value: TVTab.search, role: .search) {
                    TVSearchView().toolbar(.hidden, for: .tabBar).contentMargins(.top, 110, for: .scrollContent)
                }
            }

            TVNavBar(tab: $tab, engaged: $engaged)
        }
        .background(Color.black.ignoresSafeArea())
        // Starting playback anywhere jumps straight to Now Playing with the transport open.
        .environment(\.tvOpenNowPlaying) { tab = .nowPlaying; engaged = true }
        .onChange(of: tab) { _, t in if t != .nowPlaying { engaged = false } }
        // The Siri Remote play/pause button toggles playback from ANY tab / focus — including a track
        // restored (paused) at launch, where focus never reached Now Playing's own handler. The direct
        // Music Videos playlist toggles the video; everything else the audio.
        .onPlayPauseCommand {
            let v = TVVideoController.shared
            v.direct ? v.togglePlayPause() : player.togglePlayPause()
        }
    }
}

// MARK: - The custom nav bar

/// Home / Albums / Playlists in one glass capsule, the mini bar as its OWN separate pill (like iOS),
/// Search as another separated pill, and the Transfer button — everything focusable, ALWAYS visible.
/// Clicking the mini bar expands just that pill into the transport (`engaged`) with focus moving
/// inside to previous / play-pause / next / lyrics / queue / scrub; the other nav pills stay around
/// it, so swiping left (or Menu) goes straight back to navigating.
private struct TVNavBar: View {
    @Binding var tab: TVTab
    @Binding var engaged: Bool

    var body: some View {
        HStack(spacing: 18) {
            HStack(spacing: 4) {
                TVNavTextItem(title: "Home", selected: tab == .home) { tab = .home }
                TVNavTextItem(title: "Albums", selected: tab == .albums) { tab = .albums }
                TVNavTextItem(title: "Playlists", selected: tab == .playlists) { tab = .playlists }
            }
            .padding(5)
            .glassEffect(.regular, in: .capsule)

            if engaged {
                // The mini bar, expanded into the transport — in place, between its neighbours.
                TVNavTransportPill(engaged: $engaged)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            } else {
                // The mini bar: its own pill. FOCUS = show Now Playing; CLICK = enter the transport.
                TVNavMiniPill(selected: tab == .nowPlaying,
                              onSelect: { tab = .nowPlaying },
                              onClick: { engage in
                                  tab = .nowPlaying
                                  if engage { engaged = true }
                              })
                .padding(5)
                .glassEffect(.regular, in: .capsule)
            }

            // Search — a separated pill, like the iOS search tab.
            TVNavIconItem(icon: "magnifyingglass", selected: tab == .search) { tab = .search }
                .padding(5)
                .glassEffect(.regular, in: .capsule)

            // Focusable here in the bar (its old floating overlay was unreachable by the focus engine).
            TransferButton()
        }
        .focusSection()
        .frame(maxWidth: .infinity)
        .padding(.top, 24)
        .padding(.bottom, 12)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: engaged)
    }
}

/// A text tab pill: white capsule + black text when focused (the system tab bar look), subtle white
/// wash when it's the selected tab. FOCUSING it switches the page (like the system tab bar) — no
/// click needed.
private struct TVNavTextItem: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout).fontWeight(.medium)
                .foregroundStyle(focused ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                .padding(.horizontal, 26)
                .padding(.vertical, 12)
                .background(
                    Capsule().fill(focused ? AnyShapeStyle(.white)
                                   : selected ? AnyShapeStyle(.white.opacity(0.16))
                                   : AnyShapeStyle(.clear))
                )
        }
        .buttonStyle(.tvBare)
        .focused($focused)
        .onChange(of: focused) { _, f in if f { action() } }   // focus = select, system-tab-bar style
        .animation(.easeOut(duration: 0.15), value: focused)
    }
}

/// An icon pill (Search) with the same focus-switches-page treatment as the text items.
private struct TVNavIconItem: View {
    let icon: String
    let selected: Bool
    let action: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.body.weight(.semibold))
                .foregroundStyle(focused ? AnyShapeStyle(.black) : AnyShapeStyle(.primary))
                .padding(14)
                .background(
                    Circle().fill(focused ? AnyShapeStyle(.white)
                                  : selected ? AnyShapeStyle(.white.opacity(0.16))
                                  : AnyShapeStyle(.clear))
                )
        }
        .buttonStyle(.tvBare)
        .focused($focused)
        .onChange(of: focused) { _, f in if f { action() } }   // focus = select
        .animation(.easeOut(duration: 0.15), value: focused)
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
