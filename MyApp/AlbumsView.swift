import SwiftUI

struct AlbumsView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var albums: [MediaItem] = []
    @State private var isLoading = false
    @State private var loadFailed = false

    private let cols = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: DS.gridSpacing)]

    var body: some View {
        LibraryStack {
            ScrollView {
                if albums.isEmpty && isLoading {
                    CenteredState(systemImage: nil, title: "Loading", loading: true)
                } else if albums.isEmpty && loadFailed {
                    CenteredState(systemImage: "wifi.exclamationmark", title: "Couldn't load albums") {
                        Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
                    }
                } else if albums.isEmpty {
                    CenteredState(systemImage: "square.stack", title: "No albums in your library")
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
            .scrollIndicators(.hidden)
            .navigationTitle("Albums")
            .task { if albums.isEmpty { await load() } }
        }
    }

    private func load() async {
        isLoading = true
        loadFailed = false
        do { albums = try await client.fetchAlbums() }
        catch { loadFailed = true }
        isLoading = false
    }
}
