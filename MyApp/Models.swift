import Foundation
import SwiftUI

// MARK: - API Response Models

struct MediaItem: Identifiable, Codable, Hashable {
    let id: String
    let name: String
    let type: String
    let sortName: String?
    let albumArtist: String?
    let albumArtists: [NameId]?
    let album: String?
    let albumId: String?
    let artistItems: [NameId]?
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let runTimeTicks: Int64?
    let productionYear: Int?
    let imageTags: [String: String]?
    let albumPrimaryImageTag: String?
    let childCount: Int?
    let overview: String?
    let playlistItemId: String?   // entry id when this item is inside a playlist

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type"
        case sortName = "SortName"
        case albumArtist = "AlbumArtist"
        case albumArtists = "AlbumArtists"
        case album = "Album", albumId = "AlbumId"
        case artistItems = "ArtistItems"
        case indexNumber = "IndexNumber"
        case parentIndexNumber = "ParentIndexNumber"
        case runTimeTicks = "RunTimeTicks"
        case productionYear = "ProductionYear"
        case imageTags = "ImageTags"
        case albumPrimaryImageTag = "AlbumPrimaryImageTag"
        case childCount = "ChildCount"
        case overview = "Overview"
        case playlistItemId = "PlaylistItemId"
    }

    var durationSeconds: Double? {
        guard let ticks = runTimeTicks else { return nil }
        return Double(ticks) / 10_000_000
    }

    var primaryArtist: String {
        albumArtist ?? artistItems?.first?.name ?? ""
    }

    func hash(into hasher: inout Hasher) { hasher.combine(id) }
    static func == (lhs: MediaItem, rhs: MediaItem) -> Bool { lhs.id == rhs.id }
}

struct NameId: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name"
    }
}

struct ItemsResponse: Codable {
    let items: [MediaItem]
    let totalRecordCount: Int
    enum CodingKeys: String, CodingKey {
        case items = "Items", totalRecordCount = "TotalRecordCount"
    }
}

struct LyricResponse: Codable {
    let lyrics: [LyricLine]
    enum CodingKeys: String, CodingKey { case lyrics = "Lyrics" }
}

struct LyricLine: Codable {
    let text: String
    let start: Int64?   // ticks (10,000,000 per second); present for synced lyrics
    enum CodingKeys: String, CodingKey { case text = "Text", start = "Start" }
    var seconds: Double? { start.map { Double($0) / 10_000_000 } }
}

struct AuthResponse: Codable {
    let accessToken: String
    let user: AuthUser
    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken", user = "User"
    }
}

struct AuthUser: Codable {
    let id: String
    let name: String
    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name"
    }
}

// MARK: - Playback

struct PlaybackQueue {
    var items: [MediaItem] = []
    /// Canonical (unshuffled) order, used to restore order when shuffle is turned off.
    var originalItems: [MediaItem] = []
    var currentIndex: Int = 0
    var isShuffled: Bool = false
    var repeatMode: RepeatMode = .off

    var currentItem: MediaItem? {
        guard !items.isEmpty, items.indices.contains(currentIndex) else { return nil }
        return items[currentIndex]
    }

    var hasNext: Bool { repeatMode == .all || currentIndex < items.count - 1 }
    var hasPrevious: Bool { repeatMode == .all || currentIndex > 0 }

    mutating func advanceToNext() {
        if currentIndex < items.count - 1 { currentIndex += 1 }
        else if repeatMode == .all { currentIndex = 0 }
    }

    mutating func advanceToPrevious() {
        if currentIndex > 0 { currentIndex -= 1 }
        else if repeatMode == .all { currentIndex = items.count - 1 }
    }
}

enum RepeatMode: String, CaseIterable {
    case off, all, one

    var systemImage: String {
        switch self {
        case .off, .all: "repeat"
        case .one: "repeat.1"
        }
    }
    var isActive: Bool { self != .off }

    mutating func cycle() {
        switch self {
        case .off: self = .all
        case .all: self = .one
        case .one: self = .off
        }
    }
}

// MARK: - Placeholder

extension MediaItem {
    static let placeholder = MediaItem(
        id: "", name: "", type: "Audio",
        sortName: nil, albumArtist: nil, albumArtists: nil,
        album: nil, albumId: nil, artistItems: nil,
        indexNumber: nil, parentIndexNumber: nil,
        runTimeTicks: nil, productionYear: nil,
        imageTags: nil, albumPrimaryImageTag: nil,
        childCount: nil, overview: nil, playlistItemId: nil
    )
}

struct CreatePlaylistResult: Codable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL, authFailed, noData
    case httpError(Int)
    case decodingError(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid server URL"
        case .authFailed: "Authentication failed — check your credentials"
        case .noData: "No data received from server"
        case .httpError(let code): "Server error (HTTP \(code))"
        case .decodingError: "Couldn't parse server response"
        case .networkError(let e): e.localizedDescription
        }
    }
}
