import SwiftUI
import CoreSpotlight

/// The whole native iOS 26 chrome: a system `TabView` with Home / Albums / Playlists tabs and a
/// `role: .search` tab (bottom, keyboard-adjusting search field), a persistent mini player in the
/// `tabViewBottomAccessory`, and the full Now Playing presented as a zoom-expanding cover.
struct RootTabView: View {
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    @Environment(\.colorScheme) private var colorScheme
    @State private var selection: RootTab = .home
    @State private var spotlightRoute: LibraryRoute?
    @State private var homePath = NavigationPath()
    @Namespace private var npZoom

    var body: some View {
        @Bindable var player = player

        TabView(selection: $selection) {
            Tab("Home", systemImage: "house.fill", value: RootTab.home) {
                HomeView(navPath: $homePath).miniBarClearance()
            }
            Tab("Albums", systemImage: "square.stack.fill", value: RootTab.albums) {
                AlbumsView().miniBarClearance()
            }
            Tab("Playlists", systemImage: "music.note.list", value: RootTab.playlists) {
                PlaylistsView().miniBarClearance()
            }
            Tab(value: RootTab.search, role: .search) {
                // No manual miniBarClearance here: the native search tab manages its own bottom
                // assembly (the mini bar sits above the search field, and both rise with the keyboard).
                // A manual safe-area inset fights that and mis-stacks them.
                SearchView()
            }
        }
        // Liquid-Glass mini bar in the native iOS 26 bottom accessory — the system floats it correctly
        // ABOVE the floating tab bar (a plain safeAreaInset overlaps it) and supplies the glass. Shown
        // ONLY while a track is loaded, so there's no empty bar when idle.
        .tabViewBottomAccessory {
            if SessionHub.shared.yieldedToRemote, SessionHub.shared.remote != nil {
                // Another device took over playback (exclusive-playback rule) — mirror IT, live.
                RemoteMiniBar()
            } else if let r = SessionHub.shared.remote, !r.isPaused, !player.isPlaying {
                // Another device is ACTIVELY playing and we're not — its live playback outranks the
                // locally-restored (paused) track, so playback is visibly shared without a transfer.
                RemoteMiniBar()
            } else if player.currentItem != nil {
                MiniPlayer(namespace: npZoom, appColorScheme: colorScheme)
            } else if SessionHub.shared.remote != nil {
                // Nothing loaded locally, but another device of this account is playing —
                // mirror it here; the controls drive that device.
                RemoteMiniBar()
            }
        }
        // "Transfer to this device" floats top-right whenever another device is the one playing.
        .overlay(alignment: .topTrailing) {
            TransferButton()
                .padding(.trailing, 16)
                .padding(.top, 4)
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
        // Now Playing asked to view an album/artist. Push it into the Home tab FIRST (behind the still-open
        // player), THEN close the player — so the detail is already there when it dismisses, with no
        // intermediate flash of the Home root.
        .onChange(of: player.pendingRoute) { _, route in
            guard let route else { return }
            selection = .home
            homePath.append(route)
            player.pendingRoute = nil
            player.showNowPlaying = false
        }
        .task { await SpotlightIndexer.reindex(client) }
        // Pre-load the keyboard once it's idle, so the first Search use doesn't lag / stall playback.
        .task { try? await Task.sleep(for: .milliseconds(500)); KeyboardWarmer.warmUp() }
        // No local session yet (fresh install) → show the server's last-played track in the mini bar.
        .task { await player.restoreFromServerIfNeeded() }
        // Prime the Liked Songs set so hearts + the playlist count render correctly from launch.
        .task { await client.refreshFavorites() }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            Task { spotlightRoute = await SpotlightIndexer.route(forIdentifier: id, client: client) }
        }
    }
}

enum RootTab: Hashable { case home, albums, playlists, search }

/// Reserves bottom room so scrollable tab content (and pushed detail views) clears the floating mini
/// player when a track is loaded — the bottom accessory isn't added to the scroll content inset
/// automatically, so the last rows would otherwise hide behind it.
private struct MiniBarClearance: ViewModifier {
    @Environment(Player.self) private var player
    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if player.currentItem != nil {
                Color.clear.frame(height: 80)   // mini-bar height + a breathing gap so the last row doesn't kiss it
            }
        }
    }
}

extension View {
    func miniBarClearance() -> some View { modifier(MiniBarClearance()) }
}
