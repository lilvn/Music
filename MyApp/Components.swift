import SwiftUI

// MARK: - Design Constants

enum DS {
    static let hPad: CGFloat = 20          // horizontal padding for lists
    static let gridPad: CGFloat = 16       // horizontal padding for grids
    static let gridSpacing: CGFloat = 12   // spacing between grid cells
    static let cornerCard: CGFloat = 16    // album / artist cards
    static let cornerThumb: CGFloat = 10   // row thumbnails
    static let cornerMini: CGFloat = 11    // mini player artwork
    static let shadowRadius: CGFloat = 8
    static let shadowY: CGFloat = 4
    static let shadowOpacity: CGFloat = 0.12
    static let bottomClearance: CGFloat = 80   // clears the now-playing bar + search bar + tab bar
}

// MARK: - Navigation

/// Value-based navigation route. Identifiable so it can drive a `.sheet(item:)`.
enum LibraryRoute: Hashable, Identifiable {
    case album(MediaItem)
    case artist(MediaItem)
    case playlist(MediaItem)

    var id: String {
        switch self {
        case .album(let m):    return "album-\(m.id)"
        case .artist(let m):   return "artist-\(m.id)"
        case .playlist(let m): return "playlist-\(m.id)"
        }
    }
}

@ViewBuilder
func destinationView(for route: LibraryRoute) -> some View {
    switch route {
    case .album(let album):       AlbumDetailView(album: album)
    case .artist(let artist):     ArtistDetailView(artist: artist)
    case .playlist(let playlist): PlaylistDetailView(playlist: playlist)
    }
}

// MARK: - Card-open navigation (detail opens as a standard sheet — slides up, swipes down to close)

struct OpenDetailAction {
    let open: (LibraryRoute) -> Void
    let namespace: Namespace.ID
}

private struct OpenDetailKey: EnvironmentKey {
    static let defaultValue: OpenDetailAction? = nil
}

extension EnvironmentValues {
    var openDetail: OpenDetailAction? {
        get { self[OpenDetailKey.self] }
        set { self[OpenDetailKey.self] = newValue }
    }
}

/// Install once per screen that shows cards. Provides `openDetail` and presents the zoom cover that
/// scales out of the tapped card; the native zoom dismiss (drag down to shrink back) closes it.
private struct CardNavigation: ViewModifier {
    @State private var route: LibraryRoute?
    @Namespace private var ns

    func body(content: Content) -> some View {
        content
            .environment(\.openDetail, OpenDetailAction(open: { route = $0 }, namespace: ns))
            .fullScreenCover(item: $route) { r in
                DetailHost(route: r)
                    .navigationTransition(.zoom(sourceID: r.id, in: ns))
            }
    }
}

extension View {
    func cardNavigation() -> some View { modifier(CardNavigation()) }
}

/// Hosts a detail inside the sheet and re-installs `cardNavigation()` so nested cards (albums
/// inside an artist) open their own sheets.
struct DetailHost: View {
    let route: LibraryRoute
    var body: some View {
        destinationView(for: route)
            .cardNavigation()
    }
}

/// A tappable card that zooms `route` into a full-screen cover via the ambient `openDetail` action.
struct NavCard<Label: View>: View {
    let route: LibraryRoute
    @ViewBuilder var label: () -> Label
    @Environment(\.openDetail) private var action

    var body: some View {
        Button { action?.open(route) } label: { label() }
            .buttonStyle(ScaleButtonStyle())
            .modifier(OptionalMatchedSource(id: route.id, ns: action?.namespace))
    }
}

/// Applies `matchedTransitionSource` only when a namespace is available.
private struct OptionalMatchedSource: ViewModifier {
    let id: String
    let ns: Namespace.ID?
    func body(content: Content) -> some View {
        Group {
            if let ns { content.matchedTransitionSource(id: id, in: ns) }
            else { content }
        }
    }
}



// MARK: - Track swipe actions (native, monochrome — full-swipe plays next)

extension View {
    /// Native trailing swipe → Play Next (full-swipe) / Play Last; optional leading swipe → Remove.
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

// MARK: - Top edge fade

extension View {
    /// Fades scroll content out near the top so it dissolves under the notch / sheet grabber
    /// instead of being cut off sharply.
    func topEdgeFade(_ height: CGFloat = 46) -> some View {
        mask(
            VStack(spacing: 0) {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0), .init(color: .black, location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                .frame(height: height)
                Rectangle().fill(.black)
            }
            .ignoresSafeArea()
        )
    }
}

// MARK: - Artwork background (blurred art + dark gradient — same look as the Featured cards)

struct ArtworkBackground: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color.black
            AsyncImage(url: url) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(white: 0.12)
                }
            }
            .blur(radius: 55)
            .opacity(0.85)
            // Darker at the very top so the status bar / clock reads cleanly, art breathes through
            // the middle, dark again at the bottom for legible track lists.
            LinearGradient(stops: [
                .init(color: .black.opacity(0.62), location: 0.0),
                .init(color: .black.opacity(0.32), location: 0.3),
                .init(color: .black.opacity(0.55), location: 0.62),
                .init(color: .black.opacity(0.9), location: 1.0),
            ], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }
}

// MARK: - Spinning CD (shared by the mini bar and the Recently Added carousel)

struct SpinningDisc: View {
    let artURL: URL?
    let size: CGFloat
    let spinning: Bool

    /// Shared so the mini-bar CD and the carousel CD turn at exactly the same rate.
    static let spinSpeed: Double = 52   // degrees / second

    @State private var spinBase: Double = 0
    @State private var spinRef = Date()

    var body: some View {
        TimelineView(.animation(paused: !spinning)) { context in
            let angle = spinning
                ? spinBase + context.date.timeIntervalSince(spinRef) * Self.spinSpeed
                : spinBase
            disc.rotationEffect(.degrees(angle))
        }
        .onChange(of: spinning) { _, now in
            if now { spinRef = Date() }
            else { spinBase += Date().timeIntervalSince(spinRef) * Self.spinSpeed }
        }
    }

    private var disc: some View {
        ZStack {
            // CD face = album art.
            AsyncImage(url: artURL) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(1, contentMode: .fill)
                } else {
                    Color(.systemGray4)
                }
            }
            .clipShape(Circle())

            // Iridescent disc sheen.
            Circle()
                .fill(AngularGradient(
                    gradient: Gradient(colors: [
                        .clear, .white.opacity(0.38), .clear, .cyan.opacity(0.22), .clear,
                        .white.opacity(0.32), .clear, .pink.opacity(0.18), .clear,
                    ]),
                    center: .center))
                .blendMode(.screen)
                .opacity(0.55)

            // Outer rim highlight.
            Circle().strokeBorder(.white.opacity(0.18), lineWidth: max(0.5, size * 0.012))

            // Characteristic reflective CD ring around the hub.
            Circle()
                .strokeBorder(
                    AngularGradient(
                        colors: [.white.opacity(0.6), .white.opacity(0.1), .white.opacity(0.55),
                                 .white.opacity(0.1), .white.opacity(0.6)],
                        center: .center),
                    lineWidth: max(1, size * 0.022))
                .frame(width: size * 0.46, height: size * 0.46)

            // Hub (clear plastic label area) + spindle hole.
            Circle().fill(Color(.systemBackground)).frame(width: size * 0.32, height: size * 0.32)
            Circle().strokeBorder(.white.opacity(0.3), lineWidth: 0.8)
                .frame(width: size * 0.32, height: size * 0.32)
            Circle().fill(Color(.systemBackground).opacity(0.5)).frame(width: size * 0.11, height: size * 0.11)
            Circle().strokeBorder(.black.opacity(0.3), lineWidth: 0.7)
                .frame(width: size * 0.11, height: size * 0.11)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Scale Press Button Style

struct ScaleButtonStyle: ButtonStyle {
    var scale: CGFloat = 0.95
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.2, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

// MARK: - Album Card (fluid — fills whatever width the grid gives it)

struct AlbumCard: View {
    let album: MediaItem
    @EnvironmentObject var api: JellyfinAPI

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: api.artworkURL(for: album, size: 600)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(1, contentMode: .fill)
                case .empty:
                    Color(.systemGray6)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay { ProgressView().scaleEffect(0.65).tint(Color(.systemGray3)) }
                default:
                    Color(.systemGray6)
                        .aspectRatio(1, contentMode: .fit)
                        .overlay {
                            Image(systemName: "music.note")
                                .font(.title2)
                                .foregroundStyle(Color(.systemGray4))
                        }
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
            .shadow(color: .black.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)

            VStack(alignment: .leading, spacing: 2) {
                Text(album.name)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                Text(album.albumArtist ?? album.primaryArtist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

// MARK: - Artist Row

struct ArtistRow: View {
    let artist: MediaItem
    var large: Bool = false
    @EnvironmentObject var api: JellyfinAPI

    var body: some View {
        HStack(spacing: 14) {
            AsyncImage(url: api.artworkURL(for: artist, size: 120)) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(1, contentMode: .fill)
                } else {
                    Color(.systemGray5)
                        .overlay {
                            Image(systemName: "person.fill")
                                .font(.title3)
                                .foregroundStyle(Color(.systemGray3))
                        }
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
                .font(.footnote)
                .fontWeight(.semibold)
                .foregroundStyle(Color(.systemGray3))
        }
        .padding(.horizontal, DS.hPad)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

// MARK: - Song Row

struct SongRow: View {
    let song: MediaItem
    var showAlbumArt: Bool = false
    let onTap: () -> Void
    var onPlayNext: (() -> Void)? = nil
    var onPlayLast: (() -> Void)? = nil
    var onAddToPlaylist: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    var large: Bool = false
    @EnvironmentObject var api: JellyfinAPI
    @EnvironmentObject var player: AudioPlayerManager

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
            AsyncImage(url: api.artworkURL(for: song, size: 100)) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(1, contentMode: .fill)
                } else {
                    Color(.systemGray6)
                }
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
                } else if let idx = song.indexNumber {
                    Text("\(idx)")
                        .font(.footnote)
                        .monospacedDigit()
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

// MARK: - Artist Detail

struct ArtistDetailView: View {
    let artist: MediaItem
    @EnvironmentObject var api: JellyfinAPI
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
                            NavCard(route: .album(album)) { AlbumCard(album: album) }
                        }
                    }
                    .padding(.horizontal, DS.gridPad)
                    .padding(.top, 16)
                }

                Color.clear.frame(height: DS.bottomClearance)
            }
        }
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            albums = (try? await api.fetchAlbums(artistId: artist.id)) ?? []
            isLoading = false
        }
    }

    private var heroHeader: some View {
        ZStack(alignment: .bottomLeading) {
            AsyncImage(url: api.artworkURL(for: artist, size: 600)) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(contentMode: .fill)
                } else {
                    Color(.systemGray5)
                }
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
