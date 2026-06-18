import SwiftUI

/// Phase-1 stub. Playlists (browse / detail / create / reorder / add-to-playlist) land in Phase 2.
struct PlaylistsView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView {
                Label("Playlists", systemImage: "music.note.list")
            } description: {
                Text("Coming soon")
            }
            .navigationTitle("Playlists")
        }
    }
}
