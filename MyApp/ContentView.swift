import SwiftUI
import CoreSpotlight

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

enum AppTab: Hashable, CaseIterable {
    case home, albums, playlists

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .albums: "square.stack.fill"
        case .playlists: "music.note.list"
        }
    }
    var label: String {
        switch self {
        case .home: "Home"
        case .albums: "Albums"
        case .playlists: "Playlists"
        }
    }
}

/// Custom bottom chrome (built from scratch): a liquid-glass tab pill + a detached liquid-glass
/// search circle. Tapping the circle morphs the pill into a single circle and expands the search
/// bar in its place, bringing up the keyboard. The mini player rides above all of it.
struct MainTabView: View {
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var api: JellyfinAPI
    @State private var tab: AppTab = .home
    @State private var searching = false
    @State private var searchText = ""
    @State private var spotlightRoute: LibraryRoute?
    @FocusState private var searchFocused: Bool
    @Namespace private var npZoom
    @Namespace private var tabSel

    var body: some View {
        ZStack {
            // Real TabView (native bar hidden) so only the visible tab renders — keeps it fast
            // and preserves each tab's state. The custom glass bar lives in the safeAreaInset.
            TabView(selection: $tab) {
                Tab("Home", systemImage: "house.fill", value: AppTab.home) {
                    HomeView().toolbar(.hidden, for: .tabBar)
                }
                Tab("Albums", systemImage: "square.stack.fill", value: AppTab.albums) {
                    AlbumsView().toolbar(.hidden, for: .tabBar)
                }
                Tab("Playlists", systemImage: "music.note.list", value: AppTab.playlists) {
                    PlaylistsView().toolbar(.hidden, for: .tabBar)
                }
            }

            if searching {
                SearchResultsView(query: searchText)
                    .background(Color(.systemBackground).ignoresSafeArea())
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomChrome }
        .fullScreenCover(isPresented: $player.showNowPlaying) {
            NowPlayingView()
                .navigationTransition(.zoom(sourceID: "np", in: npZoom))
        }
        // Open the detail when the user taps a Spotlight result for this library.
        .fullScreenCover(item: $spotlightRoute) { route in
            NavigationStack {
                destinationView(for: route)
                    .cardNavigation()
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
        .task { await SpotlightIndexer.reindex(api) }
        .onContinueUserActivity(CSSearchableItemActionType) { activity in
            guard let id = activity.userInfo?[CSSearchableItemActivityIdentifier] as? String else { return }
            Task { spotlightRoute = await SpotlightIndexer.route(forIdentifier: id, api: api) }
        }
    }

    // MARK: Bottom chrome (flat, system-adaptive — no Liquid Glass)

    /// Floating-bar surface: a solid adaptive fill with a soft shadow so it reads above content.
    private func barSurface<S: Shape>(_ shape: S) -> some View {
        shape.fill(Color(.secondarySystemBackground))
            .shadow(color: .black.opacity(0.14), radius: 9, y: 2)
    }

    private var bottomChrome: some View {
        VStack(spacing: 8) {
            if player.currentItem != nil {
                MiniPlayerBar()
                    .matchedTransitionSource(id: "np", in: npZoom)
                    .padding(.horizontal, 16)
            }
            HStack(spacing: 12) {
                leftBar
                rightBar
            }
            .padding(.horizontal, 16)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 4)
        // Passively block taps in the bar region from falling through to content behind it.
        .background { if !searching { Color.clear.contentShape(Rectangle()) } }
        // Pop the keyboard up the moment search opens; drop it when search closes.
        .onChange(of: searching) { _, isSearching in searchFocused = isSearching }
        .animation(.spring(response: 0.36, dampingFraction: 0.86), value: searching)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: player.currentItem != nil)
    }

    /// Left: the tab bar, which collapses to a single circle (current tab) while searching.
    @ViewBuilder private var leftBar: some View {
        if searching {
            Button {
                searchFocused = false
                searchText = ""
                searching = false
            } label: {
                Image(systemName: tab.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 56, height: 56)
                    .background { barSurface(Circle()) }
            }
            .buttonStyle(.plain)
        } else {
            HStack(spacing: 2) {
                ForEach(AppTab.allCases, id: \.self) { t in
                    Button { tab = t } label: {
                        VStack(spacing: 3) {
                            Image(systemName: t.icon).font(.system(size: 18))
                            Text(t.label).font(.caption2).fontWeight(.medium)
                        }
                        .foregroundStyle(tab == t ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            // Solid sliding selection pill (flat — no glass).
                            if tab == t {
                                Capsule(style: .continuous)
                                    .fill(Color(.systemBackground))
                                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                                    .matchedGeometryEffect(id: "tabSelector", in: tabSel)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background { barSurface(Capsule(style: .continuous)) }
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: tab)
        }
    }

    /// Right: the search button, which expands into the full search field while searching.
    @ViewBuilder private var rightBar: some View {
        if searching {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $searchText)
                    .focused($searchFocused)
                    .autocorrectionDisabled()
                    .submitLabel(.done)              // return key dismisses the keyboard
                    .onSubmit { searchFocused = false }
#if os(iOS)
                    .textInputAutocapitalization(.never)
#endif
                if !searchText.isEmpty {
                    Button { searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.body)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .frame(height: 56)
            .background { barSurface(Capsule(style: .continuous)) }
        } else {
            Button { searching = true } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 56, height: 56)
                    .background { barSurface(Circle()) }
            }
            .buttonStyle(.plain)
        }
    }
}

