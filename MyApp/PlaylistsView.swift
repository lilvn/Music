import SwiftUI

// MARK: - Playlists tab

struct PlaylistsView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var playlists: [MediaItem] = []
    @State private var isLoading = false
    @State private var loadFailed = false
    @State private var showCreate = false
    @State private var newName = ""

    private let cols = [GridItem(.adaptive(minimum: 160, maximum: 240), spacing: DS.gridSpacing)]

    var body: some View {
        LibraryStack {
            ScrollView {
                if playlists.isEmpty && isLoading {
                    CenteredState(systemImage: nil, title: "Loading", loading: true)
                } else if playlists.isEmpty && loadFailed {
                    CenteredState(systemImage: "wifi.exclamationmark", title: "Couldn't load playlists") {
                        Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
                    }
                } else if playlists.isEmpty {
                    CenteredState(systemImage: "music.note.list", title: "No playlists yet")
                } else {
                    LazyVGrid(columns: cols, spacing: DS.gridSpacing + 4) {
                        ForEach(playlists) { p in
                            LibraryLink(route: .playlist(p)) { PlaylistCard(playlist: p) }
                        }
                    }
                    .padding(.horizontal, DS.gridPad)
                    .padding(.top, 4)
                }
            }
            .scrollIndicators(.hidden)
            .navigationTitle("Playlists")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { newName = ""; showCreate = true } label: { Image(systemName: "plus") }
                }
            }
            .alert("New Playlist", isPresented: $showCreate) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }
            }
            .task { if playlists.isEmpty { await load() } }
        }
    }

    private func load() async {
        isLoading = true
        loadFailed = false
        do { playlists = try await client.fetchPlaylists() }
        catch { loadFailed = true }
        isLoading = false
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            _ = try? await client.createPlaylist(name: name)
            await load()
        }
    }
}

struct PlaylistCard: View {
    let playlist: MediaItem
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryImage(url: client.artworkURL(for: playlist, size: 400), maxPixel: 400) {
                Color(.systemGray6)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.title2)
                            .foregroundStyle(Color(.systemGray4))
                    }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
            .shadow(color: .black.opacity(DS.shadowOpacity), radius: DS.shadowRadius, y: DS.shadowY)

            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.footnote).fontWeight(.semibold).lineLimit(1)
                if let count = playlist.childCount {
                    Text("\(count) song\(count == 1 ? "" : "s")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

// MARK: - Playlist detail (play / reorder / remove)

struct PlaylistDetailView: View {
    let playlist: MediaItem
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var tracks: [MediaItem] = []
    @State private var isLoading = true
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
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 40)
            } else if tracks.isEmpty {
                Text("This playlist is empty")
                    .font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .padding(.vertical, 40)
            } else {
                ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                    SongRow(song: track, showAlbumArt: true,
                            onTap: { player.play(items: tracks, from: index) },
                            onPlayNext: { player.playNext(track) },
                            onPlayLast: { player.playLast(track) },
                            onRemove: { remove(track) })
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowBackground(Color.clear)
                        .trackSwipeActions(onPlayNext: { player.playNext(track) },
                                           onPlayLast: { player.playLast(track) },
                                           onRemove: { remove(track) })
                }
                .onMove(perform: move)
            }
        }
        .listStyle(.plain)
        .scrollIndicators(.hidden)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, $editMode)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                if !tracks.isEmpty {
                    Button(editMode.isEditing ? "Done" : "Edit") {
                        withAnimation { editMode = editMode.isEditing ? .inactive : .active }
                    }
                }
            }
        }
        .task {
            tracks = (try? await client.fetchPlaylistItems(playlistId: playlist.id)) ?? []
            isLoading = false
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            LibraryImage(url: client.artworkURL(for: playlist, size: 600), maxPixel: 600) {
                Color(.secondarySystemBackground)
                    .overlay {
                        Image(systemName: "music.note.list")
                            .font(.system(size: 56, weight: .ultraLight))
                            .foregroundStyle(.tertiary)
                    }
            }
            .frame(width: 240, height: 240)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .black.opacity(0.2), radius: 18, y: 10)
            .frame(maxWidth: .infinity)

            Text(playlist.name)
                .font(.title2).fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .padding(.horizontal, DS.hPad)
            Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.top, 4)

            playButton.padding(.vertical, 18)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
    }

    private var playButton: some View {
        Button {
            guard !tracks.isEmpty else { return }
            player.play(items: tracks, from: 0)
        } label: {
            Label("Play", systemImage: "play.fill")
                .font(.headline)
                .foregroundStyle(Color(.systemBackground))
                .padding(.horizontal, 44)
                .padding(.vertical, 14)
                .background(Color.primary, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(tracks.isEmpty)
    }

    private func remove(_ track: MediaItem) {
        guard let entryId = track.playlistItemId else { return }
        tracks.removeAll { $0.id == track.id }
        Task { try? await client.removeFromPlaylist(playlist.id, entryIds: [entryId]) }
    }

    private func move(from offsets: IndexSet, to destination: Int) {
        tracks.move(fromOffsets: offsets, toOffset: destination)
        guard let src = offsets.first else { return }
        // New index of the moved entry after the local move.
        let newIndex = destination > src ? destination - 1 : destination
        guard tracks.indices.contains(newIndex), let entryId = tracks[newIndex].playlistItemId else { return }
        Task { try? await client.movePlaylistItem(playlist.id, entryId: entryId, to: newIndex) }
    }
}

// MARK: - 3D-touch / long-press menu for containers (album / playlist)

/// Items to add to a playlist — one track, or all tracks of an album/playlist.
struct PlaylistAddRequest: Identifiable {
    let id = UUID()
    let itemIds: [String]
}

/// Long-press (3D-touch) menu for an album or playlist card: Play Next / Play Last / Add to Playlist,
/// operating on the container's tracks (fetched on demand).
struct LibraryItemMenu: ViewModifier {
    let item: MediaItem
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    @State private var addRequest: PlaylistAddRequest?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button { queue(next: true) } label: {
                    Label("Play Next", systemImage: "text.line.first.and.arrowtriangle.forward")
                }
                Button { queue(next: false) } label: {
                    Label("Play Last", systemImage: "text.line.last.and.arrowtriangle.forward")
                }
                Button { Task { addRequest = PlaylistAddRequest(itemIds: await trackIds()) } } label: {
                    Label("Add to Playlist", systemImage: "text.badge.plus")
                }
            }
            .sheet(item: $addRequest) { PlaylistPickerSheet(request: $0) }
    }

    private func tracks() async -> [MediaItem] {
        if item.type == "Playlist" { return (try? await client.fetchPlaylistItems(playlistId: item.id)) ?? [] }
        return (try? await client.fetchTracks(parentId: item.id)) ?? []
    }
    private func trackIds() async -> [String] { await tracks().map(\.id) }
    private func queue(next: Bool) {
        Task { let t = await tracks(); next ? player.playNext(t) : player.playLast(t) }
    }
}

extension View {
    func libraryItemMenu(_ item: MediaItem) -> some View { modifier(LibraryItemMenu(item: item)) }
}

// MARK: - Add-to-playlist picker

struct PlaylistPickerSheet: View {
    let request: PlaylistAddRequest
    @Environment(JellyfinClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var playlists: [MediaItem] = []
    @State private var isLoading = true
    @State private var showCreate = false
    @State private var newName = ""

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        newName = ""; showCreate = true
                    } label: {
                        Label("New Playlist", systemImage: "plus")
                    }
                }
                Section {
                    if isLoading {
                        HStack { Spacer(); ProgressView(); Spacer() }
                    } else {
                        ForEach(playlists) { p in
                            Button { add(to: p) } label: {
                                HStack(spacing: 12) {
                                    LibraryImage(url: client.artworkURL(for: p, size: 120), maxPixel: 160) {
                                        Color(.systemGray6)
                                            .overlay { Image(systemName: "music.note.list").foregroundStyle(Color(.systemGray4)) }
                                    }
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(p.name).foregroundStyle(.primary).lineLimit(1)
                                        if let c = p.childCount {
                                            Text("\(c) song\(c == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Add to Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { dismiss() } } }
            .alert("New Playlist", isPresented: $showCreate) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { createAndAdd() }
            }
            .task { playlists = (try? await client.fetchPlaylists()) ?? []; isLoading = false }
        }
    }

    private func add(to playlist: MediaItem) {
        Task {
            try? await client.addToPlaylist(playlist.id, itemIds: request.itemIds)
            dismiss()
        }
    }

    private func createAndAdd() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            _ = try? await client.createPlaylist(name: name, itemIds: request.itemIds)
            dismiss()
        }
    }
}
