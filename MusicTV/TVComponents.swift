import SwiftUI

// MARK: - Shared TV building blocks (10-foot UI: big art, focus-driven cards)

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

/// A focusable square cover card (album / playlist) with its labels below. The `.card` (now `.borderless`
/// on tvOS 18+) button style gives the system focus lift + specular sheen.
struct TVCoverCard: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    var subtitle: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            LibraryImage(url: client.artworkURL(for: item, size: 600), maxPixel: 600) {
                TVPlaceholder()
            }
            .aspectRatio(1, contentMode: .fill)
        }
        .buttonStyle(.borderless)
        .overlay(alignment: .bottom) { EmptyView() }
        // Labels live OUTSIDE the button so the focus lift only scales the artwork.
        .padding(.bottom, 0)
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
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
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
            .padding(.vertical, 4)
        }
        .buttonStyle(.plain)
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
            .buttonStyle(.borderless)
            .clipShape(Circle())

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
