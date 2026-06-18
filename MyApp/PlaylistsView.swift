import SwiftUI

struct PlaylistsView: View {
    @EnvironmentObject var api: JellyfinAPI
    @State private var playlists: [MediaItem] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var showCreate = false
    @State private var newName = ""

    private let cols = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: DS.gridSpacing)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Playlists").font(.largeTitle).fontWeight(.bold)
                        Spacer()
                        Button { newName = ""; showCreate = true } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 17, weight: .semibold))
                                .frame(width: 38, height: 38)
                                .glassEffect(.regular, in: .circle)
                        }
                    }
                    .padding(.horizontal, DS.gridPad)
                    .padding(.top, 4)
                    .padding(.bottom, 6)

                    if playlists.isEmpty && isLoading {
                        CenteredState(systemImage: nil, title: "Loading", loading: true)
                    } else if playlists.isEmpty && loadFailed {
                        CenteredState(systemImage: "wifi.exclamationmark", title: "Couldn't load playlists") {
                            Button("Try Again") { Task { await load(force: true) } }
                                .buttonStyle(.bordered)
                        }
                    } else if playlists.isEmpty {
                        CenteredState(systemImage: "music.note.list",
                                      title: "No playlists yet\nTap + to create one.")
                    } else {
                        LazyVGrid(columns: cols, spacing: DS.gridSpacing + 4) {
                            ForEach(playlists) { playlist in
                                NavCard(route: .playlist(playlist)) {
                                    PlaylistCard(playlist: playlist)
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        Task { try? await api.deletePlaylist(playlist.id); await load(force: true) }
                                    } label: { Label("Delete Playlist", systemImage: "trash") }
                                }
                            }
                        }
                        .padding(.horizontal, DS.gridPad)
                        .padding(.top, 4)
                        .padding(.bottom, DS.bottomClearance)
                    }
                }
            }
            .topEdgeFade()
            .toolbar(.hidden, for: .navigationBar)
            .cardNavigation()
            .refreshable { await load(force: true) }
            .alert("New Playlist", isPresented: $showCreate) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let name = newName.trimmingCharacters(in: .whitespaces)
                    guard !name.isEmpty else { return }
                    Task { _ = try? await api.createPlaylist(name: name); await load(force: true) }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .task { await load() }
    }

    private func load(force: Bool = false) async {
        guard playlists.isEmpty || force else { return }
        isLoading = true
        loadFailed = false
        do { playlists = try await api.fetchPlaylists() }
        catch { loadFailed = true }
        isLoading = false
    }
}

// MARK: - Playlist Card

struct PlaylistCard: View {
    let playlist: MediaItem
    @EnvironmentObject var api: JellyfinAPI

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: api.artworkURL(for: playlist, size: 600)) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(1, contentMode: .fill)
                } else {
                    Color(.systemGray6)
                        .overlay {
                            Image(systemName: "music.note.list")
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
                Text(playlist.name)
                    .font(.footnote)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if let count = playlist.childCount {
                    Text("\(count) song\(count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

// MARK: - Playlist Detail

struct PlaylistDetailView: View {
    let playlist: MediaItem
    @EnvironmentObject var api: JellyfinAPI
    @EnvironmentObject var player: AudioPlayerManager
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true
    @State private var pickerTrack: MediaItem?
    @State private var editMode: EditMode = .inactive

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
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    .padding(.vertical, 40)
            } else if tracks.isEmpty {
                Text("This playlist is empty")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden).listRowBackground(Color.clear)
                    .padding(.vertical, 40)
            } else {
                ForEach(tracks) { song in
                    SongRow(song: song, showAlbumArt: true,
                            onTap: { player.play(items: tracks, from: tracks.firstIndex { $0.id == song.id } ?? 0, api: api) },
                            onPlayNext: { player.playNext(song, api: api) },
                            onPlayLast: { player.playLast(song, api: api) },
                            onAddToPlaylist: { pickerTrack = song },
                            onRemove: { remove(song) })
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .trackSwipeActions(onPlayNext: { player.playNext(song, api: api) },
                                           onPlayLast: { player.playLast(song, api: api) },
                                           onRemove: { remove(song) })
                }
                .onMove(perform: move)
                .onDelete { offsets in offsets.map { tracks[$0] }.forEach(remove) }
            }

            Color.clear.frame(height: DS.bottomClearance)
                .listRowSeparator(.hidden).listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background { ArtworkBackground(url: api.artworkURL(for: playlist, size: 600)) }
        .environment(\.colorScheme, .dark)
        .environment(\.editMode, $editMode)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $pickerTrack) { PlaylistPickerSheet(track: $0) }
        .task { await reload() }
    }

    /// Reorder locally (optimistic) and sync each moved entry's new index to the server.
    private func move(from: IndexSet, to: Int) {
        let moved = from.map { tracks[$0] }
        tracks.move(fromOffsets: from, toOffset: to)
        for item in moved {
            guard let entry = item.playlistItemId,
                  let newIndex = tracks.firstIndex(where: { $0.id == item.id }) else { continue }
            Task { try? await api.movePlaylistItem(playlist.id, entryId: entry, to: newIndex) }
        }
    }

    private func reload() async {
        tracks = (try? await api.fetchPlaylistItems(playlistId: playlist.id)) ?? []
        isLoading = false
    }

    private func remove(_ song: MediaItem) {
        guard let entry = song.playlistItemId else { return }
        // Optimistic removal so the row vanishes immediately, then sync with the server.
        withAnimation { tracks.removeAll { $0.id == song.id } }
        Task { try? await api.removeFromPlaylist(playlist.id, entryIds: [entry]); await reload() }
    }

    private var header: some View {
        VStack(spacing: 12) {
            AsyncImage(url: api.artworkURL(for: playlist, size: 800)) { phase in
                if case .success(let img) = phase {
                    img.resizable().aspectRatio(1, contentMode: .fill)
                } else {
                    Color(.systemGray6)
                        .overlay {
                            Image(systemName: "music.note.list")
                                .font(.system(size: 60, weight: .ultraLight))
                                .foregroundStyle(Color(.systemGray4))
                        }
                }
            }
            .frame(width: 220, height: 220)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 16, y: 8)

            VStack(spacing: 4) {
                Text(playlist.name)
                    .font(.title2).fontWeight(.bold)
                    .multilineTextAlignment(.center)
                if let count = playlist.childCount {
                    Text("\(count) song\(count == 1 ? "" : "s")")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 14) {
                playButton
                if !tracks.isEmpty {
                    Button {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    } label: {
                        Label(editMode.isEditing ? "Done" : "Edit",
                              systemImage: editMode.isEditing ? "checkmark" : "arrow.up.arrow.down")
                            .font(.subheadline.weight(.medium))
                            .padding(.horizontal, 18).padding(.vertical, 14)
                    }
                    .buttonStyle(.glass)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 16)
        .padding(.horizontal, DS.hPad)
        .padding(.bottom, 8)
    }

    private var playButton: some View {
        Button {
            guard !tracks.isEmpty else { return }
            player.play(items: tracks, from: 0, api: api)
        } label: {
            Label("Play", systemImage: "play.fill")
                .font(.headline)
                .padding(.horizontal, 36).padding(.vertical, 14)
        }
        .buttonStyle(.glass)
    }
}

// MARK: - Add to Playlist picker

struct PlaylistPickerSheet: View {
    let track: MediaItem
    @EnvironmentObject var api: JellyfinAPI
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [MediaItem] = []
    @State private var loading = true
    @State private var showCreate = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Button { newName = ""; showCreate = true } label: {
                    Label("New Playlist", systemImage: "plus.circle.fill")
                }
                if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }
                } else {
                    ForEach(playlists) { pl in
                        Button { add(to: pl.id) } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: api.artworkURL(for: pl, size: 100)) { phase in
                                    if case .success(let img) = phase {
                                        img.resizable().aspectRatio(1, contentMode: .fill)
                                    } else {
                                        Color(.systemGray6).overlay {
                                            Image(systemName: "music.note.list").foregroundStyle(.tertiary)
                                        }
                                    }
                                }
                                .frame(width: 44, height: 44)
                                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(pl.name).foregroundStyle(.primary).lineLimit(1)
                                    if let c = pl.childCount {
                                        Text("\(c) song\(c == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .alert("New Playlist", isPresented: $showCreate) {
                TextField("Name", text: $newName)
                Button("Create") {
                    let n = newName.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { return }
                    Task { _ = try? await api.createPlaylist(name: n, itemIds: [track.id]); dismiss() }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            playlists = (try? await api.fetchPlaylists()) ?? []
            loading = false
        }
    }

    private func add(to playlistId: String) {
        Task { try? await api.addToPlaylist(playlistId, itemIds: [track.id]); dismiss() }
    }
}
