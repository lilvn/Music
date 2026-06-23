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
    @State private var homePath = NavigationPath()
    @Namespace private var npZoom

    var body: some View {
        @Bindable var player = player

        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: RootTab.home) {
                HomeView(navPath: $homePath)
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
        // Liquid-Glass mini bar in the native iOS 26 bottom accessory — the system floats it correctly
        // ABOVE the floating tab bar (a plain safeAreaInset overlaps it) and supplies the glass. Shown
        // ONLY while a track is loaded, so there's no empty bar when idle.
        .tabViewBottomAccessory {
            if player.currentItem != nil {
                MiniPlayer(namespace: npZoom)
            }
        }
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
        // Now Playing asked to view an album/artist: it closed itself first; push it into the Home
        // tab (so the tab bar + mini player stay) once the player has finished dismissing.
        .onChange(of: player.showNowPlaying) { _, shown in
            guard !shown, let route = player.pendingRoute else { return }
            player.pendingRoute = nil
            selection = .home
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { homePath.append(route) }
        }
        .task { await SpotlightIndexer.reindex(client) }
        // No local session yet (fresh install) → show the server's last-played track in the mini bar.
        .task { await player.restoreFromServerIfNeeded() }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            Task { spotlightRoute = await SpotlightIndexer.route(forIdentifier: id, client: client) }
        }
    }
}

enum RootTab: Hashable { case home, albums, playlists, search }
