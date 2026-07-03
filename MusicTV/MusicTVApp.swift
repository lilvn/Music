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
            .task { AudioStore.shared.attach(client) }
        }
    }
}
