import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Indexes the library (albums / artists / playlists) into iOS Spotlight so the user can search
/// them from the system search field, and resolves a tapped result back into a `LibraryRoute`.
@MainActor
enum SpotlightIndexer {
    static let domain = "com.jellytunes.library"

    /// Re-index the whole library. Cheap to call on launch; replaces the previous index.
    static func reindex(_ api: JellyfinAPI) async {
        let albums = (try? await api.fetchAlbums(limit: 500)) ?? []
        let artists = (try? await api.fetchArtists(limit: 300)) ?? []
        let playlists = (try? await api.fetchPlaylists()) ?? []

        var items: [CSSearchableItem] = []
        items += albums.map { make($0, kind: "album", subtitle: $0.albumArtist ?? $0.primaryArtist) }
        items += artists.map { make($0, kind: "artist", subtitle: "Artist") }
        items += playlists.map { make($0, kind: "playlist", subtitle: "Playlist") }
        guard !items.isEmpty else { return }

        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: [domain])
        try? await index.indexSearchableItems(items)
    }

    private static func make(_ item: MediaItem, kind: String, subtitle: String) -> CSSearchableItem {
        let attr = CSSearchableItemAttributeSet(contentType: UTType.audio)
        attr.title = item.name
        attr.contentDescription = subtitle
        // The identifier mirrors LibraryRoute.id ("album-<id>") so we can resolve it back on tap.
        return CSSearchableItem(uniqueIdentifier: "\(kind)-\(item.id)",
                                domainIdentifier: domain,
                                attributeSet: attr)
    }

    /// Resolve a tapped Spotlight result identifier ("album-<id>") into a route (fetches the item).
    static func route(forIdentifier id: String, api: JellyfinAPI) async -> LibraryRoute? {
        guard let dash = id.firstIndex(of: "-") else { return nil }
        let kind = String(id[..<dash])
        let itemId = String(id[id.index(after: dash)...])
        guard let item = try? await api.fetchItem(id: itemId) else { return nil }
        switch kind {
        case "album":    return .album(item)
        case "artist":   return .artist(item)
        case "playlist": return .playlist(item)
        default:         return nil
        }
    }
}
