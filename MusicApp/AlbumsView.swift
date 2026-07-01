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
                VStack(alignment: .leading, spacing: 0) {
                    Text("Albums")
                        .font(.largeTitle).fontWeight(.bold)
                        .padding(.horizontal, DS.hPad)
                        .padding(.top, 8)
                        .padding(.bottom, 14)

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
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            // Pull down to re-sync albums with Jellyfin (main page only).
            .refreshable { await load() }
            // Title lives in the scroll content (Home-style), so no header pins while scrolling.
            .toolbar(.hidden, for: .navigationBar)
            .task { if albums.isEmpty { await load() } }
        }
    }

    private func load() async {
        isLoading = true
        loadFailed = false
        do { albums = try await client.fetchAlbums() }
        catch { loadFailed = true }
        isLoading = false
        // Warm the grid's covers so they're ready as you scroll, not loaded lazily on appear.
        ImageStore.shared.prefetch(albums.map { client.artworkURL(for: $0, size: 400) }, maxPixel: 400)
    }
}
