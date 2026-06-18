import AppIntents
import Foundation

/// A library item (song / album / artist) exposed to App Intents so Siri & Shortcuts can resolve a
/// spoken name like "Play ANTI in Jellytunes" by searching the library.
struct LibraryItemEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Music"
    static var defaultQuery = LibraryItemQuery()

    let id: String      // Jellyfin item id
    let name: String
    let kind: String    // "Audio" | "MusicAlbum" | "MusicArtist"

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct LibraryItemQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [LibraryItemEntity] {
        var out: [LibraryItemEntity] = []
        for id in identifiers {
            if let item = try? await JellyfinAPI.shared.fetchItem(id: id) {
                out.append(LibraryItemEntity(id: item.id, name: item.name, kind: item.type))
            }
        }
        return out
    }

    /// Resolve a spoken/typed name to candidate items via library search.
    @MainActor
    func entities(matching string: String) async throws -> [LibraryItemEntity] {
        let results = (try? await JellyfinAPI.shared.search(query: string)) ?? []
        return results.prefix(12).map { LibraryItemEntity(id: $0.id, name: $0.name, kind: $0.type) }
    }
}

/// "Play <song/album/artist> in Jellytunes".
struct PlayLibraryIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Music"
    static var description = IntentDescription("Play a song, album, or artist from your Jellyfin library.")
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Music")
    var item: LibraryItemEntity

    @Parameter(title: "Shuffle", default: false)
    var shuffle: Bool

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let line = await JellytunesIntents.play(item: item, shuffle: shuffle)
        return .result(dialog: "\(line)")
    }
}

/// A playlist exposed to App Intents (for "Add this song to <playlist>").
struct PlaylistEntity: AppEntity {
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Playlist"
    static var defaultQuery = PlaylistQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PlaylistQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [String]) async throws -> [PlaylistEntity] {
        let all = (try? await JellyfinAPI.shared.fetchPlaylists()) ?? []
        return all.filter { identifiers.contains($0.id) }.map { PlaylistEntity(id: $0.id, name: $0.name) }
    }
    @MainActor
    func entities(matching string: String) async throws -> [PlaylistEntity] {
        let all = (try? await JellyfinAPI.shared.fetchPlaylists()) ?? []
        return all.filter { $0.name.localizedCaseInsensitiveContains(string) }
                  .map { PlaylistEntity(id: $0.id, name: $0.name) }
    }
    @MainActor
    func suggestedEntities() async throws -> [PlaylistEntity] {
        let all = (try? await JellyfinAPI.shared.fetchPlaylists()) ?? []
        return all.prefix(12).map { PlaylistEntity(id: $0.id, name: $0.name) }
    }
}

/// "Add this song to <playlist> in Jellytunes" — adds the currently playing track to a playlist.
struct AddCurrentToPlaylistIntent: AppIntent {
    static var title: LocalizedStringResource = "Add Current Song to Playlist"
    static var description = IntentDescription("Add the song that's playing to one of your playlists.")
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Playlist")
    var playlist: PlaylistEntity

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let track = AudioPlayerManager.shared.currentItem else {
            return .result(dialog: "Nothing is playing right now.")
        }
        try? await JellyfinAPI.shared.addToPlaylist(playlist.id, itemIds: [track.id])
        return .result(dialog: "Added \(track.name) to \(playlist.name).")
    }
}

/// "Play recently played in Jellytunes".
struct PlayRecentlyPlayedIntent: AppIntent {
    static var title: LocalizedStringResource = "Play Recently Played"
    static var description = IntentDescription("Play your recently played songs.")
    static var openAppWhenRun: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let api = JellyfinAPI.shared
        let tracks = (try? await api.fetchRecentlyPlayed(limit: 50)) ?? []
        guard !tracks.isEmpty else { return .result(dialog: "You don't have any recently played songs yet.") }
        AudioPlayerManager.shared.play(items: tracks, api: api)
        return .result(dialog: "Playing your recently played songs.")
    }
}

@MainActor
enum JellytunesIntents {
    /// Start playback for a resolved library item; returns a spoken-result line.
    static func play(item: LibraryItemEntity, shuffle: Bool) async -> String {
        let api = JellyfinAPI.shared
        let player = AudioPlayerManager.shared
        switch item.kind {
        case "Audio":
            if let track = try? await api.fetchItem(id: item.id) {
                player.play(items: [track], shuffled: shuffle, api: api)
                return "Playing \(item.name)."
            }
        case "MusicAlbum":
            if let tracks = try? await api.fetchTracks(parentId: item.id), !tracks.isEmpty {
                player.play(items: tracks, shuffled: shuffle, api: api)
                return "Playing \(item.name)."
            }
        case "MusicArtist":
            let albums = (try? await api.fetchAlbums(artistId: item.id)) ?? []
            var all: [MediaItem] = []
            for a in albums.prefix(8) { all += (try? await api.fetchTracks(parentId: a.id)) ?? [] }
            if !all.isEmpty {
                player.play(items: all, shuffled: shuffle, api: api)
                return "Playing \(item.name)."
            }
        default:
            break
        }
        return "I couldn't play \(item.name)."
    }
}

struct JellytunesShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PlayLibraryIntent(),
            phrases: [
                "Play \(\.$item) in \(.applicationName)",
                "Play \(\.$item) on \(.applicationName)",
            ],
            shortTitle: "Play Music",
            systemImageName: "play.circle.fill"
        )
        AppShortcut(
            intent: PlayRecentlyPlayedIntent(),
            phrases: [
                "Play recently played in \(.applicationName)",
                "Play my recent songs in \(.applicationName)",
            ],
            shortTitle: "Recently Played",
            systemImageName: "clock.arrow.circlepath"
        )
        AppShortcut(
            intent: AddCurrentToPlaylistIntent(),
            phrases: [
                "Add this to \(\.$playlist) in \(.applicationName)",
                "Add this song to \(\.$playlist) in \(.applicationName)",
            ],
            shortTitle: "Add to Playlist",
            systemImageName: "text.badge.plus"
        )
    }
}
