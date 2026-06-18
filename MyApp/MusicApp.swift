import SwiftUI

@main
struct MusicApp: App {
    init() {
        // Cache artwork aggressively so covers aren't re-downloaded while scrolling grids /
        // carousels or re-rendering during playback.
        URLCache.shared = URLCache(memoryCapacity: 64 * 1024 * 1024,     // 64 MB
                                   diskCapacity: 512 * 1024 * 1024)      // 512 MB
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(JellyfinClient.shared)
                .environment(Player.shared)
                .tint(.primary)
        }
    }
}
