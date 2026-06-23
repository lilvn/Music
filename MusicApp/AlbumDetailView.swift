import SwiftUI

struct AlbumDetailView: View {
    let album: MediaItem
    /// When set (e.g. opened from a Recently Played song), that track is tinted and scrolled into view.
    var highlightSongId: String? = nil
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true
    @State private var addRequest: PlaylistAddRequest?
    /// Full album metadata fetched by id (so an album opened from a track — e.g. Recently Played —
    /// still gets its name / year / artwork).
    @State private var albumDetail: MediaItem?

    @Environment(\.libraryPush) private var push
    @Namespace private var trackHighlightNS

    private var info: MediaItem { albumDetail ?? album }
    private var totalSeconds: Double { tracks.reduce(0) { $0 + ($1.durationSeconds ?? 0) } }

    /// A minimal artist item for navigation (ArtistDetailView fetches full metadata by id).
    private var artistItem: MediaItem? {
        guard let a = info.artistItems?.first ?? info.albumArtists?.first else { return nil }
        return MediaItem(id: a.id, name: a.name, type: "MusicArtist", sortName: nil, albumArtist: nil,
                         albumArtists: nil, album: nil, albumId: nil, artistItems: nil, indexNumber: nil,
                         parentIndexNumber: nil, runTimeTicks: nil, productionYear: nil, imageTags: nil,
                         albumPrimaryImageTag: nil, childCount: nil, overview: nil, playlistItemId: nil)
    }

    private var lengthSummary: String {
        let totalMin = Int(totalSeconds / 60)
        if totalMin >= 60 {
            let h = totalMin / 60, m = totalMin % 60
            return m > 0 ? "\(h) hr \(m) min" : "\(h) hr"
        }
        return "\(max(1, totalMin)) min"
    }

    var body: some View {
        ScrollViewReader { proxy in
        List {
            Section {
                header
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 40)
            } else {
                let discs = Dictionary(grouping: tracks) { $0.parentIndexNumber ?? 1 }
                let sorted = discs.keys.sorted()
                ForEach(sorted, id: \.self) { disc in
                    Section {
                        ForEach(Array((discs[disc] ?? []).enumerated()), id: \.element.id) { discPos, track in
                            let idx = tracks.firstIndex { $0.id == track.id } ?? 0
                            SongRow(song: track, showAlbumArt: false,
                                    trackNumber: track.indexNumber ?? (discPos + 1),
                                    onTap: { player.play(items: tracks, from: idx) },
                                    onPlayNext: { player.playNext(track) },
                                    onPlayLast: { player.playLast(track) },
                                    onAddToPlaylist: { addRequest = PlaylistAddRequest(itemIds: [track.id]) },
                                    highlightNamespace: trackHighlightNS)
                                .id(track.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowSeparator(.hidden)
                                .listRowBackground(track.id == highlightSongId
                                                   ? Color.primary.opacity(0.10) : Color.clear)
                                .trackSwipeActions(onPlayNext: { player.playNext(track) },
                                                   onPlayLast: { player.playLast(track) })
                        }
                    } header: {
                        if sorted.count > 1 {
                            Label("Disc \(disc)", systemImage: "opticaldisc.fill")
                                .font(.footnote).fontWeight(.medium)
                                .foregroundStyle(.secondary)
                                .textCase(nil)
                        }
                    }
                }

                Section {
                    albumFooter
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { ArtworkBackground(url: client.artworkURL(for: info, size: 400)) }
        .scrollIndicators(.hidden)
        .animation(.spring(response: 0.4, dampingFraction: 0.82), value: player.currentItem?.id)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $addRequest) { PlaylistPickerSheet(request: $0) }
        .task {
            async let detail = client.fetchItem(id: album.id)
            async let trks = client.fetchTracks(parentId: album.id)
            albumDetail = try? await detail
            tracks = (try? await trks) ?? []
            isLoading = false
            if let h = highlightSongId {
                try? await Task.sleep(for: .milliseconds(300))
                withAnimation(.easeInOut) { proxy.scrollTo(h, anchor: .center) }
            }
        }
        }   // ScrollViewReader
    }

    private var header: some View {
        VStack(spacing: 0) {
            artwork
            metadata.padding(.top, 18)
            playRow.padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    /// Play pill flanked by round "play last" (left) and "play next" (right).
    private var playRow: some View {
        HStack(spacing: 16) {
            QueueActionButton(icon: "text.line.last.and.arrowtriangle.forward",
                              disabled: tracks.isEmpty) { player.playLast(tracks) }
            playButton
            QueueActionButton(icon: "text.line.first.and.arrowtriangle.forward",
                              disabled: tracks.isEmpty) { player.playNext(tracks) }
        }
    }

    private var artwork: some View {
        LibraryImage(url: client.artworkURL(for: info, size: 600), maxPixel: 600) {
            ArtworkPlaceholder()
        }
        .frame(width: 240, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: DS.cornerArtwork, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 10)
        .frame(maxWidth: .infinity)
    }

    private var metadata: some View {
        VStack(spacing: 6) {
            Text(info.name)
                .font(.title2).fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.hPad)
            // Tappable artist → artist profile.
            if let artistItem {
                Button { push(.artist(artistItem)) } label: {
                    Text(artistItem.name)
                        .font(.callout).fontWeight(.medium)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            } else {
                Text(info.albumArtist ?? info.primaryArtist)
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    /// Apple-Music-style footer beneath the tracklist: song count + total time, then the year.
    private var albumFooter: some View {
        let count = tracks.count
        return VStack(alignment: .leading, spacing: 4) {
            Text("\(count) song\(count == 1 ? "" : "s")" + (totalSeconds > 0 ? ", \(lengthSummary)" : ""))
                .font(.footnote).foregroundStyle(.secondary)
            if let year = info.productionYear {
                Text(verbatim: String(year))
                    .font(.footnote).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DS.hPad)
        .padding(.top, 18)
        .padding(.bottom, 28)
    }

    private var playButton: some View {
        Button {
            guard !tracks.isEmpty else { return }
            player.play(items: tracks, from: 0)
        } label: {
            Label("Play", systemImage: "play.fill")
                .font(.headline)
                .foregroundStyle(.primary)
                .padding(.horizontal, 44)
                .padding(.vertical, 14)
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(tracks.isEmpty)
    }
}
