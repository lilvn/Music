import SwiftUI

/// A 6×6 grid of the heart mark — the Liked Songs cover.
struct HeartGridCover: View {
    var body: some View {
        GeometryReader { geo in
            // /6.2 (not /6) leaves an even outer margin equal to each heart's own padding, so the grid
            // sits inset from the cover's rounded edges with the same spacing seen between the hearts.
            let cell = geo.size.width / 6.2
            VStack(spacing: 0) {
                ForEach(0..<6, id: \.self) { _ in
                    HStack(spacing: 0) {
                        ForEach(0..<6, id: \.self) { _ in
                            Image("LikeHeart")
                                .resizable()
                                .scaledToFit()
                                .padding(cell * 0.10)          // even breathing room on all four sides
                                .frame(width: cell, height: cell)
                        }
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.width)
        }
        .aspectRatio(1, contentMode: .fit)
        .background(
            // Same dark gray→black "glass" gradient as the app icon background.
            LinearGradient(colors: [Color(red: 0.30, green: 0.30, blue: 0.32),
                                    Color(red: 0.03, green: 0.03, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
        )
    }
}

/// Favourites-backed "Liked Songs" — newest first, with a heart-grid cover. Not a real playlist, so it
/// can't be deleted; songs are added/removed via the heart in Now Playing.
struct LikedSongsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true
    @State private var addRequest: PlaylistAddRequest?
    @Namespace private var trackHighlightNS

    /// What's actually shown — the loaded order minus anything just unliked, so removing a like (row
    /// menu or swipe) drops it live without a refetch.
    private var displayed: [MediaItem] { tracks.filter { client.favoriteIds.contains($0.id) } }

    var body: some View {
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden).listRowBackground(Color.clear).padding(.vertical, 40)
            } else if displayed.isEmpty {
                Text("Songs you like will show up here. Tap the heart on a song in Now Playing.")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    .padding(.vertical, 40).padding(.horizontal, DS.hPad)
            } else {
                ForEach(Array(displayed.enumerated()), id: \.element.id) { index, track in
                    SongRow(song: track, showAlbumArt: true,
                            onTap: { player.play(items: displayed, from: index) },
                            onPlayNext: { player.playNext(track) },
                            onPlayLast: { player.playLast(track) },
                            onAddToPlaylist: { addRequest = PlaylistAddRequest(itemIds: [track.id]) },
                            highlightNamespace: trackHighlightNS)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button(role: .destructive) { unlike(track) } label: {
                                Label("Unlike", systemImage: "heart.slash")
                            }.tint(.pink)
                        }
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)   // kill the default header→tracks gap; the header owns its own cushion
        .scrollContentBackground(.hidden)
        // Wash derived from the Liked Songs cover itself (the heart grid's dark gradient), not a random
        // song's art — toned toward the system background so the list text stays legible in either mode.
        .background {
            LinearGradient(colors: [Color(red: 0.30, green: 0.30, blue: 0.32),
                                    Color(red: 0.03, green: 0.03, blue: 0.05)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(Color(.systemBackground).opacity(0.62))
                .ignoresSafeArea()
        }
        .scrollIndicators(.hidden)
        // (highlight animation lives on the row itself — see SongRow — so it never reaches the nav bar)
        .navigationBarTitleDisplayMode(.inline)
        .fadingDetailHeader()
        .sheet(item: $addRequest) { PlaylistPickerSheet(request: $0) }
        .task { await reload() }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HeartGridCover()
                .frame(width: 240, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: DS.cornerArtwork, style: .continuous))
                .artworkShadow()

            Text("Liked Songs")
                .font(.title2).fontWeight(.bold)
                .padding(.top, 18)
            Text("\(displayed.count) song\(displayed.count == 1 ? "" : "s")")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.top, 4)

            // 2×2 play grid, consistent with the other playlists.
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    action("Play", "play.fill") { player.play(items: displayed, from: 0) }
                    action("Shuffle", "shuffle") { player.play(items: displayed, from: 0, shuffled: true) }
                }
                HStack(spacing: 12) {
                    action("Play Last", "text.line.last.and.arrowtriangle.forward") { player.playLast(displayed) }
                    action("Play Next", "text.line.first.and.arrowtriangle.forward") { player.playNext(displayed) }
                }
            }
            .padding(.horizontal, DS.hPad)
            .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 14)   // deliberate, consistent gap down to the first track
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                .frame(maxWidth: .infinity).frame(height: 46)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(displayed.isEmpty)
    }

    private func reload() async {
        let fetched = (try? await client.fetchFavoriteSongs()) ?? []
        client.favoriteIds = Set(fetched.map(\.id))            // keep the cached set in sync
        client.reconcileLikedOrder(with: fetched.map(\.id))    // drop stale, learn likes from other clients
        // Sort by when each song was liked (most-recent first); ties keep the server order. Jellyfin
        // can't sort by "date favourited", so this local order is what puts new likes at the top.
        let rank = client.likeRank
        tracks = fetched.enumerated().sorted {
            let a = rank[$0.element.id] ?? Int.max
            let b = rank[$1.element.id] ?? Int.max
            return a != b ? a < b : $0.offset < $1.offset
        }.map(\.element)
        isLoading = false
    }

    /// Unlike from the swipe action — drops the row live via `displayed` (which filters on favouriteIds).
    private func unlike(_ track: MediaItem) {
        Task { await client.setFavorite(track.id, false) }
    }
}

/// The pinned "Liked Songs" tile in the Playlists grid.
struct LikedSongsCard: View {
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HeartGridCover()
                .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
                .artworkShadow()

            VStack(alignment: .leading, spacing: 2) {
                Text("Liked Songs")
                    .font(.footnote).fontWeight(.semibold).lineLimit(1)
                Text("\(client.favoriteIds.count) song\(client.favoriteIds.count == 1 ? "" : "s")")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}
