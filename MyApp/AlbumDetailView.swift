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

    private var info: MediaItem { albumDetail ?? album }
    private var totalSeconds: Double { tracks.reduce(0) { $0 + ($1.durationSeconds ?? 0) } }

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
                                    onAddToPlaylist: { addRequest = PlaylistAddRequest(itemIds: [track.id]) })
                                .id(track.id)
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowBackground(track.id == highlightSongId
                                                   ? Color.primary.opacity(0.08) : Color.clear)
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
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
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

    private func formatLength(_ s: Double) -> String {
        let t = Int(s.rounded())
        let h = t / 3600, m = (t % 3600) / 60, sec = t % 60
        return h > 0 ? "\(h)h \(m)m \(sec)s" : "\(m)m \(sec)s"
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
            Color(.secondarySystemBackground)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                }
        }
        .frame(width: 240, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: DS.cornerArtwork, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 10)
        .frame(maxWidth: .infinity)
    }

    private var metadata: some View {
        let count = tracks.isEmpty ? (info.childCount ?? 0) : tracks.count
        return VStack(spacing: 6) {
            Text(info.name)
                .font(.title2).fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.hPad)
            Text(info.albumArtist ?? info.primaryArtist)
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let year = info.productionYear { Text(String(year)) }
                if info.productionYear != nil, count > 0 { Text("·").foregroundStyle(.quaternary) }
                if count > 0 { Text("\(count) song\(count == 1 ? "" : "s")") }
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
            if totalSeconds > 0 {
                Text(formatLength(totalSeconds))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
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
