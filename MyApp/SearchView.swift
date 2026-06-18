import SwiftUI

/// The Search tab. On iOS 26 the `.search`-role tab morphs the tab bar into a search field at
/// the bottom (with the keyboard); results render here and tapping a card expands it into a sheet.
struct SearchTabView: View {
    @EnvironmentObject var api: JellyfinAPI
    @EnvironmentObject var player: AudioPlayerManager

    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var pickerTrack: MediaItem?

    private var albums:  [MediaItem] { results.filter { $0.type == "MusicAlbum" } }
    private var artists: [MediaItem] { results.filter { $0.type == "MusicArtist" } }
    private var songs:   [MediaItem] { results.filter { $0.type == "Audio" } }
    private let songDividerLeading: CGFloat = DS.hPad + 46 + 12

    var body: some View {
        NavigationStack {
            ScrollView {
                if query.isEmpty {
                    emptyPrompt
                } else if isSearching && results.isEmpty {
                    HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
                } else if results.isEmpty {
                    noResults
                } else {
                    searchResults
                }
                Color.clear.frame(height: DS.bottomClearance)
            }
            .scrollDismissesKeyboard(.immediately)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.large)
            .cardNavigation()
        }
        .searchable(text: $query, prompt: "Artists, albums, and songs")
        .autocorrectionDisabled()
        .sheet(item: $pickerTrack) { PlaylistPickerSheet(track: $0) }
        .onChange(of: query) { _, new in
            searchTask?.cancel()
            guard !new.trimmingCharacters(in: .whitespaces).isEmpty else {
                results = []
                return
            }
            searchTask = Task {
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                await runSearch(query: new)
            }
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
            Text("No results for \"\(query)\"")
                .font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 70)
        .padding(.horizontal, DS.hPad)
    }

    // MARK: - Results

    private var searchResults: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if !artists.isEmpty {
                sectionLabel("Artists", icon: "person.fill")
                ForEach(artists) { artist in
                    NavCard(route: .artist(artist)) {
                        ArtistRow(artist: artist, large: true)
                    }
                    Divider().padding(.leading, DS.hPad + 66 + 14)
                }
            }

            if !albums.isEmpty {
                sectionLabel("Albums", icon: "square.stack")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: DS.gridSpacing) {
                        ForEach(albums) { album in
                            NavCard(route: .album(album)) {
                                AlbumCard(album: album).frame(width: 170)
                            }
                        }
                    }
                    .padding(.horizontal, DS.hPad)
                    .padding(.bottom, 4)
                }
                .padding(.top, 4)
                .padding(.bottom, 8)
            }

            if !songs.isEmpty {
                sectionLabel("Songs", icon: "music.note")
                ForEach(Array(songs.enumerated()), id: \.element.id) { index, song in
                    SongRow(song: song, showAlbumArt: true,
                            onTap: { player.play(items: songs, from: index, api: api) },
                            onPlayNext: { player.playNext(song, api: api) },
                            onPlayLast: { player.playLast(song, api: api) },
                            onAddToPlaylist: { pickerTrack = song },
                            large: true)
                    if index < songs.count - 1 {
                        Divider().padding(.leading, songDividerLeading + 10)
                    }
                }
            }
        }
        .padding(.top, 8)
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

    private func runSearch(query: String) async {
        isSearching = true
        results = (try? await api.search(query: query)) ?? []
        isSearching = false
    }
}
