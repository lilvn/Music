import SwiftUI

@main
struct MusicWatchApp: App {
    @State private var client = JellyfinClient.shared
    @State private var player = Player.shared

    var body: some Scene {
        WindowGroup {
            Group {
                if client.isAuthenticated {
                    WatchRootView()
                } else {
                    WatchLoginView()
                }
            }
            .environment(client)
            .environment(player)
            .task {
                SessionHub.shared.start(client: client, player: player)
            }
            .onChange(of: client.userId) { _, newUserId in
                SessionHub.shared.restart()
            }
        }
    }
}
