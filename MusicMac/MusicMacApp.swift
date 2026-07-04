import SwiftUI

@main
struct MusicMacApp: App {
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
                    MacRootView()
                } else {
                    MacLoginView()
                }
            }
            .environment(client)
            .environment(player)
            .frame(minWidth: 960, minHeight: 620)
            .task {
                AudioStore.shared.attach(client)
                SessionHub.shared.start(client: client, player: player)
                NotchHUD.shared.attach(client: client, player: player)
            }
            .onChange(of: client.userId) { _, newUserId in
                player.userDidChange(to: newUserId)
                SessionHub.shared.restart()
            }
        }
        .commands {
            CommandMenu("Playback") {
                Button(player.isPlaying ? "Pause" : "Play") { player.togglePlayPause() }
                    .keyboardShortcut(.space, modifiers: [.option])
                Button("Next Track") { player.nextTrack() }
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
                Button("Previous Track") { player.previousTrack() }
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
            }
        }

        Settings {
            MacSettingsView()
                .environment(client)
                .environment(player)
        }
    }
}

/// Mac settings: the connected server + sign out.
struct MacSettingsView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    var body: some View {
        Form {
            Section("Server") {
                LabeledContent("Address", value: client.serverURL.isEmpty ? "—" : client.serverURL)
                LabeledContent("User", value: client.username.isEmpty ? "—" : client.username)
            }
            Section {
                Button("Sign Out", role: .destructive) {
                    player.stop()
                    client.signOut()
                }
                .disabled(!client.isAuthenticated)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420, height: 240)
    }
}
