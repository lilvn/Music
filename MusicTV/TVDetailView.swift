import SwiftUI

/// Album / playlist / Liked Songs detail: big cover on the left, focusable track list on the right —
/// the classic tvOS two-pane layout.
struct TVCollectionDetailView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    let collection: TVCollection
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true

    private var headerItem: MediaItem? {
        switch collection {
        case .album(let a): a
        case .playlist(let p): p
        case .liked: nil
        }
    }
    private var title: String {
        switch collection {
        case .album(let a): a.name
        case .playlist(let p): p.name
        case .liked: "Liked Songs"
        }
    }
    private var subtitle: String {
        switch collection {
        case .album(let a): a.albumArtist ?? a.primaryArtist
        case .playlist: "Playlist"
        case .liked: "\(tracks.count) songs"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 60) {
            // Left pane: cover + play controls.
            VStack(spacing: 24) {
                Group {
                    if let headerItem {
                        LibraryImage(url: client.artworkURL(for: headerItem, size: 800), maxPixel: 800) {
                            TVPlaceholder()
                        }
                    } else {
                        ZStack {
                            LinearGradient(colors: [Color(red: 0.30, green: 0.30, blue: 0.32),
                                                    Color(red: 0.03, green: 0.03, blue: 0.05)],
                                           startPoint: .top, endPoint: .bottom)
                            Image(systemName: "heart.fill")
                                .font(.system(size: 96))
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                }
                .frame(width: 480, height: 480)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .shadow(color: .black.opacity(0.4), radius: 24, y: 12)

                VStack(spacing: 6) {
                    Text(title).font(.title3).fontWeight(.bold)
                        .multilineTextAlignment(.center).lineLimit(2)
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                }
                .frame(width: 480)

                HStack(spacing: 20) {
                    Button {
                        player.play(items: tracks, from: 0)
                    } label: { Label("Play", systemImage: "play.fill") }
                    Button {
                        player.play(items: tracks, from: 0, shuffled: true)
                    } label: { Label("Shuffle", systemImage: "shuffle") }
                }
                .disabled(tracks.isEmpty)
            }

            // Right pane: the tracks.
            ScrollView {
                LazyVStack(spacing: 6) {
                    if isLoading {
                        ProgressView().padding(60)
                    } else if tracks.isEmpty {
                        Text("No songs here yet.")
                            .foregroundStyle(.secondary).padding(60)
                    } else {
                        ForEach(Array(tracks.enumerated()), id: \.element.id) { i, track in
                            TVSongRow(song: track, showArt: !isAlbum) {
                                player.play(items: tracks, from: i)
                            }
                        }
                    }
                }
                .padding(.vertical, 20)
            }
        }
        .padding(.horizontal, 80)
        .padding(.top, 40)
        .background { TVBackdrop(item: headerItem ?? tracks.first) }
        .task { await load() }
    }

    private var isAlbum: Bool { if case .album = collection { true } else { false } }

    private func load() async {
        switch collection {
        case .album(let a):    tracks = (try? await client.fetchAlbumTracks(albumId: a.id)) ?? []
        case .playlist(let p): tracks = (try? await client.fetchPlaylistItems(playlistId: p.id)) ?? []
        case .liked:
            let fetched = (try? await client.fetchFavoriteSongs()) ?? []
            client.favoriteIds = Set(fetched.map(\.id))
            client.reconcileLikedOrder(with: fetched.map(\.id))
            let rank = client.likeRank
            tracks = fetched.enumerated().sorted {
                let a = rank[$0.element.id] ?? Int.max
                let b = rank[$1.element.id] ?? Int.max
                return a != b ? a < b : $0.offset < $1.offset
            }.map(\.element)
        }
        isLoading = false
    }
}
