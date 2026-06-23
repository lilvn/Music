import SwiftUI

// MARK: - Design constants

enum DS {
    static let hPad: CGFloat = 20          // horizontal padding for lists
    static let gridPad: CGFloat = 16       // horizontal padding for grids
    static let gridSpacing: CGFloat = 12   // spacing between grid cells
    static let cornerCard: CGFloat = 16    // album / artist cards
    static let cornerArtwork: CGFloat = 26 // large artwork (album detail, now playing)
    static let cornerThumb: CGFloat = 10   // row thumbnails
    static let cornerMini: CGFloat = 11    // mini player artwork
    static let shadowRadius: CGFloat = 8
    static let shadowY: CGFloat = 4
    static let shadowOpacity: CGFloat = 0.12
}

// MARK: - Dynamic artwork gradient (Apple-Music-style art-derived wash)

/// The album art rendered as a soft, saturated colour wash — the shared "dynamic gradient" used as the
/// CD body, the detail / now-playing backgrounds, the mini-bar progress fill and the playing bars.
/// Fills whatever frame it's given and, when `animated`, slowly drifts so the colours feel alive
/// (Apple-Music / Dynamic-Island style). The blur is applied before the transforms so it's rasterised
/// once and the motion is a cheap layer transform rather than a per-frame re-blur.
struct ArtworkGradient: View {
    let url: URL?
    var blur: CGFloat = 40
    var animated: Bool = true

    private var image: some View {
        LibraryImage(url: url, maxPixel: 240) { Color(white: 0.16) }
            .aspectRatio(contentMode: .fill)
            .blur(radius: blur, opaque: true)
            .saturation(1.4)
    }

    var body: some View {
        if animated {
            // Lava-lamp flow: a slow CONTINUOUS rotation plus a lazy elliptical drift and gentle
            // breathing, so the colours keep flowing in one direction rather than pulsing back and
            // forth. Offsets are proportional to the view, so it works at any size (full-screen
            // background → 36pt CD). 30fps keeps it cheap; the caller clips/masks the overflow.
            GeometryReader { geo in
                let maxSide = max(geo.size.width, geo.size.height)
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    image
                        .frame(width: geo.size.width, height: geo.size.height)
                        .scaleEffect(1.42 + 0.1 * sin(t * 0.31))
                        .rotationEffect(.degrees(t * 3.5))
                        .offset(x: maxSide * 0.09 * sin(t * 0.23),
                                y: maxSide * 0.09 * cos(t * 0.19))
                }
            }
        } else {
            image.scaleEffect(1.06)
        }
    }
}

/// Animated "now playing" bars filled with the album's dynamic gradient — the Apple-Music / Dynamic-
/// Island style playing indicator that replaces the SF `waveform` glyph in lists.
struct PlayingIndicator: View {
    let url: URL?
    let active: Bool
    private let count = 4

    var body: some View {
        TimelineView(.animation(paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ArtworkGradient(url: url, blur: 4, animated: false)
                .saturation(1.3)
                .mask {
                    HStack(spacing: 2.5) {
                        ForEach(0..<count, id: \.self) { i in
                            Capsule().frame(width: 2.5, height: barHeight(i, t))
                        }
                    }
                    .frame(height: 16)
                }
        }
        .frame(width: 20, height: 16)
    }

    private func barHeight(_ i: Int, _ t: Double) -> CGFloat {
        guard active else { return 4 }
        let beat = sin(t * 5.5 + Double(i) * 1.1) + 0.5 * sin(t * 8.7 + Double(i) * 0.7)
        let v = max(0, min(1, (beat / 1.5 + 1) / 2))   // 0…1, layered for a beat-like pulse
        return 4 + CGFloat(v) * 12                      // 4…16
    }
}

/// Full-bleed dynamic background derived from the artwork, toned toward the system background so the
/// foreground (adaptive `.primary` / `.secondary` text) stays legible in both light and dark mode.
struct ArtworkBackground: View {
    let url: URL?
    var body: some View {
        ArtworkGradient(url: url, blur: 55)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .overlay(Color(.systemBackground).opacity(0.5))
            .overlay(
                LinearGradient(colors: [Color(.systemBackground).opacity(0.25),
                                        Color(.systemBackground).opacity(0.0),
                                        Color(.systemBackground).opacity(0.55)],
                               startPoint: .top, endPoint: .bottom))
            .ignoresSafeArea()
    }
}

/// Cross-fades the artwork background between tracks. The ZStack + `.animation(value:)` is what makes
/// the `.id` + `.transition` actually fire when used inside a `.background` / `.presentationBackground`.
struct CrossfadeBackground: View {
    let url: URL?
    var body: some View {
        ZStack {
            ArtworkBackground(url: url)
                .id(url)
                .transition(.opacity)
        }
        .animation(.easeInOut(duration: 0.55), value: url)
    }
}

/// Shown wherever an item has no artwork — a subtle dark panel with the custom heart-speaker mark.
/// Falls back to an SF Symbol until the `ArtworkPlaceholder` image asset is added. Fills its frame,
/// so it reads correctly at every size (row thumbnail → full now-playing art → cover-flow reflection).
struct ArtworkPlaceholder: View {
    var body: some View {
        GeometryReader { geo in
            let s = min(geo.size.width, geo.size.height)
            ZStack {
                LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let mark = UIImage(named: "ArtworkPlaceholder") {
                    Image(uiImage: mark)
                        .resizable()
                        .scaledToFit()
                        .frame(width: max(s * 0.12, 14), height: max(s * 0.12, 14))
                        .opacity(0.9)
                } else {
                    Image(systemName: "music.note")
                        .font(.system(size: s * 0.26, weight: .regular))
                        .foregroundStyle(.white.opacity(0.32))
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }
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

/// Lets a view deep in a `LibraryStack` push a route programmatically (e.g. from a context menu
/// "View Album / View Artist"), reusing the same destination + zoom as a tapped card.
private struct LibraryPushKey: EnvironmentKey {
    static let defaultValue: (LibraryRoute) -> Void = { _ in }
}
extension EnvironmentValues {
    var libraryPush: (LibraryRoute) -> Void {
        get { self[LibraryPushKey.self] }
        set { self[LibraryPushKey.self] = newValue }
    }
}

/// A tab's root `NavigationStack`. Detail routes PUSH (so the tab bar + mini player stay above them)
/// and zoom-expand out of the tapped card. One namespace per stack, threaded to cards via the
/// environment; nested pushes (an album opened from an artist) reuse the same destination + zoom.
struct LibraryStack<Root: View>: View {
    /// Optional externally-owned path, so a parent (e.g. RootTabView) can push into this stack — used
    /// to navigate from Now Playing while keeping the tab bar + mini player.
    var externalPath: Binding<NavigationPath>? = nil
    @ViewBuilder var root: () -> Root
    @Namespace private var ns
    @State private var internalPath = NavigationPath()

    private var pathBinding: Binding<NavigationPath> { externalPath ?? $internalPath }

    var body: some View {
        NavigationStack(path: pathBinding) {
            root()
                .navigationDestination(for: LibraryRoute.self) { route in
                    destinationView(for: route)
                        .navigationTransition(.zoom(sourceID: route.id, in: ns))
                }
        }
        .environment(\.zoomNamespace, ns)
        .environment(\.libraryPush) { pathBinding.wrappedValue.append($0) }
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
                ArtworkPlaceholder()
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
    /// When supplied, the current-track glass highlight glides between rows (matchedGeometry).
    var highlightNamespace: Namespace.ID? = nil
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
        // Liquid-glass "magnifier" highlight on the currently-playing row (consistent across all lists).
        .background {
            if isCurrent {
                if let ns = highlightNamespace {
                    Color.clear
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                        .padding(.horizontal, 8)
                        .matchedGeometryEffect(id: "songHighlight", in: ns)
                } else {
                    Color.clear
                        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 16))
                        .padding(.horizontal, 8)
                        .transition(.opacity.combined(with: .scale(scale: 0.96)))
                }
            }
        }
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
                    if player.isPlaying {
                        PlayingIndicator(url: client.artworkURL(for: song, size: 160), active: true)
                    } else {
                        Image(systemName: "pause.fill").font(.caption).foregroundStyle(.primary)
                    }
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
            PlayingIndicator(url: client.artworkURL(for: song, size: 160), active: player.isPlaying)
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
    @Environment(Player.self) private var player
    @State private var albums: [MediaItem] = []
    @State private var isLoading = true

    private let heroHeight: CGFloat = 280
    private let cols = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: DS.gridSpacing)]

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                heroHeader

                if !albums.isEmpty {
                    playRow
                        .padding(.horizontal, DS.hPad)
                        .padding(.top, 14)
                }

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

    /// Play / Shuffle all of the artist's songs (fetched on tap, in album order).
    private var playRow: some View {
        HStack(spacing: 12) {
            artistAction(title: "Play", icon: "play.fill") { playAll(shuffled: false) }
            artistAction(title: "Shuffle", icon: "shuffle") { playAll(shuffled: true) }
        }
    }

    private func artistAction(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity)
                .frame(height: 46)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(ScaleButtonStyle())
    }

    private func playAll(shuffled: Bool) {
        Task {
            let songs = (try? await client.fetchArtistSongs(artistId: artist.id)) ?? []
            if !songs.isEmpty { player.play(items: songs, from: 0, shuffled: shuffled) }
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
