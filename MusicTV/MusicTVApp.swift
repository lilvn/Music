import SwiftUI

@main
struct MusicTVApp: App {
    @State private var client = JellyfinClient.shared
    @State private var player = Player.shared

    init() {
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,
                                   diskCapacity: 512 * 1024 * 1024)
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if client.isAuthenticated {
                    TVRootView()
                } else {
                    TVLoginView()
                }
            }
            .environment(client)
            .environment(player)
            // Queue pre-buffering reuses the shared AudioStore; we skip the full library auto-download
            // on the TV (it's a plugged-in streaming box, not a phone that leaves the house).
            .task {
                AudioStore.shared.attach(client)
                SessionHub.shared.start(client: client, player: player)
                if client.isAuthenticated { await TVVideoController.shared.loadLibrary(client: client) }
            }
            .onChange(of: client.userId) { _, newUserId in
                player.userDidChange(to: newUserId)
                SessionHub.shared.restart()
            }
            // TV rule: a track with a library music video NEVER plays its regular audio — the video is
            // the playback, on every page. Evaluated at the root so it holds app-wide: on track change,
            // and when audio starts (so pressing play on a matched track swaps to its video too).
            .onChange(of: player.currentItem?.id) { _, _ in
                TVVideoController.shared.evaluate(client: client, audio: player)
            }
            .onChange(of: player.isPlaying) { _, playing in
                if playing { TVVideoController.shared.evaluate(client: client, audio: player) }
            }
        }
    }
}
