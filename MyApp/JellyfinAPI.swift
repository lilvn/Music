import Foundation
import SwiftUI
import Combine

@MainActor
class JellyfinAPI: ObservableObject {
    // Personal single-user app — credentials are baked in, no login flow.
    let serverURL    = "https://music.485-0.com"
    let accessToken  = "7bf28a1d98424dd0bfab971128840bba"
    let userId       = "55044ca5301b4cc5b69bf1eb6974d684"
    let username     = "485"

    private var baseURL: URL? { URL(string: serverURL) }

    private var authHeader: String {
        "MediaBrowser Client=\"Music\", Device=\"Apple\", DeviceId=\"music-app-001\", Version=\"1.0\", Token=\"\(accessToken)\""
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

    /// A rotating set of albums for the Featured shelf.
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

    func fetchAlbums(artistId: String? = nil, limit: Int = 300) async throws -> [MediaItem] {
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
        return try await fetchItems(path: "Users/\(userId)/Items", query: items)
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

    /// Move a playlist entry (its `playlistItemId`) to a new position.
    func movePlaylistItem(_ playlistId: String, entryId: String, to newIndex: Int) async throws {
        try await sendMutation("Playlists/\(playlistId)/Items/\(entryId)/Move/\(newIndex)",
                               method: "POST", query: [])
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

    func fetchLyrics(itemId: String) async throws -> [LyricLine] {
        guard let req = request("Audio/\(itemId)/Lyrics") else { throw APIError.invalidURL }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw APIError.httpError((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        return try JSONDecoder().decode(LyricResponse.self, from: data).lyrics
    }

    func search(query: String) async throws -> [MediaItem] {
        try await fetchItems(path: "Users/\(userId)/Items", query: [
            q("SearchTerm", query),
            q("IncludeItemTypes", "Audio,MusicAlbum,MusicArtist"),
            q("Recursive", "true"),
            q("Limit", "60"),
            q("Fields", "PrimaryImageAspectRatio,SortName,AlbumArtist,Album,RunTimeTicks,AlbumId"),
            q("ImageTypeLimit", "1"),
        ])
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
