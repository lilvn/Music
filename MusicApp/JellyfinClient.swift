import Foundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

/// Jellyfin REST data layer. Async `URLSession` throughout — no Combine.
/// Credentials are entered at sign-in and persisted per device — nothing is baked into the app.
@MainActor
@Observable
final class JellyfinClient {
    /// Shared instance so App Intents (Siri / Shortcuts) can reach the API outside the view tree.
    static let shared = JellyfinClient()

    // Credentials are entered at first launch and persisted — nothing is baked into the app.
    private(set) var serverURL: String
    private(set) var accessToken: String
    private(set) var userId: String
    private(set) var username: String

    /// Ids of the user's favourite (liked) songs — drives the Now Playing heart + Liked Songs.
    var favoriteIds: Set<String> = []

    /// Ids in the order they were liked, most-recent FIRST. Tracked locally per user because Jellyfin
    /// has no "date favourited" sort (its DateCreated is the library-add date, not the like time) —
    /// this is what puts a newly-liked song at the TOP of Liked Songs.
    private(set) var likedOrder: [String] = []

    // Caches for IMMUTABLE content, so re-opening an album or the lyrics sheet is instant (no refetch).
    // MainActor-isolated (the whole client is), so plain dictionaries are safe here.
    @ObservationIgnored private var albumTrackCache: [String: [MediaItem]] = [:]
    @ObservationIgnored private var lyricsCache: [String: [LyricLine]] = [:]

    var isAuthenticated: Bool { !serverURL.isEmpty && !accessToken.isEmpty && !userId.isEmpty }

    private enum Keys {
        static let server = "jf.server", token = "jf.token", userId = "jf.userId", username = "jf.username"
    }

    init() {
        let d = UserDefaults.standard
        serverURL   = d.string(forKey: Keys.server) ?? ""
        accessToken = d.string(forKey: Keys.token) ?? ""
        userId      = d.string(forKey: Keys.userId) ?? ""
        username    = d.string(forKey: Keys.username) ?? ""
        likedOrder  = d.stringArray(forKey: Self.likedOrderKey(userId)) ?? []
    }

    private var baseURL: URL? { URL(string: serverURL) }

    /// Stable per-install device id. REQUIRED for cross-device control: with the old hardcoded id every
    /// device reported as the SAME session, so the server couldn't tell an iPhone from an Apple TV.
    static let deviceId: String = {
        let key = "jf.deviceId"
        if let id = UserDefaults.standard.string(forKey: key) { return id }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: key)
        return id
    }()

    /// Human-readable device name shown in other devices' "playing on …" UI.
    static var deviceName: String {
#if os(tvOS)
        "Apple TV"
#elseif os(macOS)
        "Mac"
#else
        UIDevice.current.model   // "iPhone" / "iPad"
#endif
    }

    private var deviceAuthHeader: String {
        "MediaBrowser Client=\"Music2.0\", Device=\"\(Self.deviceName)\", DeviceId=\"\(Self.deviceId)\", Version=\"1.0\""
    }
    private var authHeader: String { "\(deviceAuthHeader), Token=\"\(accessToken)\"" }

    // MARK: - Authentication

    /// Authenticate against a Jellyfin server with a username + password and persist the session.
    func authenticate(server: String, username: String, password: String) async throws {
        var s = server.trimmingCharacters(in: .whitespaces)
        if !s.lowercased().hasPrefix("http") { s = "https://" + s }   // default to https
        while s.hasSuffix("/") { s.removeLast() }
        guard let base = URL(string: s) else { throw APIError.invalidURL }

        var req = URLRequest(url: base.appendingPathComponent("Users/AuthenticateByName"))
        req.httpMethod = "POST"
        req.setValue(deviceAuthHeader, forHTTPHeaderField: "Authorization")   // no token yet
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["Username": username, "Pw": password])

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)

        serverURL = s
        accessToken = auth.accessToken
        userId = auth.user.id
        self.username = auth.user.name
        likedOrder = UserDefaults.standard.stringArray(forKey: Self.likedOrderKey(userId)) ?? []

        let d = UserDefaults.standard
        d.set(serverURL, forKey: Keys.server)
        d.set(accessToken, forKey: Keys.token)
        d.set(userId, forKey: Keys.userId)
        d.set(self.username, forKey: Keys.username)
    }

    func signOut() {
        serverURL = ""; accessToken = ""; userId = ""; username = ""; favoriteIds = []; likedOrder = []
        let d = UserDefaults.standard
        [Keys.server, Keys.token, Keys.userId, Keys.username].forEach { d.removeObject(forKey: $0) }
    }

    // MARK: - Library

    func fetchRecentlyAdded(limit: Int = 16) async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("IncludeItemTypes", "MusicAlbum"),
            q("SortBy", "DateCreated"),
            q("SortOrder", "Descending"),
            q("Limit", "\(limit)"),
            q("Recursive", "true"),
            q("Fields", "PrimaryImageAspectRatio,ProductionYear,ChildCount,Overview"),
            q("ImageTypeLimit", "1"),
            q("EnableImageTypes", "Primary"),
        ])
    }

    /// A rotating set of albums for the Featured cover-flow shelf.
    func fetchFeatured(limit: Int = 8) async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("IncludeItemTypes", "MusicAlbum"),
            q("SortBy", "Random"),
            q("Limit", "\(limit)"),
            q("Recursive", "true"),
            q("Fields", "PrimaryImageAspectRatio,ProductionYear,ChildCount,Overview,AlbumArtist"),
            q("ImageTypeLimit", "1"),
            q("EnableImageTypes", "Primary"),
        ])
    }

    func fetchAlbums(artistId: String? = nil, genreId: String? = nil, limit: Int = 300) async throws -> [MediaItem] {
        var items: [URLQueryItem] = [
            q("IncludeItemTypes", "MusicAlbum"),
            q("Recursive", "true"),
            q("SortBy", "SortName"),
            q("SortOrder", "Ascending"),
            q("Limit", "\(limit)"),
            q("Fields", "PrimaryImageAspectRatio,SortName,ProductionYear,ChildCount"),
            q("ImageTypeLimit", "1"),
            q("EnableImageTypes", "Primary"),
        ]
        if let id = artistId { items.append(q("AlbumArtistIds", id)) }
        if let gid = genreId { items.append(q("GenreIds", gid)) }
        return try await fetchItems(path: "Users/\(userId)/Items", query: items)
    }

    /// All songs by an album-artist, in album / track order — powers the artist page Play / Shuffle.
    func fetchArtistSongs(artistId: String) async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("AlbumArtistIds", artistId),
            q("IncludeItemTypes", "Audio"),
            q("Recursive", "true"),
            q("SortBy", "Album,ParentIndexNumber,IndexNumber,SortName"),
            q("Fields", "RunTimeTicks,AlbumArtist,Album,AlbumId"),
        ])
    }

    /// Music genres in the library (for the Albums genre filter).
    func fetchMusicGenres() async throws -> [MediaItem] {
        try await fetchItems(path: "MusicGenres", query: [
            q("UserId", userId),
            q("SortBy", "SortName"),
            q("Limit", "100"),
        ])
    }

    func fetchArtists(limit: Int = 200) async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("IncludeItemTypes", "MusicArtist"),
            q("Recursive", "true"),
            q("SortBy", "SortName"),
            q("SortOrder", "Ascending"),
            q("Limit", "\(limit)"),
            q("Fields", "PrimaryImageAspectRatio,ChildCount"),
            q("ImageTypeLimit", "1"),
        ])
    }

    /// Tracks of an album (sorted by disc/track) or any container.
    /// Album tracklist, cached — albums are immutable, so it never goes stale.
    func fetchAlbumTracks(albumId: String) async throws -> [MediaItem] {
        if let cached = albumTrackCache[albumId] { return cached }
        let tracks = try await fetchTracks(parentId: albumId)
        albumTrackCache[albumId] = tracks
        return tracks
    }

    func fetchTracks(parentId: String) async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("ParentId", parentId),
            q("IncludeItemTypes", "Audio"),
            q("SortBy", "ParentIndexNumber,IndexNumber,SortName"),
            q("Fields", "RunTimeTicks,SortName,AlbumArtist"),
        ])
    }

    func fetchPlaylists() async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("IncludeItemTypes", "Playlist"),
            q("Recursive", "true"),
            q("SortBy", "SortName"),
            q("Limit", "200"),
            q("Fields", "ChildCount,Overview"),
            q("ImageTypeLimit", "1"),
            q("EnableImageTypes", "Primary"),
        ])
    }

    /// Items of a playlist, preserving the playlist's own order.
    func fetchPlaylistItems(playlistId: String) async throws -> [MediaItem] {
        try await fetchItems(path: "Playlists/\(playlistId)/Items", query: [
            q("UserId", userId),
            q("Fields", "RunTimeTicks,SortName,AlbumArtist,Album,AlbumId"),
        ])
    }

    func fetchAllSongs(limit: Int = 500) async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("IncludeItemTypes", "Audio"),
            q("Recursive", "true"),
            q("SortBy", "SortName"),
            q("SortOrder", "Ascending"),
            q("Limit", "\(limit)"),
            q("Fields", "RunTimeTicks,AlbumArtist,Album,AlbumId"),
        ])
    }

    /// Recently played songs (most recent first).
    func fetchRecentlyPlayed(limit: Int = 16) async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("IncludeItemTypes", "Audio"),
            q("SortBy", "DatePlayed"),
            q("SortOrder", "Descending"),
            q("Filters", "IsPlayed"),
            q("Limit", "\(limit)"),
            q("Recursive", "true"),
            q("Fields", "PrimaryImageAspectRatio,AlbumArtist,Album,AlbumId,RunTimeTicks"),
            q("ImageTypeLimit", "1"),
            q("EnableImageTypes", "Primary"),
        ])
    }

    /// Recently added songs (newest first) — used to suggest tracks when adding music to a playlist.
    func fetchRecentlyAddedSongs(limit: Int = 30) async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("IncludeItemTypes", "Audio"),
            q("SortBy", "DateCreated"),
            q("SortOrder", "Descending"),
            q("Limit", "\(limit)"),
            q("Recursive", "true"),
            q("Fields", "PrimaryImageAspectRatio,AlbumArtist,Album,AlbumId,RunTimeTicks"),
            q("ImageTypeLimit", "1"),
            q("EnableImageTypes", "Primary"),
        ])
    }

    /// The user's most-played songs, most-played first (by server play count).
    func fetchMostPlayed(limit: Int = 16) async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("IncludeItemTypes", "Audio"),
            q("SortBy", "PlayCount"),
            q("SortOrder", "Descending"),
            q("Filters", "IsPlayed"),
            q("Limit", "\(limit)"),
            q("Recursive", "true"),
            q("Fields", "PrimaryImageAspectRatio,AlbumArtist,Album,AlbumId,RunTimeTicks"),
            q("ImageTypeLimit", "1"),
            q("EnableImageTypes", "Primary"),
        ])
    }

    /// Server-generated "instant mix" of songs similar to `itemId` — powers Autoplay when the queue
    /// runs out (most-relevant first).
    func fetchInstantMix(itemId: String, limit: Int = 20) async throws -> [MediaItem] {
        try await fetchItems(path: "Items/\(itemId)/InstantMix", query: [
            q("UserId", userId),
            q("Limit", "\(limit)"),
            q("Fields", "RunTimeTicks,AlbumArtist,Album,AlbumId"),
            q("ImageTypeLimit", "1"),
            q("EnableImageTypes", "Primary"),
        ])
    }

    /// Fetch a single item (album / artist / etc.) by id — used to open a detail from Now Playing.
    func fetchItem(id: String) async throws -> MediaItem {
        guard let req = request("Users/\(userId)/Items/\(id)", query: [
            q("Fields", "PrimaryImageAspectRatio,ProductionYear,ChildCount,AlbumArtist,Overview"),
        ]) else { throw APIError.invalidURL }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw APIError.httpError(http.statusCode)
        }
        return try JSONDecoder().decode(MediaItem.self, from: data)
    }

    func search(query: String) async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("SearchTerm", query),
            q("IncludeItemTypes", "Audio,MusicAlbum,MusicArtist,Playlist"),
            q("Recursive", "true"),
            q("Limit", "60"),
            q("Fields", "PrimaryImageAspectRatio,SortName,AlbumArtist,Album,RunTimeTicks,AlbumId"),
            q("ImageTypeLimit", "1"),
        ])
    }

    func fetchLyrics(itemId: String) async throws -> [LyricLine] {
        if let cached = lyricsCache[itemId] { return cached }
        guard let req = request("Audio/\(itemId)/Lyrics") else { throw APIError.invalidURL }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let lines = try JSONDecoder().decode(LyricResponse.self, from: data).lyrics
        lyricsCache[itemId] = lines
        return lines
    }

    // MARK: - Playlist editing

    @discardableResult
    func createPlaylist(name: String, itemIds: [String] = []) async throws -> String {
        guard let base = baseURL else { throw APIError.invalidURL }
        var req = URLRequest(url: base.appendingPathComponent("Playlists"))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "Name": name, "Ids": itemIds, "UserId": userId, "MediaType": "Audio",
        ])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp)
        return (try? JSONDecoder().decode(CreatePlaylistResult.self, from: data).id) ?? ""
    }

    func addToPlaylist(_ playlistId: String, itemIds: [String]) async throws {
        try await sendMutation("Playlists/\(playlistId)/Items", method: "POST",
                               query: [q("ids", itemIds.joined(separator: ",")), q("userId", userId)])
    }

    func removeFromPlaylist(_ playlistId: String, entryIds: [String]) async throws {
        try await sendMutation("Playlists/\(playlistId)/Items", method: "DELETE",
                               query: [q("entryIds", entryIds.joined(separator: ","))])
    }

    func deletePlaylist(_ id: String) async throws {
        try await sendMutation("Items/\(id)", method: "DELETE", query: [])
    }

    // MARK: - Favourites (liked songs)

    /// Favourite songs, newest first (DateCreated descending) — the Liked Songs list.
    func fetchFavoriteSongs() async throws -> [MediaItem] {
        try await fetchItems(path: "Items", query: [
            q("userId", userId),
            q("Filters", "IsFavorite"),
            q("IncludeItemTypes", "Audio"),
            q("Recursive", "true"),
            q("SortBy", "DateCreated"),
            q("SortOrder", "Descending"),
            q("Fields", "PrimaryImageAspectRatio,AlbumArtist,Album,AlbumId,RunTimeTicks"),
            q("ImageTypeLimit", "1"),
            q("EnableImageTypes", "Primary"),
        ])
    }

    /// Refresh the cached set of favourite ids (so the heart reflects the current state).
    func refreshFavorites() async {
        guard isAuthenticated else { return }
        let songs = (try? await fetchFavoriteSongs()) ?? []
        favoriteIds = Set(songs.map(\.id))
        reconcileLikedOrder(with: songs.map(\.id))   // keep the local like-order in sync on every refresh
    }

    func isFavorite(_ itemId: String) -> Bool { favoriteIds.contains(itemId) }

    /// Toggle an item's favourite state (optimistic local update + server mutation). Liking moves the
    /// id to the FRONT of `likedOrder` so it shows at the top of Liked Songs; unliking drops it.
    func setFavorite(_ itemId: String, _ favorite: Bool) async {
        if favorite {
            favoriteIds.insert(itemId)
            likedOrder.removeAll { $0 == itemId }
            likedOrder.insert(itemId, at: 0)
        } else {
            favoriteIds.remove(itemId)
            likedOrder.removeAll { $0 == itemId }
        }
        saveLikedOrder()
        try? await sendMutation("Users/\(userId)/FavoriteItems/\(itemId)",
                                method: favorite ? "POST" : "DELETE", query: [])
    }

    /// Position of each liked id (0 = most-recently liked) — used to sort Liked Songs.
    var likeRank: [String: Int] {
        var d = [String: Int](minimumCapacity: likedOrder.count)
        for (i, id) in likedOrder.enumerated() { d[id] = i }
        return d
    }

    /// Reconcile local like-order with the server's current favourites: drop ids no longer favourited,
    /// and append any favourited elsewhere (unknown like-time → they sort after locally-liked ones).
    func reconcileLikedOrder(with currentIds: [String]) {
        let set = Set(currentIds)
        likedOrder.removeAll { !set.contains($0) }
        let known = Set(likedOrder)
        likedOrder.append(contentsOf: currentIds.filter { !known.contains($0) })
        saveLikedOrder()
    }

    private func saveLikedOrder() { UserDefaults.standard.set(likedOrder, forKey: Self.likedOrderKey(userId)) }
    private static func likedOrderKey(_ uid: String) -> String { "jf.likedOrder.\(uid)" }

    /// Set an item's primary (cover) image — Jellyfin wants the bytes base64-encoded in the body.
    func uploadPrimaryImage(itemId: String, jpeg: Data) async throws {
        guard let base = baseURL else { throw APIError.invalidURL }
        var req = URLRequest(url: base.appendingPathComponent("Items/\(itemId)/Images/Primary"))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        req.httpBody = jpeg.base64EncodedData()
        let (_, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp)
    }

    /// Move a playlist entry (its `playlistItemId`) to a new position.
    func movePlaylistItem(_ playlistId: String, entryId: String, to newIndex: Int) async throws {
        try await sendMutation("Playlists/\(playlistId)/Items/\(entryId)/Move/\(newIndex)",
                               method: "POST", query: [])
    }

    // MARK: - Playback reporting (scrobble play state back to Jellyfin)

    func reportPlaybackStart(itemId: String, positionTicks: Int64, queueIds: [String] = []) async {
        await postPlayback("Sessions/Playing", itemId: itemId, positionTicks: positionTicks,
                           isPaused: false, queueIds: queueIds)
    }
    func reportPlaybackProgress(itemId: String, positionTicks: Int64, isPaused: Bool, queueIds: [String] = []) async {
        await postPlayback("Sessions/Playing/Progress", itemId: itemId, positionTicks: positionTicks,
                           isPaused: isPaused, queueIds: queueIds)
    }
    func reportPlaybackStopped(itemId: String, positionTicks: Int64) async {
        await postPlayback("Sessions/Playing/Stopped", itemId: itemId, positionTicks: positionTicks, isPaused: false)
    }

    private func postPlayback(_ path: String, itemId: String, positionTicks: Int64,
                              isPaused: Bool, queueIds: [String] = []) async {
        guard let base = baseURL else { return }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": positionTicks,
            "IsPaused": isPaused,
            "PlayMethod": "DirectStream",
            "CanSeek": true,
        ]
        // Report the queue so other devices can mirror it and "transfer here" mid-album.
        if !queueIds.isEmpty { body["NowPlayingQueue"] = queueIds.map { ["Id": $0] } }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }

    // MARK: - Sessions (cross-device shared Now Playing)

    /// All active sessions visible to this user (other devices, other Jellyfin clients).
    func fetchSessions() async throws -> [SessionInfo] {
        guard let base = baseURL else { throw APIError.invalidURL }
        var comps = URLComponents(url: base.appendingPathComponent("Sessions"), resolvingAgainstBaseURL: false)
        comps?.queryItems = [q("activeWithinSeconds", "360")]
        guard let url = comps?.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp)
        return try JSONDecoder().decode([SessionInfo].self, from: data)
    }

    /// Send a transport command (PlayPause / NextTrack / PreviousTrack / Stop / Seek) to another session.
    func sendPlaystate(sessionId: String, command: String, seekTicks: Int64? = nil) async {
        var query: [URLQueryItem] = []
        if let seekTicks { query.append(q("seekPositionTicks", String(seekTicks))) }
        try? await sendMutation("Sessions/\(sessionId)/Playing/\(command)", method: "POST", query: query)
    }

    /// Cast items AT another session: PlayNow replaces its queue (optionally at an index/position),
    /// PlayNext/PlayLast enqueue without touching what's playing. Params are QUERY items per the
    /// Jellyfin OpenAPI (`itemIds` comma-joined is required).
    func sendPlay(sessionId: String, itemIds: [String], playCommand: String = "PlayNow",
                  startIndex: Int? = nil, startTicks: Int64? = nil) async {
        guard !itemIds.isEmpty else { return }
        var query: [URLQueryItem] = [
            q("playCommand", playCommand),
            q("itemIds", itemIds.joined(separator: ",")),
        ]
        if let startIndex { query.append(q("startIndex", String(startIndex))) }
        if let startTicks { query.append(q("startPositionTicks", String(startTicks))) }
        try? await sendMutation("Sessions/\(sessionId)/Playing", method: "POST", query: query)
    }

    /// Declare this session remote-controllable (required for other devices to send it commands).
    func postCapabilities() async {
        guard let base = baseURL else { return }
        var req = URLRequest(url: base.appendingPathComponent("Sessions/Capabilities/Full"))
        req.httpMethod = "POST"
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "PlayableMediaTypes": ["Audio"],
            "SupportedCommands": ["PlayState", "Play"],
            "SupportsMediaControl": true,
            "SupportsPersistentIdentifier": false,
        ])
        _ = try? await URLSession.shared.data(for: req)
    }

    /// Fetch specific items by id (used to materialise a remote session's queue). Order is NOT
    /// guaranteed by the server — callers reorder against their id list.
    func fetchItems(ids: [String]) async throws -> [MediaItem] {
        guard !ids.isEmpty else { return [] }
        return try await fetchItems(path: "Items", query: [
            q("userId", userId),
            q("Ids", ids.joined(separator: ",")),
            q("Fields", "PrimaryImageAspectRatio,AlbumArtist,Album,AlbumId,RunTimeTicks"),
            q("ImageTypeLimit", "1"),
            q("EnableImageTypes", "Primary"),
        ])
    }

    // MARK: - Music videos

    /// All music videos in the library (small collections — fetched once and matched client-side
    /// against the playing song's artist/title).
    func fetchMusicVideos() async throws -> [MediaItem] {
        try await fetchItems(path: "Items", query: [
            q("userId", userId),
            q("IncludeItemTypes", "MusicVideo"),
            q("Recursive", "true"),
            q("Fields", "PrimaryImageAspectRatio,Artists,RunTimeTicks"),
            q("ImageTypeLimit", "1"),
            q("EnableImageTypes", "Primary"),
        ])
    }

    /// Direct-play stream URL for a VIDEO item (music videos) — the video counterpart of `streamURL`.
    func videoStreamURL(for item: MediaItem) -> URL? {
        guard let base = baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("Videos/\(item.id)/stream"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [q("static", "true"), q("api_key", accessToken)]
        return comps?.url
    }

    /// The server's WebSocket endpoint — where remote-control commands arrive.
    var webSocketURL: URL? {
        guard let base = baseURL,
              var comps = URLComponents(url: base.appendingPathComponent("socket"),
                                        resolvingAgainstBaseURL: false) else { return nil }
        comps.scheme = (comps.scheme == "https") ? "wss" : "ws"
        comps.queryItems = [q("api_key", accessToken), q("deviceId", Self.deviceId)]
        return comps.url
    }

    // MARK: - URLs

    func artworkURL(for item: MediaItem, size: Int = 400) -> URL? {
        guard let base = baseURL else { return nil }
        let itemId: String
        if item.type == "Audio", item.imageTags?["Primary"] == nil, let aid = item.albumId {
            itemId = aid
        } else {
            itemId = item.id
        }
        guard item.imageTags?["Primary"] != nil || item.type == "Audio" else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/Images/Primary"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            q("maxHeight", "\(size)"), q("maxWidth", "\(size)"),
            q("quality", "90"), q("api_key", accessToken),
        ]
        return comps?.url
    }

    /// Primary-image URL built directly from an item id, IGNORING the cached image tag — so it resolves
    /// even when the fetched item has no tag yet (e.g. a playlist whose cover was just uploaded).
    /// `cacheBust` forces a fresh fetch past the URL/decoded caches after an upload.
    func primaryImageURL(itemId: String, size: Int = 600, cacheBust: Int = 0) -> URL? {
        guard let base = baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/Images/Primary"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            q("maxHeight", "\(size)"), q("maxWidth", "\(size)"),
            q("quality", "90"), q("api_key", accessToken),
        ]
        if cacheBust > 0 { comps?.queryItems?.append(q("cb", "\(cacheBust)")) }
        return comps?.url
    }

    func streamURL(for item: MediaItem) -> URL? {
        guard let base = baseURL else { return nil }
        var comps = URLComponents(url: base.appendingPathComponent("Audio/\(item.id)/stream"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [q("static", "true"), q("api_key", accessToken)]
        return comps?.url
    }

    // MARK: - Private

    private func fetchItems(path: String, query: [URLQueryItem]) async throws -> [MediaItem] {
        guard let req = request(path, query: query) else { throw APIError.invalidURL }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw APIError.httpError(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(ItemsResponse.self, from: data).items
        } catch {
            throw APIError.decodingError(error)
        }
    }

    private func sendMutation(_ path: String, method: String, query: [URLQueryItem]) async throws {
        guard let base = baseURL,
              var comps = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw APIError.invalidURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        let (_, resp) = try await URLSession.shared.data(for: req)
        try ensureOK(resp)
    }

    private func ensureOK(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw APIError.httpError((resp as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    private func request(_ path: String, query: [URLQueryItem] = []) -> URLRequest? {
        guard let base = baseURL,
              var comps = URLComponents(url: base.appendingPathComponent(path),
                                        resolvingAgainstBaseURL: false)
        else { return nil }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue(authHeader, forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func q(_ name: String, _ value: String) -> URLQueryItem {
        URLQueryItem(name: name, value: value)
    }
}
