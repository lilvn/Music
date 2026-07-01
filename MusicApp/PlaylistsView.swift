import SwiftUI
import PhotosUI

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
                VStack(alignment: .leading, spacing: 0) {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Playlists")
                            .font(.largeTitle).fontWeight(.bold)
                        Spacer()
                        // Same GlassCircleButton as the playlist detail's "+", so the two are identical.
                        GlassCircleButton(action: { newName = ""; showCreate = true }) {
                            Image(systemName: "plus")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(.horizontal, DS.hPad)
                    .padding(.top, 8)
                    .padding(.bottom, 14)

                    if playlists.isEmpty && isLoading {
                        CenteredState(systemImage: nil, title: "Loading", loading: true)
                    } else if playlists.isEmpty && loadFailed {
                        CenteredState(systemImage: "wifi.exclamationmark", title: "Couldn't load playlists") {
                            Button("Try Again") { Task { await load() } }.buttonStyle(.bordered)
                        }
                    } else {
                        LazyVGrid(columns: cols, spacing: DS.gridSpacing + 4) {
                            // Pinned, non-deletable favourites tile — always first.
                            LibraryLink(route: .likedSongs) { LikedSongsCard() }
                            ForEach(playlists) { p in
                                LibraryLink(route: .playlist(p)) { PlaylistCard(playlist: p) }
                            }
                        }
                        .padding(.horizontal, DS.gridPad)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollEdgeEffectStyle(.soft, for: .top)
            // Pull down to re-sync with Jellyfin (main page only — not inside pushed details/sheets).
            .refreshable { await client.refreshFavorites(); await load(); AudioStore.shared.refreshPinnedLibrary() }
            // Title lives in the scroll content (Home-style), so no header pins while scrolling.
            .toolbar(.hidden, for: .navigationBar)
            .alert("New Playlist", isPresented: $showCreate) {
                TextField("Name", text: $newName)
                Button("Cancel", role: .cancel) {}
                Button("Create") { create() }
            }
            .task { if playlists.isEmpty { await load() } }
            // Drop a playlist from the grid the moment it's deleted from its long-press menu.
            .onReceive(NotificationCenter.default.publisher(for: .playlistDeleted)) { note in
                if let id = note.object as? String {
                    withAnimation { playlists.removeAll { $0.id == id } }
                }
            }
        }
    }

    private func load() async {
        isLoading = true
        loadFailed = false
        do { playlists = try await client.fetchPlaylists() }
        catch { loadFailed = true }
        isLoading = false
        // Warm the grid's covers so they're ready as you scroll, not loaded lazily on appear.
        ImageStore.shared.prefetch(playlists.map { client.artworkURL(for: $0, size: 400) }, maxPixel: 400)
    }

    private func create() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            if let id = try? await client.createPlaylist(name: name) {
                await uploadDefaultPlaylistCover(for: id, using: client)
            }
            await load()
        }
    }

}

/// Renders our coverless-playlist placeholder to a JPEG and sets it as the playlist's primary image on
/// Jellyfin, so a brand-new playlist shows our default art everywhere (app + server + other clients)
/// instead of Jellyfin's generic one.
@MainActor
func uploadDefaultPlaylistCover(for playlistId: String, using client: JellyfinClient) async {
    guard !playlistId.isEmpty else { return }
    let renderer = ImageRenderer(content: ArtworkPlaceholder().frame(width: 600, height: 600))
    renderer.scale = 1
    guard let data = renderer.uiImage?.jpegData(compressionQuality: 0.9) else { return }
    try? await client.uploadPrimaryImage(itemId: playlistId, jpeg: data)
}

extension Notification.Name {
    /// Posted (with the playlist id as `object`) when a playlist is deleted, so the grid can update.
    static let playlistDeleted = Notification.Name("playlistDeleted")
}

// MARK: - Square image cropper (move & scale before setting a playlist cover)

struct CropImage: Identifiable { let id = UUID(); let image: UIImage }

/// Pan + pinch to frame an image inside a square, then renders the framed square to a UIImage.
struct ImageCropper: View {
    let image: UIImage
    let onCrop: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var side: CGFloat = 320   // crop-square size (set from geometry; used by the toolbar)
    @State private var scale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var liveScale: CGFloat = 1
    @State private var liveOffset: CGSize = .zero

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                let s = max(120, min(geo.size.width, geo.size.height) - 32)
                ZStack {
                    Color.black
                    framed(s, scale: scale * liveScale,
                           offset: CGSize(width: offset.width + liveOffset.width,
                                          height: offset.height + liveOffset.height))
                        .overlay(Rectangle().stroke(.white.opacity(0.9), lineWidth: 2))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        MagnifyGesture()
                            .onChanged { liveScale = $0.magnification }
                            .onEnded { v in
                                scale = min(max(scale * v.magnification, 1), 6)
                                liveScale = 1
                                withAnimation(.spring(response: 0.3)) { clampOffset(s) }
                            },
                        DragGesture()
                            .onChanged { liveOffset = $0.translation }
                            .onEnded { v in
                                offset.width += v.translation.width
                                offset.height += v.translation.height
                                liveOffset = .zero
                                withAnimation(.spring(response: 0.3)) { clampOffset(s) }
                            }
                    )
                )
                .onAppear { side = s }
                .onChange(of: s) { side = $1 }
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Move and Scale")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Use") { exportAndDismiss(side) }.fontWeight(.semibold)
                }
            }
        }
    }

    private func framed(_ s: CGFloat, scale: CGFloat, offset: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFill()
            .frame(width: s, height: s)
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: s, height: s)
            .clipped()
    }

    private func clampOffset(_ s: CGFloat) {
        let aspect = image.size.width / max(1, image.size.height)
        let dispW = aspect >= 1 ? s * aspect : s
        let dispH = aspect >= 1 ? s : s / aspect
        let maxX = max(0, (dispW * scale - s) / 2)
        let maxY = max(0, (dispH * scale - s) / 2)
        offset.width = min(max(offset.width, -maxX), maxX)
        offset.height = min(max(offset.height, -maxY), maxY)
    }

    @MainActor private func exportAndDismiss(_ s: CGFloat) {
        let renderer = ImageRenderer(content: framed(s, scale: scale, offset: offset))
        renderer.scale = 1000 / s   // ~1000px square output
        if let ui = renderer.uiImage { onCrop(ui) }
        dismiss()
    }
}

struct PlaylistCard: View {
    let playlist: MediaItem
    @Environment(JellyfinClient.self) private var client

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LibraryImage(url: client.artworkURL(for: playlist, size: 400), maxPixel: 400) {
                ArtworkPlaceholder()
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerCard, style: .continuous))
            .artworkShadow()

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
    @State private var showAddMusic = false
    @State private var showCoverPicker = false
    @State private var pickedImage: PhotosPickerItem?
    @State private var cropImage: CropImage?
    @State private var coverVersion = 0
    @Namespace private var trackHighlightNS

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
                            onRemove: { remove(track) },
                            highlightNamespace: trackHighlightNS)
                        .listRowInsets(EdgeInsets(top: 0, leading: 0, bottom: 0, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .trackSwipeActions(onPlayNext: { player.playNext(track) },
                                           onPlayLast: { player.playLast(track) },
                                           onRemove: { remove(track) })
                }
            }
        }
        .listStyle(.plain)
        .listSectionSpacing(0)   // kill the default header→tracks gap; the header owns its own cushion
        .scrollContentBackground(.hidden)
        .background { ArtworkBackground(url: coverURL, animated: false) }
        .scrollIndicators(.hidden)
        // (highlight animation lives on the row itself — see SongRow — so it never reaches the nav bar)
        .navigationBarTitleDisplayMode(.inline)
        // Back button + the "+" (Add Music) both fade out together on close.
        .fadingDetailHeader {
            GlassCircleButton(action: { showAddMusic = true }) {
                Image(systemName: "plus")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
            }
        }
        .sheet(isPresented: $showAddMusic, onDismiss: { Task { await reload() } }) {
            AddMusicToPlaylistSheet(playlistId: playlist.id)
        }
        .sheet(item: $cropImage) { item in
            ImageCropper(image: item.image) { uploadCover($0) }
        }
        .onChange(of: pickedImage) { _, item in loadForCrop(item) }
        .task { await reload() }
    }

    private func reload() async {
        tracks = (try? await client.fetchPlaylistItems(playlistId: playlist.id)) ?? []
        isLoading = false
    }

    /// Cover URL built straight from the playlist id (so it resolves even when the fetched item has no
    /// image tag — e.g. right after the first upload), cache-busted so a new cover shows immediately.
    private var coverURL: URL? {
        client.primaryImageURL(itemId: playlist.id, size: 600, cacheBust: coverVersion)
    }

    private func loadForCrop(_ item: PhotosPickerItem?) {
        guard let item else { return }
        Task {
            guard let data = try? await item.loadTransferable(type: Data.self),
                  let ui = UIImage(data: data) else { return }
            cropImage = CropImage(image: ui)   // present the framing UI before uploading
            pickedImage = nil
        }
    }

    private func uploadCover(_ cropped: UIImage) {
        Task {
            guard let jpeg = cropped.jpegData(compressionQuality: 0.85) else { return }
            try? await client.uploadPrimaryImage(itemId: playlist.id, jpeg: jpeg)
            coverVersion += 1   // bust the cache so the new cover loads
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            // Centered square cover — no camera badge. 3D-touch (long-press) it for "Edit Cover".
            // `.contextMenuPreview` confines the lift/highlight to the rounded cover itself (the default
            // region was the whole square frame + the shadow bounds around it).
            LibraryImage(url: coverURL, maxPixel: 600) { ArtworkPlaceholder() }
                .frame(width: 240, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: DS.cornerArtwork, style: .continuous))
                .artworkShadow()
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: DS.cornerArtwork, style: .continuous))
                .contextMenu {
                    Button { showCoverPicker = true } label: {
                        Label("Edit Cover", systemImage: "photo")
                    }
                }
                .photosPicker(isPresented: $showCoverPicker, selection: $pickedImage, matching: .images)

            Text(playlist.name)
                .font(.title2).fontWeight(.bold)
                .multilineTextAlignment(.center)
                .padding(.top, 18)
                .padding(.horizontal, DS.hPad)
            Text("\(tracks.count) song\(tracks.count == 1 ? "" : "s")")
                .font(.footnote).foregroundStyle(.secondary)
                .padding(.top, 4)

            actions
                .padding(.horizontal, DS.hPad)
                .padding(.top, 18)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 12)
        .padding(.bottom, 14)   // deliberate, consistent gap down to the first track
    }

    /// Play / Shuffle / Play Next / Play Last — the 2×2 grid the artist view uses.
    private var actions: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                action("Play", "play.fill") { player.play(items: tracks, from: 0) }
                action("Shuffle", "shuffle") { player.play(items: tracks, from: 0, shuffled: true) }
            }
            HStack(spacing: 12) {
                action("Play Last", "text.line.last.and.arrowtriangle.forward") { player.playLast(tracks) }
                action("Play Next", "text.line.first.and.arrowtriangle.forward") { player.playNext(tracks) }
            }
        }
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity).frame(height: 46)
                .glassEffect(.regular.interactive(), in: .capsule)
        }
        .buttonStyle(ScaleButtonStyle())
        .disabled(tracks.isEmpty)
    }

    private func remove(_ track: MediaItem) {
        guard let entryId = track.playlistItemId else { return }
        tracks.removeAll { $0.id == track.id }
        Task { try? await client.removeFromPlaylist(playlist.id, entryIds: [entryId]) }
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
                if item.type == "Playlist" {
                    Divider()
                    Button(role: .destructive) {
                        Task {
                            try? await client.deletePlaylist(item.id)
                            NotificationCenter.default.post(name: .playlistDeleted, object: item.id)
                        }
                    } label: { Label("Delete Playlist", systemImage: "trash") }
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
                                        ArtworkPlaceholder()
                                    }
                                    .frame(width: 44, height: 44)
                                    .clipShape(RoundedRectangle(cornerRadius: DS.cornerThumb, style: .continuous))
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
            if let id = try? await client.createPlaylist(name: name, itemIds: request.itemIds) {
                await uploadDefaultPlaylistCover(for: id, using: client)
            }
            dismiss()
        }
    }
}

// MARK: - Add music to a playlist (search → tap to add)

struct AddMusicToPlaylistSheet: View {
    let playlistId: String
    @Environment(JellyfinClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MediaItem] = []
    @State private var resultCache: [String: [MediaItem]] = [:]
    @State private var recentlyAdded: [MediaItem] = []
    @State private var recommended: [MediaItem] = []
    @State private var isSearching = false
    @State private var added: Set<String> = []

    private var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    private var songs: [MediaItem] { results.filter { $0.type == "Audio" } }

    var body: some View {
        NavigationStack {
            List {
                if trimmed.isEmpty {
                    // Nothing typed → suggest tracks to add.
                    if !recentlyAdded.isEmpty {
                        Section("Recently Added") { ForEach(recentlyAdded) { addRow($0) } }
                    }
                    if !recommended.isEmpty {
                        Section("Recommended") { ForEach(recommended) { addRow($0) } }
                    }
                } else {
                    ForEach(songs) { addRow($0) }
                }
            }
            .listStyle(.plain)
            .overlay {
                if trimmed.isEmpty && recentlyAdded.isEmpty && recommended.isEmpty {
                    ProgressView()
                } else if !trimmed.isEmpty && songs.isEmpty && !isSearching {
                    ContentUnavailableView("No songs", systemImage: "magnifyingglass",
                                           description: Text("No songs matching “\(query)”."))
                }
            }
            .searchable(text: $query, prompt: "Songs")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .navigationTitle("Add Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task { await loadSuggestions() }
            .task(id: query) {
                let anim = Animation.easeInOut(duration: 0.22)
                guard !trimmed.isEmpty else { withAnimation(anim) { results = []; isSearching = false }; return }
                if let cached = resultCache[trimmed] {
                    withAnimation(anim) { results = cached; isSearching = false }; return
                }
                isSearching = true
                try? await Task.sleep(for: .milliseconds(280))
                guard !Task.isCancelled else { return }
                let found = (try? await client.search(query: trimmed)) ?? []
                guard !Task.isCancelled else { return }
                resultCache[trimmed] = found
                withAnimation(anim) { results = found; isSearching = false }
            }
        }
    }

    private func loadSuggestions() async {
        guard recentlyAdded.isEmpty, recommended.isEmpty else { return }
        async let recent = client.fetchRecentlyAddedSongs(limit: 30)
        async let recs = client.fetchMostPlayed(limit: 30)
        recentlyAdded = (try? await recent) ?? []
        recommended = (try? await recs) ?? []
    }

    @ViewBuilder
    private func addRow(_ song: MediaItem) -> some View {
        Button { add(song) } label: {
            HStack(spacing: 12) {
                LibraryImage(url: client.artworkURL(for: song, size: 160), maxPixel: 160) {
                    ArtworkPlaceholder()
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: DS.cornerThumb, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.name).foregroundStyle(.primary).lineLimit(1)
                    Text(song.primaryArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Image(systemName: added.contains(song.id) ? "checkmark.circle.fill" : "plus.circle")
                    .font(.title3)
                    .foregroundStyle(added.contains(song.id) ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .contentTransition(.symbolEffect(.replace))
            }
        }
        .buttonStyle(.plain)
    }

    private func add(_ song: MediaItem) {
        guard !added.contains(song.id) else { return }
        withAnimation { _ = added.insert(song.id) }
        Task { try? await client.addToPlaylist(playlistId, itemIds: [song.id]) }
    }
}
