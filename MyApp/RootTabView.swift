import SwiftUI

/// The whole native iOS 26 chrome: a system `TabView` with Home / Albums / Playlists tabs and a
/// `role: .search` tab (bottom, keyboard-adjusting search field), a persistent mini player in the
/// `tabViewBottomAccessory`, and the full Now Playing presented as a zoom-expanding cover.
struct RootTabView: View {
    @Environment(Player.self) private var player
    @State private var selection: RootTab = .home
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
            Tab(value: RootTab.search, role: .search) {
                SearchView()
            }
        }
        // Only reserve the accessory when something is playing — an always-on accessory leaves an
        // empty frosted pill above the tab bar when idle. It animates in/out with playback.
        .modifier(MiniPlayerAccessory(active: player.currentItem != nil, namespace: npZoom))
        // Now Playing zoom-expands from the mini player. `fullScreenCover` (not `.sheet`) is what
        // actually animates `.navigationTransition(.zoom)` on this build.
        .fullScreenCover(isPresented: $player.showNowPlaying) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "np", in: npZoom))
        }
    }
}

enum RootTab: Hashable { case home, albums, playlists, search }

/// Applies the mini-player accessory only while a track is loaded, so the bar is absent (not an
/// empty pill) when idle. The TabView keeps its identity, so tab selection / pushed details survive.
private struct MiniPlayerAccessory: ViewModifier {
    let active: Bool
    let namespace: Namespace.ID
    func body(content: Content) -> some View {
        if active {
            content.tabViewBottomAccessory { MiniPlayer(namespace: namespace) }
        } else {
            content
        }
    }
}
