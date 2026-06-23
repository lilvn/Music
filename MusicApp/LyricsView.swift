import SwiftUI

/// Synced (or plain) lyrics for the current track, presented as a sheet from Now Playing. Synced
/// lyrics highlight the active line and auto-scroll; tapping a timed line seeks to it.
struct LyricsView: View {
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var lines: [LyricLine] = []
    @State private var loading = true

    private var synced: Bool { lines.contains { $0.seconds != nil } }

    private var activeIndex: Int? {
        guard synced else { return nil }
        let t = player.currentTime + 0.25
        return lines.lastIndex { ($0.seconds ?? .infinity) <= t }
    }

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if lines.isEmpty {
                    ContentUnavailableView("No Lyrics",
                                           systemImage: "quote.bubble",
                                           description: Text("No lyrics available for this track."))
                } else {
                    lyricsScroll
                }
            }
            .navigationTitle("Lyrics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationBackground {
            CrossfadeBackground(url: client.artworkURL(for: player.currentItem ?? .placeholder, size: 400))
        }
        .task {
            if let id = player.currentItem?.id {
                lines = (try? await client.fetchLyrics(itemId: id)) ?? []
            }
            loading = false
        }
    }

    private var lyricsScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let active = i == activeIndex
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.title2).fontWeight(.bold)
                            .foregroundStyle(active ? Color.primary : Color.secondary.opacity(synced ? 0.45 : 1))
                            .scaleEffect(active ? 1.02 : 1, anchor: .leading)
                            .animation(.easeInOut(duration: 0.25), value: active)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                            .onTapGesture {
                                if let s = line.seconds { player.seek(to: s) }
                            }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 80)
            }
            .scrollIndicators(.hidden)
            .onChange(of: activeIndex) { _, idx in
                guard let idx else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }
}
