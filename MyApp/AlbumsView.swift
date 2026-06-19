import SwiftUI

struct AlbumsView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var albums: [MediaItem] = []
    @State private var genres: [MediaItem] = []
    @State private var selectedGenreId: String?
    @State private var isLoading = false
    @State private var loadFailed = false

    private let cols = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: DS.gridSpacing)]

    var body: some View {
        LibraryStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if !genres.isEmpty { genreFilter }
                    albumsContent
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Albums")
            .task { await initialLoad() }
        }
    }

    @ViewBuilder
    private var albumsContent: some View {
        if albums.isEmpty && isLoading {
            CenteredState(systemImage: nil, title: "Loading", loading: true)
        } else if albums.isEmpty && loadFailed {
            CenteredState(systemImage: "wifi.exclamationmark", title: "Couldn't load albums") {
                Button("Try Again") { Task { await loadAlbums() } }.buttonStyle(.bordered)
            }
        } else if albums.isEmpty {
            CenteredState(systemImage: "square.stack",
                          title: selectedGenreId == nil ? "No albums in your library" : "No albums in this genre")
        } else {
            LazyVGrid(columns: cols, spacing: DS.gridSpacing + 4) {
                ForEach(albums) { album in
                    LibraryLink(route: .album(album)) { AlbumCard(album: album) }
                }
            }
            .padding(.horizontal, DS.gridPad)
            .padding(.top, 4)
        }
    }

    // Horizontal genre chips; tap to filter the album grid by genre.
    private var genreFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                genreChip(title: "All", id: nil)
                ForEach(genres) { g in genreChip(title: g.name, id: g.id) }
            }
            .padding(.horizontal, DS.gridPad)
        }
        .padding(.bottom, 12)
    }

    private func genreChip(title: String, id: String?) -> some View {
        let selected = selectedGenreId == id
        return Button {
            guard selectedGenreId != id else { return }
            selectedGenreId = id
            Task { await loadAlbums() }
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selected ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.primary))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .background(selected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color(.secondarySystemBackground)),
                            in: .capsule)
        }
        .buttonStyle(.plain)
    }

    private func initialLoad() async {
        if genres.isEmpty { genres = (try? await client.fetchMusicGenres()) ?? [] }
        if albums.isEmpty { await loadAlbums() }
    }

    private func loadAlbums() async {
        isLoading = true
        loadFailed = false
        do { albums = try await client.fetchAlbums(genreId: selectedGenreId) }
        catch { loadFailed = true }
        isLoading = false
    }
}
