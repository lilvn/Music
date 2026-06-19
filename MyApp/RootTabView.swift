import SwiftUI
import CoreSpotlight

/// The whole native iOS 26 chrome: a system `TabView` with Home / Albums / Playlists tabs and a
/// `role: .search` tab (bottom, keyboard-adjusting search field), a persistent mini player in the
/// `tabViewBottomAccessory`, and the full Now Playing presented as a zoom-expanding cover.
struct RootTabView: View {
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    @State private var selection: RootTab = .home
    @State private var spotlightRoute: LibraryRoute?
    @Namespace private var npZoom

    var body: some View {
        @Bindable var player = player

        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: RootTab.home) {
                HomeView()
            }
            Tab("Albums", systemImage: "square.stack.fill", value: RootTab.albums) {
                AlbumsView()
            }
            Tab("Playlists", systemImage: "music.note.list", value: RootTab.playlists) {
                PlaylistsView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: RootTab.search) {
                SearchView()
            }
        }
        // Apply the accessory ALWAYS (stable identity). Toggling it on/off would change the
        // TabView's type and re-create every tab — reloading Home and resetting scroll the moment
        // playback starts ("refreshes the page"). MiniPlayer renders nothing when idle.
        .tabViewBottomAccessory { MiniPlayer(namespace: npZoom) }
        // Now Playing zoom-expands from the mini player. `fullScreenCover` (not `.sheet`) is what
        // actually animates `.navigationTransition(.zoom)` on this build.
        .fullScreenCover(isPresented: $player.showNowPlaying) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "np", in: npZoom))
        }
        // Open the detail when the user taps a Spotlight result for this library.
        .fullScreenCover(item: $spotlightRoute) { route in
            NavigationStack {
                destinationView(for: route)
                    .navigationDestination(for: LibraryRoute.self) { destinationView(for: $0) }
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { spotlightRoute = nil } label: {
                                Image(systemName: "chevron.down").fontWeight(.semibold)
                            }
                            .tint(.primary)
                        }
                    }
            }
        }
        .task { await SpotlightIndexer.reindex(client) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            Task { spotlightRoute = await SpotlightIndexer.route(forIdentifier: id, client: client) }
        }
    }
}

enum RootTab: Hashable { case home, albums, playlists, search }
