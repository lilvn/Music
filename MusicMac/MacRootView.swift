import SwiftUI

enum MacSection: Hashable {
    case home, albums, playlists, liked, search
}

/// The Mac shell: a native NavigationSplitView (sidebar + detail) with the mini player as a Liquid
/// Glass bar along the bottom of the detail area — CD + title + transport + the artwork-wash fill
/// as the progress, exactly the phone's mini bar grown up. Cross-device is seamless: another
/// device's playback shows identically; the toolbar's Transfer button is the only tell.
struct MacRootView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var section: MacSection = .home
    @State private var showNowPlaying = false

    var body: some View {
        NavigationSplitView {
            List(selection: $section) {
                Section("Library") {
                    Label("Home", systemImage: "house.fill").tag(MacSection.home)
                    Label("Albums", systemImage: "square.stack.fill").tag(MacSection.albums)
                    Label("Playlists", systemImage: "music.note.list").tag(MacSection.playlists)
                    Label("Liked Songs", systemImage: "heart.fill").tag(MacSection.liked)
                    Label("Search", systemImage: "magnifyingglass").tag(MacSection.search)
                }
            }
            .navigationSplitViewColumnWidth(min: 190, ideal: 210, max: 280)
        } detail: {
            detailPage
                .navigationTitle("")
        }
        // The mini bar floats over the bottom of the whole window, like the phone's accessory.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacMiniBar(showNowPlaying: $showNowPlaying)
                .padding(.horizontal, 16)
                .padding(.bottom, 10)
                .padding(.top, 4)
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                MacTransferButton()
            }
        }
        .sheet(isPresented: $showNowPlaying) {
            MacNowPlayingView()
                .environment(client)
                .environment(player)
        }
    }

    @ViewBuilder
    private var detailPage: some View {
        switch section {
        case .home:      MacHomeView()
        case .albums:    MacAlbumsView()
        case .playlists: MacPlaylistsView()
        case .liked:     MacLikedView()
        case .search:    MacSearchView()
        }
    }
}

/// "Transfer here" for the Mac toolbar — the one visible difference when another device plays.
struct MacTransferButton: View {
    @Environment(Player.self) private var player
    private var hub: SessionHub { SessionHub.shared }

    var body: some View {
        if let remote = hub.remote, !player.isPlaying, remote.item.type != "MusicVideo" {
            Button {
                hub.transferHere()
            } label: {
                if hub.transferring {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Transfer Here", systemImage: "airplayaudio")
                }
            }
            .disabled(hub.transferring)
            .help("Transfer playback from \(remote.deviceName) to this Mac")
        }
    }
}

// MARK: - Pages

struct MacHomeView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var featured: [MediaItem] = []
    @State private var recent: [MediaItem] = []
    @State private var mostPlayed: [MediaItem] = []
    @State private var playlists: [MediaItem] = []
    @State private var loaded = false
    @State private var route: MediaItem?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                if !featured.isEmpty {
                    MacShelf(title: "Featured", items: featured) { route = $0 }
                }
                if !recent.isEmpty {
                    MacShelf(title: "New Releases", items: recent) { route = $0 }
                }
                if !mostPlayed.isEmpty {
                    MacShelf(title: "Most Played", items: mostPlayed) { song in
                        if let i = mostPlayed.firstIndex(of: song) {
                            player.play(items: mostPlayed, from: i)
                        }
                    }
                }
                if !playlists.isEmpty {
                    MacShelf(title: "Playlists", items: playlists, subtitle: { _ in "Playlist" }) { route = $0 }
                }
                if !loaded { ProgressView().frame(maxWidth: .infinity).padding(40) }
            }
            .padding(24)
        }
        .navigationDestination(item: $route) { item in
            MacCollectionDetailView(collection: item)
        }
        .task {
            guard !loaded else { return }
            async let feat = client.fetchFeatured(limit: 10)
            async let rec = client.fetchRecentlyAdded(limit: 14)
            async let most = client.fetchMostPlayed(limit: 14)
            async let lists = client.fetchPlaylists()
            featured = (try? await feat) ?? []
            recent = (try? await rec) ?? []
            mostPlayed = (try? await most) ?? []
            playlists = (try? await lists) ?? []
            loaded = true
        }
    }
}

struct MacAlbumsView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var albums: [MediaItem] = []
    @State private var route: MediaItem?

    private let cols = [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 24) {
                ForEach(albums) { album in
                    MacCoverCard(item: album) { route = album }
                }
            }
            .padding(24)
        }
        .navigationDestination(item: $route) { MacCollectionDetailView(collection: $0) }
        .task { if albums.isEmpty { albums = (try? await client.fetchAlbums()) ?? [] } }
    }
}

struct MacPlaylistsView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var playlists: [MediaItem] = []
    @State private var route: MediaItem?

    private let cols = [GridItem(.adaptive(minimum: 160, maximum: 210), spacing: 20)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: cols, spacing: 24) {
                ForEach(playlists) { p in
                    MacCoverCard(item: p, subtitle: "Playlist") { route = p }
                }
            }
            .padding(24)
        }
        .navigationDestination(item: $route) { MacCollectionDetailView(collection: $0) }
        .task { if playlists.isEmpty { playlists = (try? await client.fetchPlaylists()) ?? [] } }
    }
}

struct MacLikedView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                MacTrackList(tracks: tracks, title: "Liked Songs", subtitle: "\(tracks.count) songs")
            }
        }
        .task {
            let fetched = (try? await client.fetchFavoriteSongs()) ?? []
            client.favoriteIds = Set(fetched.map(\.id))
            client.reconcileLikedOrder(with: fetched.map(\.id))
            let rank = client.likeRank
            tracks = fetched.enumerated().sorted {
                let a = rank[$0.element.id] ?? Int.max
                let b = rank[$1.element.id] ?? Int.max
                return a != b ? a < b : $0.offset < $1.offset
            }.map(\.element)
            isLoading = false
        }
    }
}

struct MacSearchView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var route: MediaItem?

    private var albums: [MediaItem] { results.filter { $0.type == "MusicAlbum" } }
    private var songs: [MediaItem] { results.filter { $0.type == "Audio" } }
    private let cols = [GridItem(.adaptive(minimum: 150, maximum: 200), spacing: 20)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if !albums.isEmpty {
                    Text("Albums").font(.title3).fontWeight(.semibold)
                    LazyVGrid(columns: cols, spacing: 22) {
                        ForEach(albums) { album in
                            MacCoverCard(item: album) { route = album }
                        }
                    }
                }
                if !songs.isEmpty {
                    Text("Songs").font(.title3).fontWeight(.semibold)
                    LazyVStack(spacing: 2) {
                        ForEach(Array(songs.enumerated()), id: \.element.id) { i, song in
                            MacSongRow(song: song, index: nil) { player.play(items: songs, from: i) }
                        }
                    }
                }
            }
            .padding(24)
        }
        .searchable(text: $query, prompt: "Artists, Albums, Songs")
        .navigationDestination(item: $route) { MacCollectionDetailView(collection: $0) }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty else { results = []; return }
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            results = (try? await client.search(query: q)) ?? []
        }
    }
}

// MARK: - Detail (album / playlist)

struct MacCollectionDetailView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    let collection: MediaItem
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true

    private var isPlaylist: Bool { collection.type == "Playlist" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .bottom, spacing: 24) {
                    LibraryImage(url: client.artworkURL(for: collection, size: 600), maxPixel: 600) {
                        MacPlaceholder()
                    }
                    .frame(width: 220, height: 220)
                    .clipShape(RoundedRectangle(cornerRadius: MacDS.artwork, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 16, y: 8)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(collection.name).font(.largeTitle).fontWeight(.bold).lineLimit(2)
                        Text(isPlaylist ? "Playlist" : (collection.albumArtist ?? collection.primaryArtist))
                            .font(.title3).foregroundStyle(.secondary)
                        Text("\(tracks.count) songs")
                            .font(.callout).foregroundStyle(.tertiary)

                        HStack(spacing: 10) {
                            Button {
                                player.play(items: tracks, from: 0)
                            } label: {
                                Label("Play", systemImage: "play.fill")
                                    .padding(.horizontal, 18).padding(.vertical, 7)
                            }
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .buttonStyle(.plain)

                            Button {
                                player.play(items: tracks, from: 0, shuffled: true)
                            } label: {
                                Label("Shuffle", systemImage: "shuffle")
                                    .padding(.horizontal, 18).padding(.vertical, 7)
                            }
                            .glassEffect(.regular.interactive(), in: .capsule)
                            .buttonStyle(.plain)
                        }
                        .padding(.top, 8)
                        .disabled(tracks.isEmpty)
                    }
                }

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(30)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                            MacSongRow(song: track, index: isPlaylist ? nil : (track.indexNumber ?? i + 1)) {
                                player.play(items: tracks, from: i)
                            }
                        }
                    }
                }
            }
            .padding(24)
        }
        .task {
            if collection.type == "MusicAlbum" {
                tracks = (try? await client.fetchAlbumTracks(albumId: collection.id)) ?? []
            } else {
                tracks = (try? await client.fetchPlaylistItems(playlistId: collection.id)) ?? []
            }
            isLoading = false
        }
    }
}

// MARK: - Track rows / list

struct MacSongRow: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    let song: MediaItem
    var index: Int? = nil
    let action: () -> Void
    @State private var hovering = false

    private var isCurrent: Bool { player.currentItem?.id == song.id }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                if let index {
                    Text("\(index)")
                        .font(.footnote).monospacedDigit().foregroundStyle(.tertiary)
                        .frame(width: 24, alignment: .trailing)
                } else {
                    LibraryImage(url: client.artworkURL(for: song, size: 100), maxPixel: 100) {
                        MacPlaceholder()
                    }
                    .frame(width: 34, height: 34)
                    .clipShape(RoundedRectangle(cornerRadius: MacDS.thumb, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(song.name)
                        .fontWeight(isCurrent ? .semibold : .regular)
                        .lineLimit(1)
                    Text(song.primaryArtist)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if isCurrent {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .foregroundStyle(.secondary)
                }
                if let d = song.durationSeconds {
                    Text(d.formattedDuration)
                        .font(.caption).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: MacDS.thumb, style: .continuous)
                .fill(hovering ? Color.primary.opacity(0.07) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .contextMenu {
            Button { player.playNext(song) } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            Button { player.playLast(song) } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
            Button {
                let liked = client.favoriteIds.contains(song.id)
                Task { await client.setFavorite(song.id, !liked) }
            } label: {
                Label(client.favoriteIds.contains(song.id) ? "Unlike" : "Add to Liked Songs",
                      systemImage: client.favoriteIds.contains(song.id) ? "heart.slash" : "heart")
            }
        }
    }
}

struct MacTrackList: View {
    @Environment(Player.self) private var player
    let tracks: [MediaItem]
    let title: String
    let subtitle: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.largeTitle).fontWeight(.bold)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                LazyVStack(spacing: 2) {
                    ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                        MacSongRow(song: track, index: nil) { player.play(items: tracks, from: i) }
                    }
                }
            }
            .padding(24)
        }
    }
}
