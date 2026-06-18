import SwiftUI

struct AlbumDetailView: View {
    let album: MediaItem
    @EnvironmentObject var api: JellyfinAPI
    @EnvironmentObject var player: AudioPlayerManager
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true
    @State private var pickerTrack: MediaItem?

    var body: some View {
        List {
            Section {
                header
                    .killScrollBounce()
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
                                    onTap: { player.play(items: tracks, from: idx, api: api) },
                                    onPlayNext: { player.playNext(track, api: api) },
                                    onPlayLast: { player.playLast(track, api: api) },
                                    onAddToPlaylist: { pickerTrack = track })
                                .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                                .listRowBackground(Color.clear)
                                .trackSwipeActions(onPlayNext: { player.playNext(track, api: api) },
                                                   onPlayLast: { player.playLast(track, api: api) })
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

            Color.clear.miniBarClearance()
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pickerTrack) { PlaylistPickerSheet(track: $0) }
        .task {
            tracks = (try? await api.fetchTracks(parentId: album.id)) ?? []
            isLoading = false
        }
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

    /// Play pill flanked by a round "play next" (left) and "add to queue" (right).
    private var playRow: some View {
        HStack(spacing: 16) {
            QueueActionButton(icon: "text.line.first.and.arrowtriangle.forward",
                              disabled: tracks.isEmpty) { player.playNext(tracks, api: api) }
            playButton
            QueueActionButton(icon: "text.line.last.and.arrowtriangle.forward",
                              disabled: tracks.isEmpty) { player.playLast(tracks, api: api) }
        }
    }

    private var artwork: some View {
        LibraryImage(url: api.artworkURL(for: album, size: 600), maxPixel: 600) {
            Color(.secondarySystemBackground)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                }
        }
        .frame(width: 240, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 18, y: 10)
        .frame(maxWidth: .infinity)
    }

    private var metadata: some View {
        VStack(spacing: 6) {
            Text(album.name)
                .font(.title2).fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DS.hPad)
            Text(album.albumArtist ?? album.primaryArtist)
                .font(.callout).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let year = album.productionYear { Text(String(year)) }
                if album.productionYear != nil, album.childCount != nil {
                    Text("·").foregroundStyle(.quaternary)
                }
                if let count = album.childCount { Text("\(count) song\(count == 1 ? "" : "s")") }
            }
            .font(.footnote)
            .foregroundStyle(.tertiary)
        }
    }

    private var playButton: some View {
        Button {
            guard !tracks.isEmpty else { return }
            player.play(items: tracks, from: 0, api: api)
        } label: {
            Label("Play", systemImage: "play.fill")
                .font(.headline)
                .foregroundStyle(Color(.systemBackground))
                .padding(.horizontal, 44)
                .padding(.vertical, 14)
                .background(Color.primary, in: .capsule)
        }
        .buttonStyle(.plain)
    }
}
