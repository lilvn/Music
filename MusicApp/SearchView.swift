import SwiftUI
import UIKit

/// A wrapped `UISearchBar` so we control the keyboard: NO predictive/QuickType suggestions bar, and
/// the return key is a "Done" key that closes the keyboard (search runs live as you type, so the
/// return key never needs to "search").
struct SearchField: UIViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeUIView(context: Context) -> UISearchBar {
        let bar = UISearchBar()
        bar.placeholder = placeholder
        bar.searchBarStyle = .minimal
        bar.autocapitalizationType = .none
        bar.autocorrectionType = .no
        bar.spellCheckingType = .no
        bar.returnKeyType = .done
        bar.enablesReturnKeyAutomatically = false
        let field = bar.searchTextField
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.inlinePredictionType = .no      // no inline QuickType predictions
        field.smartDashesType = .no
        field.smartQuotesType = .no
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UISearchBar, context: Context) {
        if bar.text != text { bar.text = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UISearchBarDelegate {
        var parent: SearchField
        init(_ parent: SearchField) { self.parent = parent }

        func searchBar(_ searchBar: UISearchBar, textDidChange searchText: String) {
            parent.text = searchText
        }
        // The "Done" return key just closes the keyboard.
        func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
            searchBar.resignFirstResponder()
        }
    }
}

/// The search tab's root. A custom search field (top), live results below; result taps push with the
/// same zoom card-expand as the rest of the app.
struct SearchView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var isSearching = false
    @State private var addRequest: PlaylistAddRequest?
    @Namespace private var ns

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var albums:  [MediaItem] { results.filter { $0.type == "MusicAlbum" } }
    private var artists: [MediaItem] { results.filter { $0.type == "MusicArtist" } }
    private var songs:   [MediaItem] { results.filter { $0.type == "Audio" } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SearchField(text: $query, placeholder: "Artists, Albums, Songs")
                    .padding(.horizontal, 10)
                    .padding(.top, 4)
                    .padding(.bottom, 2)

                ScrollView {
                    if trimmed.isEmpty {
                        emptyPrompt
                    } else if isSearching && results.isEmpty {
                        HStack { Spacer(); ProgressView(); Spacer() }.padding(.top, 60)
                    } else if results.isEmpty {
                        noResults
                    } else {
                        searchResults
                    }
                }
                .scrollIndicators(.hidden)
                .scrollDismissesKeyboard(.immediately)
                // Tap anywhere in the results area (not the field) to close the keyboard.
                .simultaneousGesture(TapGesture().onEnded { dismissKeyboard() })
            }
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: LibraryRoute.self) { route in
                destinationView(for: route)
                    .navigationTransition(.zoom(sourceID: route.id, in: ns))
            }
        }
        .environment(\.zoomNamespace, ns)
        .sheet(item: $addRequest) { PlaylistPickerSheet(request: $0) }
        // Re-runs (and cancels the prior run) whenever the query changes — the sleep debounces.
        .task(id: query) {
            guard !trimmed.isEmpty else { results = []; isSearching = false; return }
            isSearching = true
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            results = (try? await client.search(query: trimmed)) ?? []
            isSearching = false
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

    private var searchResults: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            if !artists.isEmpty {
                sectionLabel("Artists", icon: "person.fill")
                ForEach(artists) { artist in
                    LibraryLink(route: .artist(artist)) {
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
                            LibraryLink(route: .album(album)) {
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
                            onTap: { player.play(items: songs, from: index) },
                            onPlayNext: { player.playNext(song) },
                            onPlayLast: { player.playLast(song) },
                            onAddToPlaylist: { addRequest = PlaylistAddRequest(itemIds: [song.id]) },
                            large: true)
                    if index < songs.count - 1 {
                        Divider().padding(.leading, DS.hPad + 56 + 12)
                    }
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 24)
    }

    private func dismissKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
