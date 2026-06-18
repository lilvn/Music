import SwiftUI

@main struct JellytunesApp: App {
    @StateObject private var api = JellyfinAPI()
    @StateObject private var player = AudioPlayerManager()

    init() {
        // Cache artwork aggressively so covers aren't re-downloaded while scrolling the
        // carousel/grids or re-rendering during playback.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,    // 64 MB
                                   diskCapacity: 512 * 1024 * 1024)     // 512 MB
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(api)
                .environmentObject(player)
                .tint(.primary)
        }
    }
}

enum AppTab: Hashable { case home, albums, playlists, search }

struct MainTabView: View {
    @EnvironmentObject var player: AudioPlayerManager
    @State private var tab: AppTab = .home
    @Namespace private var npZoom

    var body: some View {
        TabView(selection: $tab) {
            Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                HomeView()
            }
            Tab("Albums", systemImage: "square.stack.fill", value: AppTab.albums) {
                AlbumsView()
            }
            Tab("Playlists", systemImage: "music.note.list", value: AppTab.playlists) {
                PlaylistsView()
            }
            // iOS 26 `.search` role: a round glass search button on the trailing side of the
            // tab bar that expands into a search field (with keyboard) when tapped.
            Tab(value: AppTab.search, role: .search) {
                SearchTabView()
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .tabViewBottomAccessory {
            if player.currentItem != nil {
                MiniPlayerBar()
                    .matchedTransitionSource(id: "np", in: npZoom)
            }
        }
        .fullScreenCover(isPresented: $player.showNowPlaying) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "np", in: npZoom))
        }
    }
}
