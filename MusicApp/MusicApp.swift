import SwiftUI
import UIKit

/// Loads the keyboard subsystem once, early, so the FIRST time Search opens it doesn't lag. That
/// first-ever keyboard presentation is a known ~1s main-thread hitch on iOS, and here it was long
/// enough to also stall playback — warming it at launch (before any audio plays) absorbs the cost.
@MainActor
enum KeyboardWarmer {
    private static var warmed = false
    static func warmUp() {
        guard !warmed,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .flatMap(\.windows)
                .first(where: { $0.isKeyWindow }) else { return }
        warmed = true
        // Focus a UISearchTextField (the kind `.searchable` uses) for ONE run-loop tick so the keyboard
        // process actually loads (a synchronous resign cancels the load before it happens — why the
        // first Search still hitched), then resign next tick so the flash is imperceptible.
        let field = UISearchTextField()
        field.frame = CGRect(x: -20, y: -20, width: 1, height: 1)
        window.addSubview(field)
        field.becomeFirstResponder()
        DispatchQueue.main.async {
            field.resignFirstResponder()
            field.removeFromSuperview()
        }
    }
}

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
            // The signed-in Jellyfin user changed (login / switch / sign-out): re-point per-user state
            // — Recently Played history and Liked Songs both belong to that specific account.
            .onChange(of: client.userId) { _, newUserId in
                player.userDidChange(to: newUserId)
                Task { await client.refreshFavorites() }
            }
        }
    }
}
