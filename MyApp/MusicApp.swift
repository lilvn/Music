import SwiftUI

@main
struct MusicApp: App {
    @State private var client = JellyfinClient.shared
    @State private var player = Player.shared

    init() {
        // Cache artwork aggressively so covers aren't re-downloaded while scrolling grids /
        // carousels or re-rendering during playback.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,     // 64 MB
                                   diskCapacity: 512 * 1024 * 1024)      // 512 MB
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if client.isAuthenticated {
                    RootTabView()
                } else {
                    LoginView()
                }
            }
            .environment(client)
            .environment(player)
            .tint(.primary)
        }
    }
}
