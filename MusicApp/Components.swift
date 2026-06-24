import SwiftUI
import UIKit

// MARK: - Design constants

enum DS {
    static let hPad: CGFloat = 20          // horizontal padding for lists
    static let gridPad: CGFloat = 16       // horizontal padding for grids
    static let gridSpacing: CGFloat = 12   // spacing between grid cells
    // Subtle artwork rounding, in line with Apple Music / Spotify / YouTube Music (nearly square).
    static let cornerCard: CGFloat = 8     // album / artist cards
    static let cornerArtwork: CGFloat = 12 // large artwork (album detail, now playing)
    static let cornerThumb: CGFloat = 6    // row thumbnails
    static let cornerMini: CGFloat = 8     // mini player artwork
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
    @State private var spin = false
    @State private var breathe = false

    private var image: some View {
        LibraryImage(url: url, maxPixel: 160) { Color(white: 0.16) }
            .aspectRatio(contentMode: .fill)
            .blur(radius: blur, opaque: true)
            .saturation(1.4)
    }

    var body: some View {
        // Lava-lamp flow driven by GPU-interpolated `repeatForever` animations (NOT a per-frame
        // TimelineView): the blurred image is rasterised once and only the cheap scale/rotate/offset
        // transforms animate — a slow continuous spin for one-directional flow plus a lazy breathe.
        GeometryReader { geo in
            image
                .frame(width: geo.size.width, height: geo.size.height)
                .scaleEffect(animated ? (breathe ? 1.5 : 1.34) : 1.06)
                .offset(x: animated ? geo.size.width * (breathe ? 0.05 : -0.05) : 0,
                        y: animated ? geo.size.height * (breathe ? -0.04 : 0.04) : 0)
                .rotationEffect(.degrees(animated && spin ? 360 : 0))
                .onAppear {
                    guard animated else { return }
                    withAnimation(.linear(duration: 95).repeatForever(autoreverses: false)) { spin = true }
                    withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) { breathe = true }
                }
        }
    }
}

/// Animated "now playing" bars filled with the album's dynamic gradient — the Apple-Music / Dynamic-
/// Island style playing indicator that replaces the SF `waveform` glyph in lists.
struct PlayingIndicator: View {
    let url: URL?
    let active: Bool
    @Environment(Player.self) private var player

    // Each bar runs a continuous wave (so it's always lively, like the Dynamic Island) whose PEAK
    // height scales with the live audio level — quiet → small waves, a beat → bars jump. Flat when
    // paused. Only ~1–2 of these are ever on-screen, so the per-frame TimelineView is cheap here.
    private let speeds: [Double] = [6.1, 8.3, 5.2, 7.4, 6.7]
    private let phases: [Double] = [0.0, 1.7, 3.1, 0.8, 2.4]
    private let minH: CGFloat = 3
    private let maxH: CGFloat = 16

    var body: some View {
        // The blurred-gradient FILL is rendered once (outside the TimelineView); only the small bar
        // mask animates per frame, so the gradient/blur isn't re-evaluated every tick.
        ArtworkGradient(url: url, blur: 4, animated: false)
            .saturation(1.6)
            .brightness(0.24)   // lift it off the same-art background so the bars stand out
            .mask {
                // Cap at ~30 fps (the audio level updates at 30 Hz anyway) so the bars don't redraw at
                // a 120 Hz ProMotion rate — that was a needless GPU/thermal cost in long lists.
                TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !active)) { context in
                    let t = context.date.timeIntervalSinceReferenceDate
                    let level = active ? min(1, max(0, player.audioLevel)) : 0
                    HStack(spacing: 2) {
                        ForEach(speeds.indices, id: \.self) { i in
                            Capsule().frame(width: 2.5, height: barHeight(i, t, CGFloat(level)))
                        }
                    }
                    .frame(width: 22, height: 16)
                    // Ease the bars down to flat (and back up) on pause/play instead of snapping.
                    .animation(.easeOut(duration: 0.3), value: active)
                }
            }
            .frame(width: 22, height: 16)
    }

    private func barHeight(_ i: Int, _ t: Double, _ level: CGFloat) -> CGFloat {
        guard active else { return minH }
        let osc = (sin(t * speeds[i] + phases[i]) + 1) / 2   // 0…1 wave
        let peak = 0.32 + 0.68 * level                       // amplitude grows with the audio
        return minH + (maxH - minH) * CGFloat(osc) * peak
    }
}

/// Full-bleed dynamic background derived from the artwork, toned toward the system background so the
/// foreground (adaptive `.primary` / `.secondary` text) stays legible in both light and dark mode.
struct ArtworkBackground: View {
    let url: URL?
    var animated: Bool = true
    var body: some View {
        ArtworkGradient(url: url, blur: 38, animated: animated)
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
    /// Pass `false` where a moving gradient behind Liquid Glass would force a costly per-frame re-blur
    /// (e.g. the Up Next sheet) — the cross-fade between tracks still animates.
    var animated: Bool = true
    var body: some View {
        ZStack {
            ArtworkBackground(url: url, animated: animated)
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

extension View {
    /// The unified album-artwork drop shadow (matches the featured cover-flow artwork). Applied to all
    /// cover art — cards, detail covers, the now-playing hero — so artwork sits on the page the same way.
    func artworkShadow() -> some View {
        shadow(color: .black.opacity(0.25), radius: 11, y: 7)
    }

    /// A liquid-glass back button (plus optional trailing header content, e.g. a "+") rendered in a real
    /// view bar — NOT the system toolbar — so its opacity actually animates: it fades out on close exactly
    /// the way it fades in. The bar reserves its own space at the top (a custom nav bar) and keeps the
    /// edge swipe-to-go-back.
    func fadingDetailHeader() -> some View {
        modifier(FadingDetailHeader(trailing: EmptyView()))
    }
    func fadingDetailHeader<T: View>(@ViewBuilder trailing: () -> T) -> some View {
        modifier(FadingDetailHeader(trailing: trailing()))
    }
}

/// A glass circular button matching the system toolbar look — used for the back button and the header
/// "+" so they're identical everywhere.
struct GlassCircleButton<Label: View>: View {
    var action: () -> Void
    @ViewBuilder var label: () -> Label
    var body: some View {
        Button(action: action) {
            label()
                .frame(width: 36, height: 36)
                .glassEffect(.regular.interactive(), in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(ScaleButtonStyle())
    }
}

private struct FadingDetailHeader<Trailing: View>: ViewModifier {
    @Environment(\.dismiss) private var dismiss
    @State private var visible = false
    @State private var closing = false

    let trailing: Trailing

    func body(content: Content) -> some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) { bar }   // a custom nav bar that reserves its own space
            .toolbar(.hidden, for: .navigationBar)   // no system bar — we draw our own, so opacity animates
        // Recognise the left-edge back-swipe ourselves and route it through the SAME close() as the tap,
        // so the buttons fade out identically whether you tap or swipe.
        .simultaneousGesture(
            DragGesture(minimumDistance: 18)
                .onChanged { v in
                    guard !closing,
                          v.startLocation.x < 32,
                          v.translation.width > 70,
                          abs(v.translation.height) < 60 else { return }
                    close()
                }
        )
        .onAppear { withAnimation(.easeOut(duration: 0.3)) { visible = true } }
    }

    private var bar: some View {
        HStack(spacing: 0) {
            GlassCircleButton(action: close) {
                Image(systemName: "chevron.backward")
                    .font(.body.weight(.semibold)).foregroundStyle(.primary)
            }
            .accessibilityLabel("Back")
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .opacity(visible ? 1 : 0)   // a real view, so this fades reliably in BOTH directions
    }

    /// Fade the header out AND pop at the same time, so the buttons fade as the view zooms away — one
    /// smooth motion. (The old fade-then-dismiss-in-completion sequence read as janky and was race-prone.)
    private func close() {
        guard !closing else { return }
        closing = true
        withAnimation(.easeOut(duration: 0.2)) { visible = false }
        dismiss()
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
        case .artist, .likedSongs: content
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
    case .likedSongs:             LikedSongsView()
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
            .artworkShadow()

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
    @Environment(\.libraryPush) private var push

    private var isCurrent: Bool { player.currentItem?.id == song.id }

    /// The song's ALBUM artist (the page that lists it) — falls back to the track performers.
    private var artistRoute: LibraryRoute? {
        guard let a = song.albumArtists?.first ?? song.artistItems?.first else { return nil }
        return .artist(MediaItem(id: a.id, name: a.name, type: "MusicArtist",
                                 sortName: nil, albumArtist: nil, albumArtists: nil, album: nil, albumId: nil,
                                 artistItems: nil, indexNumber: nil, parentIndexNumber: nil, runTimeTicks: nil,
                                 productionYear: nil, imageTags: nil, albumPrimaryImageTag: nil, childCount: nil,
                                 overview: nil, playlistItemId: nil))
    }

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
        // Animate the highlight HERE, scoped to the row — NOT page-wide on `player.currentItem`. A
        // page-level animation on a navigation destination leaks into the nav bar and makes the back
        // button slide/disappear when the track changes while the page is on screen.
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: isCurrent)
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
            if let artistRoute {
                Button { push(artistRoute) } label: { Label("Go to Artist", systemImage: "music.mic") }
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
                    PlayingIndicator(url: client.artworkURL(for: song, size: 160), active: player.isPlaying)
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
        .navigationBarTitleDisplayMode(.inline)
        .fadingDetailHeader()
        .task {
            albums = (try? await client.fetchAlbums(artistId: artist.id)) ?? []
            isLoading = false
        }
    }

    /// Play / Shuffle / Play Next / Play Last — all of the artist's songs (fetched on tap, in album order).
    private var playRow: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                artistAction(title: "Play", icon: "play.fill") { playAll(shuffled: false) }
                artistAction(title: "Shuffle", icon: "shuffle") { playAll(shuffled: true) }
            }
            HStack(spacing: 12) {
                artistAction(title: "Play Next", icon: "text.line.first.and.arrowtriangle.forward") { queueAll(next: true) }
                artistAction(title: "Play Last", icon: "text.line.last.and.arrowtriangle.forward") { queueAll(next: false) }
            }
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

    private func queueAll(next: Bool) {
        Task {
            let songs = (try? await client.fetchArtistSongs(artistId: artist.id)) ?? []
            guard !songs.isEmpty else { return }
            next ? player.playNext(songs) : player.playLast(songs)
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
