import SwiftUI

struct AlbumsView: View {
    @EnvironmentObject var api: JellyfinAPI
    @State private var albums: [MediaItem] = []
    @State private var genres: [MediaItem] = []
    @State private var selectedGenreId: String?
    @State private var isLoading = false
    @State private var loadFailed = false

    private let cols = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: DS.gridSpacing)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text("Albums")
                        .font(.largeTitle).fontWeight(.bold)
                        .padding(.horizontal, DS.gridPad)
                        .padding(.top, 4)
                        .padding(.bottom, 6)

                    if !genres.isEmpty { genreFilter }

                    if albums.isEmpty && isLoading {
                        CenteredState(systemImage: nil, title: "Loading", loading: true)
                    } else if albums.isEmpty && loadFailed {
                        CenteredState(systemImage: "wifi.exclamationmark", title: "Couldn't load albums") {
                            Button("Try Again") { Task { await loadAlbums() } }
                                .buttonStyle(.bordered)
                        }
                    } else if albums.isEmpty {
                        CenteredState(systemImage: "square.stack",
                                      title: selectedGenreId == nil ? "No albums in your library" : "No albums in this genre")
                    } else {
                        LazyVGrid(columns: cols, spacing: DS.gridSpacing + 4) {
                            ForEach(albums) { album in
                                NavCard(route: .album(album)) { AlbumCard(album: album) }
                            }
                        }
                        .padding(.horizontal, DS.gridPad)
                        .padding(.top, 4)
                        .miniBarClearance()
                    }
                }
            }
            .scrollIndicators(.hidden)
            .topEdgeFade()
            .toolbar(.hidden, for: .navigationBar)
            .cardNavigation()
        }
        .task { await initialLoad() }
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
        if genres.isEmpty { genres = (try? await api.fetchMusicGenres()) ?? [] }
        if albums.isEmpty { await loadAlbums() }
    }

    private func loadAlbums() async {
        isLoading = true
        loadFailed = false
        do { albums = try await api.fetchAlbums(genreId: selectedGenreId) }
        catch { loadFailed = true }
        isLoading = false
    }
}

// MARK: - Shared centered state view

struct CenteredState<Accessory: View>: View {
    let systemImage: String?
    let title: String
    var loading: Bool = false
    @ViewBuilder var accessory: () -> Accessory

    init(systemImage: String?, title: String, loading: Bool = false,
         @ViewBuilder accessory: @escaping () -> Accessory = { EmptyView() }) {
        self.systemImage = systemImage
        self.title = title
        self.loading = loading
        self.accessory = accessory
    }

    var body: some View {
        VStack(spacing: 12) {
            Spacer().frame(height: 100)
            if loading {
                ProgressView()
            } else if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            accessory()
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, DS.hPad)
    }
}
