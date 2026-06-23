import Foundation
import CoreSpotlight
import UniformTypeIdentifiers

/// Indexes albums, artists, and playlists into Spotlight so they're searchable from the system, and
/// resolves a tapped Spotlight result back to a `LibraryRoute`. Item identifiers reuse the
/// `LibraryRoute.id` scheme ("album-<id>" / "artist-<id>" / "playlist-<id>").
enum SpotlightIndexer {
    static let domain = "com.music.library"

    static func reindex(_ client: JellyfinClient) async {
        async let albumsT = client.fetchAlbums()
        async let artistsT = client.fetchArtists()
        async let playlistsT = client.fetchPlaylists()
        let albums = (try? await albumsT) ?? []
        let artists = (try? await artistsT) ?? []
        let playlists = (try? await playlistsT) ?? []

        var items: [CSSearchableItem] = []
        for a in albums {
            items.append(make(id: "album-\(a.id)", title: a.name,
                              subtitle: a.albumArtist ?? a.primaryArtist, kind: "Album"))
        }
        for a in artists {
            items.append(make(id: "artist-\(a.id)", title: a.name, subtitle: "Artist", kind: "Artist"))
        }
        for p in playlists {
            items.append(make(id: "playlist-\(p.id)", title: p.name, subtitle: "Playlist", kind: "Playlist"))
        }

        let index = CSSearchableIndex.default()
        try? await index.deleteSearchableItems(withDomainIdentifiers: [domain])
        try? await index.indexSearchableItems(items)
    }

    private static func make(id: String, title: String, subtitle: String, kind: String) -> CSSearchableItem {
        let attr = CSSearchableItemAttributeSet(contentType: .content)
        attr.title = title
        attr.contentDescription = subtitle
        attr.kind = kind
        return CSSearchableItem(uniqueIdentifier: id, domainIdentifier: domain, attributeSet: attr)
    }

    /// Resolve a Spotlight result identifier back to a route to open.
    static func route(forIdentifier id: String, client: JellyfinClient) async -> LibraryRoute? {
        let parts = id.split(separator: "-", maxSplits: 1).map(String.init)
        guard parts.count == 2, let item = try? await client.fetchItem(id: parts[1]) else { return nil }
        switch parts[0] {
        case "album":    return .album(item)
        case "artist":   return .artist(item)
        case "playlist": return .playlist(item)
        default:         return nil
        }
    }
}
