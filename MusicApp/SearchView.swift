import SwiftUI

/// The search tab's root. Uses the native iOS 26 search experience: the tab is declared with
/// `role: .search` (RootTabView), so `.searchable` here renders as the bottom search field that morphs
/// out of the tab bar, Apple-Music style. Results stream in live as you type.
struct SearchView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var resultCache: [String: [MediaItem]] = [:]   // query → results, so repeats hit no network
    @State private var isSearching = false
    @State private var addRequest: PlaylistAddRequest?
    @State private var path = NavigationPath()
    @Namespace private var ns

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var albums:    [MediaItem] { results.filter { $0.type == "MusicAlbum" } }
    private var artists:   [MediaItem] { results.filter { $0.type == "MusicArtist" } }
    private var songs:     [MediaItem] { results.filter { $0.type == "Audio" } }
    private var playlists: [MediaItem] { results.filter { $0.type == "Playlist" } }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if trimmed.isEmpty {
                    centeredScroll { emptyPrompt }
                } else if isSearching && results.isEmpty {
                    centeredScroll { HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60) }
                } else if results.isEmpty {
                    centeredScroll { noResults }
                } else {
                    resultsList
                }
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: LibraryRoute.self) { route in
                destinationView(for: route)
                    .navigationTransition(.zoom(sourceID: route.id, in: ns))
            }
            .searchable(text: $query, prompt: "Artists, Albums, Songs")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .environment(\.zoomNamespace, ns)
        .environment(\.libraryPush) { path.append($0) }   // lets a song row's "Go to Artist" push here
        .sheet(item: $addRequest) { PlaylistPickerSheet(request: $0) }
        // Re-runs (and cancels the prior run) whenever the query changes — the sleep debounces.
        .task(id: query) {
            let anim = Animation.easeInOut(duration: 0.22)
            guard !trimmed.isEmpty else { withAnimation(anim) { results = []; isSearching = false }; return }
            if let cached = resultCache[trimmed] {          // repeat query → instant, no network competing with audio
                withAnimation(anim) { results = cached; isSearching = false }; return
            }
            isSearching = true
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            let found = (try? await client.search(query: trimmed)) ?? []
            guard !Task.isCancelled else { return }
            // When a search matches an artist, pull in that artist's albums + songs so they show too.
            var merged = found
            if let artist = found.first(where: { $0.type == "MusicArtist" }) {
                async let al = client.fetchAlbums(artistId: artist.id)
                async let so = client.fetchArtistSongs(artistId: artist.id)
                let artistAlbums = (try? await al) ?? []
                let artistSongs = Array(((try? await so) ?? []).prefix(40))
                var seen = Set(merged.map(\.id))
                for item in artistAlbums + artistSongs where seen.insert(item.id).inserted { merged.append(item) }
            }
            guard !Task.isCancelled else { return }
            resultCache[trimmed] = merged
            withAnimation(anim) { results = merged; isSearching = false }
        }
    }

    // MARK: - States

    private var emptyPrompt: some View {
        VStack(spacing: 14) {
            Image(systemName: "music.mic")
                .font(.system(size: 52, weight: .ultraLight))
                .foregroundStyle(.secondary)
            Text("Search your library")
                .font(.title3).fontWeight(.semibold)
            Text("Artists, albums, and songs")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
    }

    private var noResults: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 40, weight: .ultraLight))
                .foregroundStyle(.tertiary)
            Text("No results for “\(query)”")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .padding(.horizontal, DS.hPad)
    }

    // MARK: - Results

    private var resultsList: some View {
        List {
            if !artists.isEmpty {
                sectionLabel("Artists", icon: "person.fill").plainRow()
                ForEach(artists) { artist in
                    // A Button (not a List NavigationLink) so the row keeps its clean, chevron-free look.
                    Button { path.append(LibraryRoute.artist(artist)) } label: {
                        ArtistRow(artist: artist, large: true)
                    }
                    .buttonStyle(ScaleButtonStyle())
                    .matchedTransitionSource(id: LibraryRoute.artist(artist).id, in: ns)
                    .plainRow()
                }
            }

            if !albums.isEmpty {
                sectionLabel("Albums", icon: "square.stack").plainRow()
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: DS.gridSpacing) {
                        ForEach(albums) { album in
                            LibraryLink(route: .album(album)) {
                                AlbumCard(album: album).frame(width: 170)
                            }
                        }
                    }
                    .padding(.horizontal, DS.hPad)
                    .padding(.bottom, 4)
                }
                .plainRow()
            }

            if !playlists.isEmpty {
                sectionLabel("Playlists", icon: "music.note.list").plainRow()
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: DS.gridSpacing) {
                        ForEach(playlists) { playlist in
                            LibraryLink(route: .playlist(playlist)) {
                                AlbumCard(album: playlist).frame(width: 170)
                            }
                        }
                    }
                    .padding(.horizontal, DS.hPad)
                    .padding(.bottom, 4)
                }
                .plainRow()
            }

            if !songs.isEmpty {
                sectionLabel("Songs", icon: "music.note").plainRow()
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, showAlbumArt: true,
                            onTap: { player.play(items: songs, from: index) },
                            onPlayNext: { player.playNext(song) },
                            onPlayLast: { player.playLast(song) },
                            onAddToPlaylist: { addRequest = PlaylistAddRequest(itemIds: [song.id]) },
                            large: true)
                        .plainRow()
                        // Swipe a result straight into the queue — same gestures as the tracklists.
                        .trackSwipeActions(onPlayNext: { player.playNext(song) },
                                           onPlayLast: { player.playLast(song) })
                }
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.immediately)
    }

    private func centeredScroll<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        ScrollView { content() }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.immediately)
    }

    private func sectionLabel(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.footnote).fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.5)
            .padding(.horizontal, DS.hPad)
            .padding(.top, 18)
            .padding(.bottom, 6)
    }
}

private extension View {
    /// Strip the List's chrome so a search result row keeps the old free-form, edge-to-edge look
    /// (rows supply their own padding; section labels supply their own).
    func plainRow() -> some View {
        listRowInsets(EdgeInsets())
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }
}
