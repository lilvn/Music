import SwiftUI

struct AlbumsView: View {
    @EnvironmentObject var api: JellyfinAPI
    @State private var albums: [MediaItem] = []
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

                    if albums.isEmpty && isLoading {
                        CenteredState(systemImage: nil, title: "Loading", loading: true)
                    } else if albums.isEmpty && loadFailed {
                        CenteredState(systemImage: "wifi.exclamationmark", title: "Couldn't load albums") {
                            Button("Try Again") { Task { await load(force: true) } }
                                .buttonStyle(.bordered)
                        }
                    } else if albums.isEmpty {
                        CenteredState(systemImage: "square.stack", title: "No albums in your library")
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
        .task { await load() }
    }

    private func load(force: Bool = false) async {
        guard albums.isEmpty || force else { return }
        isLoading = true
        loadFailed = false
        do { albums = try await api.fetchAlbums() }
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
