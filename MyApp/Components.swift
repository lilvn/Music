import SwiftUI

// MARK: - Design constants

enum DS {
    static let hPad: CGFloat = 20          // horizontal padding for lists
    static let gridPad: CGFloat = 16       // horizontal padding for grids
    static let gridSpacing: CGFloat = 12   // spacing between grid cells
    static let cornerCard: CGFloat = 16    // album / artist cards
    static let cornerArtwork: CGFloat = 18 // large artwork (album detail, now playing)
    static let cornerThumb: CGFloat = 10   // row thumbnails
    static let cornerMini: CGFloat = 11    // mini player artwork
    static let shadowRadius: CGFloat = 8
    static let shadowY: CGFloat = 4
    static let shadowOpacity: CGFloat = 0.12
}

// MARK: - Native push navigation + zoom card-expand

/// Shares a stack's zoom `Namespace` with the cards inside it, so a `LibraryLink` deep in the tree
/// can mark its source for the zoom transition the stack's `navigationDestination` applies.
private struct ZoomNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}
extension EnvironmentValues {
    var zoomNamespace: Namespace.ID? {
        get { self[ZoomNamespaceKey.self] }
        set { self[ZoomNamespaceKey.self] = newValue }
    }
}

/// A tab's root `NavigationStack`. Detail routes PUSH (so the tab bar + mini player stay above them)
/// and zoom-expand out of the tapped card. One namespace per stack, threaded to cards via the
/// environment; nested pushes (an album opened from an artist) reuse the same destination + zoom.
struct LibraryStack<Root: View>: View {
    @ViewBuilder var root: () -> Root
    @Namespace private var ns

    var body: some View {
        NavigationStack {
            root()
                .navigationDestination(for: LibraryRoute.self) { route in
                    destinationView(for: route)
                        .navigationTransition(.zoom(sourceID: route.id, in: ns))
                }
        }
        .environment(\.zoomNamespace, ns)
    }
}

/// A tappable card that pushes `route` with the zoom card-expand (when a `LibraryStack` namespace is
/// in scope; falls back to a plain push otherwise).
struct LibraryLink<Label: View>: View {
    let route: LibraryRoute
    @ViewBuilder var label: () -> Label
    @Environment(\.zoomNamespace) private var ns

    var body: some View {
        NavigationLink(value: route) { label() }
            .buttonStyle(ScaleButtonStyle())
            .modifier(MatchedSourceIfAvailable(id: route.id, ns: ns))
            .modifier(RouteMenu(route: route))
    }
}

private struct MatchedSourceIfAvailable: ViewModifier {
    let id: String
    let ns: Namespace.ID?
    func body(content: Content) -> some View {
        if let ns { content.matchedTransitionSource(id: id, in: ns) }
        else { content }
    }
}

/// Attaches the album/playlist long-press (3D-touch) menu to a link based on its route — applied to
/// the link itself (not the label), which is where a context menu actually triggers reliably. Artists
/// have no container menu.
private struct RouteMenu: ViewModifier {
    let route: LibraryRoute
    func body(content: Content) -> some View {
        switch route {
        case .album(let m), .playlist(let m): content.libraryItemMenu(m)
        case .albumSong(let m, _): content.libraryItemMenu(m)
        case .artist: content
        }
    }
}

@ViewBuilder
func destinationView(for route: LibraryRoute) -> some View {
    switch route {
    case .album(let album):       AlbumDetailView(album: album)
    case .artist(let artist):     ArtistDetailView(artist: artist)
    case .playlist(let playlist): PlaylistDetailView(playlist: playlist)
    case .albumSong(let album, let songId): AlbumDetailView(album: album, highlightSongId: songId)
    }
}

// MARK: - Scale-press button style

struct ScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

// MARK: - Album card (fills whatever width the grid gives it)

struct AlbumCard: View {
    let album: MediaItem
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryImage(url: client.artworkURL(for: album, size: 400), maxPixel: 400) {
                Color(.systemGray6)
                    .overlay {
                        Image(systemName: "music.note")
                            .font(.title2)
                            .foregroundStyle(Color(.systemGray4))
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
            .shadow(color: .black.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.footnote).fontWeight(.semibold).lineLimit(1)
                Text(album.albumArtist ?? album.primaryArtist)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

// MARK: - Artist row

struct ArtistRow: View {
    let artist: MediaItem
    var large: Bool = false
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        HStack(spacing: 14) {
            LibraryImage(url: client.artworkURL(for: artist, size: 120), maxPixel: 200) {
                Color(.systemGray5)
                    .overlay {
                        Image(systemName: "person.fill")
                            .font(.title3)
                            .foregroundStyle(Color(.systemGray3))
                    }
            }
            .frame(width: large ? 66 : 56, height: large ? 66 : 56)
            .clipShape(Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(artist.name)
                    .font(large ? .title3 : .callout)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                if let count = artist.childCount {
                    Text("\(count) album\(count == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            Image(systemName: "chevron.right")
                .font(.footnote).fontWeight(.semibold)
                .foregroundStyle(Color(.systemGray3))
        }
        .padding(.horizontal, DS.hPad)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Song row

struct SongRow: View {
    let song: MediaItem
    var showAlbumArt: Bool = false
    /// Explicit number for the leading column (album detail), so singles with no `IndexNumber`
    /// still show a number. Falls back to the item's own index.
    var trackNumber: Int? = nil
    let onTap: () -> Void
    var onPlayNext: (() -> Void)? = nil
    var onPlayLast: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    var large: Bool = false
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    private var isCurrent: Bool { player.currentItem?.id == song.id }

    var body: some View {
        HStack(spacing: 12) {
            leading
            info
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, DS.hPad)
        .frame(minHeight: large ? 68 : 56)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .contextMenu {
            if let onPlayNext {
                Button { onPlayNext() } label: { Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward") }
            }
            if let onPlayLast {
                Button { onPlayLast() } label: { Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward") }
            }
            if let onAddToPlaylist {
                Button { onAddToPlaylist() } label: { Label("Add to Playlist", systemImage: "text.badge.plus") }
            }
            if let onRemove {
                Button(role: .destructive) { onRemove() } label: { Label("Remove from Playlist", systemImage: "minus.circle") }
            }
        }
    }

    @ViewBuilder
    private var leading: some View {
        if showAlbumArt {
            LibraryImage(url: client.artworkURL(for: song, size: 100), maxPixel: 160) {
                Color(.systemGray6)
            }
            .frame(width: large ? 56 : 46, height: large ? 56 : 46)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerThumb, style: .continuous))
        } else {
            Group {
                if isCurrent {
                    Image(systemName: player.isPlaying ? "waveform" : "pause.fill")
                        .font(.caption)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers,
                                      isActive: isCurrent && player.isPlaying)
                } else if let num = trackNumber ?? song.indexNumber {
                    Text("\(num)")
                        .font(.footnote).monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
            }
            .frame(width: 28, alignment: .trailing)
        }
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(song.name)
                .font(large ? .body : .callout)
                .fontWeight(isCurrent ? .semibold : .regular)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(song.primaryArtist)
                .font(large ? .subheadline : .footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private var trailing: some View {
        if isCurrent && showAlbumArt {
            Image(systemName: "waveform")
                .font(.caption)
                .foregroundStyle(.primary)
                .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: player.isPlaying)
        }
        if let dur = song.durationSeconds {
            Text(dur.formattedDuration)
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .monospacedDigit()
        }
    }
}

// MARK: - Track swipe actions (native, monochrome — full-swipe plays next)

extension View {
    /// Trailing swipe → Play Next (full-swipe) / Play Last; optional leading swipe → Remove.
    @ViewBuilder
    func trackSwipeActions(onPlayNext: (() -> Void)?,
                           onPlayLast: (() -> Void)?,
                           onRemove: (() -> Void)? = nil) -> some View {
        self
            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                if let onPlayNext {
                    Button { onPlayNext() } label: {
                        Image(systemName: "text.line.first.and.arrowtriangle.forward")
                    }
                    .tint(Color(.systemGray2))
                }
                if let onPlayLast {
                    Button { onPlayLast() } label: {
                        Image(systemName: "text.line.last.and.arrowtriangle.forward")
                    }
                    .tint(Color(.systemGray3))
                }
            }
            .swipeActions(edge: .leading, allowsFullSwipe: true) {
                if let onRemove {
                    Button(role: .destructive) { onRemove() } label: {
                        Image(systemName: "minus.circle")
                    }
                }
            }
    }
}

// MARK: - Queue action button (round secondary action beside the Play pill)

struct QueueActionButton: View {
    let icon: String
    var disabled: Bool = false
    let action: () -> Void
    @State private var bump = false

    var body: some View {
        Button {
            action()
            bump.toggle()
        } label: {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .glassEffect(.regular.interactive(), in: Circle())
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .sensoryFeedback(.impact(weight: .light), trigger: bump)
    }
}

// MARK: - Centered state (loading / empty / error)

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

// MARK: - Artist detail (hero header + album grid)

struct ArtistDetailView: View {
    let artist: MediaItem
    @Environment(JellyfinClient.self) private var client
    @State private var albums: [MediaItem] = []
    @State private var isLoading = true

    private let heroHeight: CGFloat = 280
    private let cols = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: DS.gridSpacing)]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroHeader

                if isLoading {
                    ProgressView().padding(48)
                } else if albums.isEmpty {
                    Text("No albums found")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(48)
                } else {
                    LazyVGrid(columns: cols, spacing: DS.gridSpacing + 4) {
                        ForEach(albums) { album in
                            LibraryLink(route: .album(album)) { AlbumCard(album: album) }
                        }
                    }
                    .padding(.horizontal, DS.gridPad)
                    .padding(.top, 16)
                }
            }
        }
        .scrollIndicators(.hidden)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            albums = (try? await client.fetchAlbums(artistId: artist.id)) ?? []
            isLoading = false
        }
    }

    private var heroHeader: some View {
        ZStack(alignment: .bottomLeading) {
            LibraryImage(url: client.artworkURL(for: artist, size: 600), maxPixel: 700) {
                Color(.systemGray5)
            }
            .frame(maxWidth: .infinity)
            .frame(height: heroHeight)
            .clipped()

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.3),
                    .init(color: Color(.systemBackground).opacity(0.7), location: 0.75),
                    .init(color: Color(.systemBackground), location: 1),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .frame(height: heroHeight)

            VStack(alignment: .leading, spacing: 4) {
                Text(artist.name)
                    .font(.system(size: 32, weight: .bold))
                if !albums.isEmpty {
                    Text("\(albums.count) album\(albums.count == 1 ? "" : "s")")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, DS.hPad)
            .padding(.bottom, 20)
        }
    }
}
