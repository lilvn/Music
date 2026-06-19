import AppIntents
import Foundation

/// A library item (album / artist / song) exposed to Siri & Shortcuts. Spoken-phrase parameters must
/// be an `AppEntity` (not a plain `String`), so search is driven through `EntityStringQuery`.
struct LibraryItemEntity: AppEntity {
    let id: String
    var name: String
    var type: String

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Music"
    static let defaultQuery = LibraryItemQuery()

    var displayRepresentation: DisplayRepresentation {
        let subtitle = switch type {
        case "MusicAlbum": "Album"
        case "MusicArtist": "Artist"
        default: "Song"
        }
        return DisplayRepresentation(title: "\(name)", subtitle: "\(subtitle)")
    }
}

struct LibraryItemQuery: EntityStringQuery {
    func entities(matching string: String) async throws -> [LibraryItemEntity] {
        let results = (try? await JellyfinClient.shared.search(query: string)) ?? []
        return results.prefix(20).map { LibraryItemEntity(id: $0.id, name: $0.name, type: $0.type) }
    }

    func entities(for identifiers: [String]) async throws -> [LibraryItemEntity] {
        var out: [LibraryItemEntity] = []
        for id in identifiers {
            if let item = try? await JellyfinClient.shared.fetchItem(id: id) {
                out.append(LibraryItemEntity(id: item.id, name: item.name, type: item.type))
            }
        }
        return out
    }

    func suggestedEntities() async throws -> [LibraryItemEntity] {
        let recent = (try? await JellyfinClient.shared.fetchRecentlyPlayed(limit: 10)) ?? []
        return recent.map { LibraryItemEntity(id: $0.id, name: $0.name, type: $0.type) }
    }
}

/// "Play <album/artist/song>" — resolves the entity to tracks and starts playback.
struct PlayMusicIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Music"
    static let openAppWhenRun = true

    @Parameter(title: "Music") var item: LibraryItemEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        let client = JellyfinClient.shared
        let player = Player.shared
        let resolved = (try? await client.fetchItem(id: item.id))
        let type = resolved?.type ?? item.type

        switch type {
        case "MusicAlbum":
            let tracks = (try? await client.fetchTracks(parentId: item.id)) ?? []
            if !tracks.isEmpty { player.play(items: tracks, from: 0) }
        case "MusicArtist":
            let albums = (try? await client.fetchAlbums(artistId: item.id)) ?? []
            var all: [MediaItem] = []
            for album in albums {
                all += (try? await client.fetchTracks(parentId: album.id)) ?? []
            }
            if !all.isEmpty { player.play(items: all, from: 0) }
        default:
            if let track = resolved { player.play(items: [track], from: 0) }
        }
        return .result()
    }
}

/// "Play my recently played" — queues the recently played songs.
struct PlayRecentlyPlayedIntent: AppIntent {
    static let title: LocalizedStringResource = "Play Recently Played"
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        let tracks = (try? await JellyfinClient.shared.fetchRecentlyPlayed(limit: 30)) ?? []
        if !tracks.isEmpty { Player.shared.play(items: tracks, from: 0) }
        return .result()
    }
}

struct MusicShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayMusicIntent(),
            phrases: [
                "Play \(\.$item) in \(.applicationName)",
                "Play \(\.$item) on \(.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "play.fill"
        )
        AppShortcut(
            intent: PlayRecentlyPlayedIntent(),
            phrases: [
                "Play my recently played in \(.applicationName)",
                "Resume \(.applicationName)",
            ],
            shortTitle: "Recently Played",
            systemImageName: "clock.arrow.circlepath"
        )
    }
}
