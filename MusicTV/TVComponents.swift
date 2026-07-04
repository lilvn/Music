import SwiftUI

// MARK: - Shared TV building blocks (10-foot UI: big art, focus-driven cards)

/// Corner radii kept in step with the iPhone app (DS.cornerCard = 8, cornerArtwork = 12, cornerThumb =
/// 6) so covers read the same nearly-square way on TV instead of over-rounded.
enum TVDS {
    static let cover: CGFloat = 8      // album / playlist / flow covers
    static let artwork: CGFloat = 12   // large plain artwork (detail header, remote mirror)
    static let thumb: CGFloat = 6      // row thumbnails
}

/// tvOS renders a white platter/highlight over the label of ANY built-in button style on focus —
/// .plain draws it too. A custom ButtonStyle is the only full opt-out: the label renders bare, the
/// button stays focusable/clickable, and focus feedback is ours alone (the .focused-driven
/// magnification the cards already apply). Keeps a tiny press dip so remote clicks feel physical.
struct TVBareButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
extension ButtonStyle where Self == TVBareButtonStyle {
    static var tvBare: TVBareButtonStyle { .init() }
}

/// Where a browse card leads. Local to the TV app — the phone's LibraryRoute carries iPhone-only cases.
enum TVCollection: Hashable {
    case album(MediaItem)
    case artist(MediaItem)
    case playlist(MediaItem)
    case liked
    case musicVideos
}

/// Starting playback from a click anywhere in the TV UI jumps to the Now Playing tab — provided by
/// TVRootView, called by the tap sites (song rows, shelves, play/shuffle buttons).
private struct TVOpenNowPlayingKey: EnvironmentKey {
    static let defaultValue: @MainActor () -> Void = {}
}
extension EnvironmentValues {
    var tvOpenNowPlaying: @MainActor () -> Void {
        get { self[TVOpenNowPlayingKey.self] }
        set { self[TVOpenNowPlayingKey.self] = newValue }
    }
}

/// Artwork placeholder for items with no cover — the SAME art as the phone (Components.swift's
/// ArtworkPlaceholder): a subtle dark panel with the custom heart-speaker mark, sized relative to
/// the panel so it reads correctly from a row thumbnail up to the Now Playing centrepiece.
struct TVPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // The heart-speaker mark, scaled to ~40% of the tile. Uses scaleEffect (a render transform),
            // NOT a GeometryReader — a GeometryReader here (rendered by every cover on Home, inside an
            // .aspectRatio) drove a DynamicLayoutComputer / _AspectRatioLayout churn that crashed
            // SwiftUI's layout on launch. This scales with any tile size without measuring it.
            Image("ArtworkPlaceholder")
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .scaleEffect(0.4)
                .opacity(0.9)
        }
    }
}

/// A focusable square cover card (album / playlist) with its labels below. Focus lifts the WHOLE tile
/// with a render-only scale — `.borderless`/`.card` zoomed the picture *inside* its fixed frame instead.
struct TVCoverCard: View {
    @Environment(JellyfinClient.self) private var client
    @FocusState private var focused: Bool
    let item: MediaItem
    var subtitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LibraryImage(url: client.artworkURL(for: item, size: 600), maxPixel: 600) {
                TVPlaceholder()
            }
            .aspectRatio(1, contentMode: .fill)
            // Clip BOTH the art and the missing-art placeholder to the same rounded corners, so a
            // coverless album isn't a square tile among rounded ones.
            .clipShape(RoundedRectangle(cornerRadius: TVDS.cover, style: .continuous))
        }
        .buttonStyle(.tvBare)   // no system white platter — the magnification below is the focus cue
        .focused($focused)
        .scaleEffect(focused ? 1.08 : 1.0)   // render transform (no layout measurement — launch-crash safe)
        .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: focused ? 22 : 0, y: focused ? 14 : 0)
        .animation(.easeOut(duration: 0.18), value: focused)
        .accessibilityLabel(item.name)
    }
}

/// Card + title/subtitle stack used in shelves and grids.
struct TVCoverCell: View {
    let item: MediaItem
    var subtitle: String? = nil
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TVCoverCard(item: item, action: action)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.callout).lineLimit(1)
                Text(subtitle ?? item.primaryArtist)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .padding(.horizontal, 4)
        }
    }
}

/// A focusable track row: art, title/artist, duration. Highlights the playing track. Tapping runs
/// `action` (start playback) and jumps to Now Playing.
struct TVSongRow: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @Environment(\.tvOpenNowPlaying) private var openNowPlaying
    let song: MediaItem
    var showArt = true
    let action: () -> Void

    private var isCurrent: Bool { player.currentItem?.id == song.id }

    var body: some View {
        Button(action: { action(); openNowPlaying() }) {
            HStack(spacing: 20) {
                if showArt {
                    LibraryImage(url: client.artworkURL(for: song, size: 160), maxPixel: 160) {
                        TVPlaceholder()
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: TVDS.thumb, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.name)
                        .font(.headline)
                        .fontWeight(isCurrent ? .bold : .semibold)
                        .lineLimit(1)
                    Text(song.primaryArtist)
                        .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 16)
                if isCurrent {
                    Image(systemName: "waveform")
                        .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                        .foregroundStyle(.secondary)
                }
                if let d = song.durationSeconds {
                    Text(d.formattedDuration)
                        .font(.subheadline).monospacedDigit().foregroundStyle(.tertiary)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 12)
        }
        // Liquid Glass row platter with the native focus lift — replaces .plain's white lozenge.
        .buttonStyle(.glass)
        .buttonBorderShape(.roundedRectangle(radius: TVDS.artwork))
    }
}

/// Full-screen backdrop: the artwork blurred to a wash, darkened for legibility (static — cheap).
struct TVBackdrop: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem?

    var body: some View {
        ZStack {
            Color.black
            if let item {
                LibraryImage(url: client.artworkURL(for: item, size: 400), maxPixel: 400) { Color.black }
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 90, opaque: true)
                    .saturation(1.3)
                    .opacity(0.45)
            }
        }
        .ignoresSafeArea()
    }
}

/// A focusable circular artist cell (avatar + name), for the Home artists shelf.
struct TVArtistCell: View {
    @Environment(JellyfinClient.self) private var client
    @FocusState private var focused: Bool
    let artist: MediaItem
    let action: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Button(action: action) {
                LibraryImage(url: client.artworkURL(for: artist, size: 400), maxPixel: 400) {
                    ZStack {
                        Color(white: 0.18)
                        Image(systemName: "music.mic")
                            .font(.system(size: 40, weight: .light))
                            .foregroundStyle(.secondary)
                    }
                }
                .aspectRatio(1, contentMode: .fill)
                .clipShape(Circle())
            }
            .buttonStyle(.tvBare)   // no system white platter — the magnification below is the focus cue
            .focused($focused)
            .scaleEffect(focused ? 1.08 : 1.0)   // lift the whole avatar, not the photo inside it
            .shadow(color: .black.opacity(focused ? 0.45 : 0), radius: focused ? 20 : 0, y: focused ? 12 : 0)
            .animation(.easeOut(duration: 0.18), value: focused)

            Text(artist.name)
                .font(.caption)
                .lineLimit(1)
        }
    }
}

/// Shelf: a horizontally scrolling row of cover cells with a section title.
struct TVShelf: View {
    let title: String
    let items: [MediaItem]
    var subtitle: ((MediaItem) -> String)? = nil
    let action: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(title).font(.title3).fontWeight(.semibold)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 40) {
                    ForEach(items) { item in
                        TVCoverCell(item: item, subtitle: subtitle?(item), action: { action(item) })
                            .frame(width: 260)
                    }
                }
                .padding(.vertical, 20)   // room for the focus lift so it doesn't clip
            }
            .scrollClipDisabled()
        }
    }
}
