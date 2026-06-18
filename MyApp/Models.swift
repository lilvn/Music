import Foundation

// MARK: - API response models

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
    let playlistItemId: String?   // entry id when this item lives inside a playlist

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

struct NameId: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    enum CodingKeys: String, CodingKey { case id = "Id", name = "Name" }
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

struct CreatePlaylistResult: Codable {
    let id: String
    enum CodingKeys: String, CodingKey { case id = "Id" }
}

// MARK: - Navigation

/// Value-based push route. Identifiable so it can also drive a `.sheet(item:)`.
enum LibraryRoute: Hashable, Identifiable {
    case album(MediaItem)
    case artist(MediaItem)
    case playlist(MediaItem)

    var id: String {
        switch self {
        case .album(let m):    return "album-\(m.id)"
        case .artist(let m):   return "artist-\(m.id)"
        case .playlist(let m): return "playlist-\(m.id)"
        }
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

// MARK: - Errors

enum APIError: LocalizedError {
    case invalidURL, noData
    case httpError(Int)
    case decodingError(Error)
    case networkError(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Invalid server URL"
        case .noData: "No data received from server"
        case .httpError(let code): "Server error (HTTP \(code))"
        case .decodingError: "Couldn't parse server response"
        case .networkError(let e): e.localizedDescription
        }
    }
}

// MARK: - Duration formatting

extension Double {
    var formattedDuration: String {
        guard isFinite && !isNaN && self >= 0 else { return "0:00" }
        let total = Int(self)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
