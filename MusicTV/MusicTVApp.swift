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
                .task {
                    AudioStore.shared.attach(client)
                    SessionHub.shared.start(client: client, player: player)
                    if client.isAuthenticated {
                        await TVVideoController.shared.loadLibrary(client: client)
                        // The restored (or already-started) track may have a matched video — the
                        // library wasn't loaded yet when it appeared, so evaluate once now.
                        TVVideoController.shared.evaluate(client: client, audio: player)
                    }
                }
                .onChange(of: client.userId) { _, newUserId in
                    player.userDidChange(to: newUserId)
                    SessionHub.shared.restart()
                }
                // Track changed → hand playback to the new song's matched video, or back to audio.
                .onChange(of: player.currentItem?.id) { _, _ in
                    TVVideoController.shared.evaluate(client: client, audio: player)
                }
                // Audio play-state changed → while a matched video owns playback the audio must
                // stay silent; a stray resume (Siri, remote command) is folded into the video.
                .onChange(of: player.isPlaying) { _, _ in
                    TVVideoController.shared.audioPlayStateChanged(audio: player)
                }
        }
    }

}
