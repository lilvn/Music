import SwiftUI

// The Now Playing side panes: Lyrics and Queue. When one is open the artwork docks to the bottom-left
// (exactly like video mode) and the pane fills the centre.

// MARK: - Lyrics

/// Synced lyrics for the current track, auto-scrolling against player.currentTime — the tvOS port of
/// the iPhone's LyricsView. Pure display (not focusable): it follows the song on its own.
struct TVLyricsPane: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var lines: [LyricLine] = []
    @State private var loaded = false

    /// The last line whose start has passed (small lead so the highlight lands ON the beat).
    private var activeIndex: Int? {
        lines.lastIndex { ($0.seconds ?? .infinity) <= player.currentTime + 0.25 }
    }

    var body: some View {
        Group {
            if !loaded {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                ContentUnavailableView("No Lyrics", systemImage: "quote.bubble",
                                       description: Text("This song doesn't have lyrics."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 30) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.system(size: 42, weight: .bold))
                                    .foregroundStyle(i == activeIndex ? AnyShapeStyle(.primary)
                                                                      : AnyShapeStyle(.secondary.opacity(0.45)))
                                    // Inactive lines shrink; the active line is never scaled ABOVE 1.0
                                    // (upscaled text rasterizes soft).
                                    .scaleEffect(i == activeIndex ? 1.0 : 0.86, anchor: .leading)
                                    .animation(.easeInOut(duration: 0.3), value: activeIndex)
                                    .id(i)
                            }
                        }
                        .padding(.vertical, 60)
                        .padding(.horizontal, 40)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollClipDisabled()
                    .onChange(of: activeIndex) { _, idx in
                        guard let idx else { return }
                        withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(idx, anchor: .center) }
                    }
                    .onAppear {
                        // Initial jump once layout settles.
                        let idx = activeIndex
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if let idx { proxy.scrollTo(idx, anchor: .center) }
                        }
                    }
                }
            }
        }
        // Refetch per track; a 404 (no lyrics) collapses to the empty state.
        .task(id: player.currentItem?.id) {
            loaded = false
            lines = []
            if let id = player.currentItem?.id {
                lines = (try? await client.fetchLyrics(itemId: id)) ?? []
            }
            loaded = true
        }
    }
}

// MARK: - Queue

/// The play queue as a focusable list — click a row to jump there (the carousel's choreography plays
/// the swap). Menu inside the list closes the pane.
struct TVQueuePane: View {
    @Environment(Player.self) private var player
    var onClose: () -> Void = {}

    /// Row uid = "itemId#occurrence" — the same song can sit in the queue twice.
    private struct Row: Identifiable {
        let uid: String
        let index: Int
        let item: MediaItem
        var id: String { uid }
    }
    private var rows: [Row] {
        var seen: [String: Int] = [:]
        return player.queue.items.enumerated().map { i, item in
            let n = seen[item.id, default: 0]
            seen[item.id] = n + 1
            return Row(uid: "\(item.id)#\(n)", index: i, item: item)
        }
    }
    private var currentUID: String? {
        let items = player.queue.items
        let i = player.queue.currentIndex
        guard items.indices.contains(i) else { return nil }
        var occurrence = 0
        for j in 0..<i where items[j].id == items[i].id { occurrence += 1 }
        return "\(items[i].id)#\(occurrence)"
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 6) {
                    Text("Up Next")
                        .font(.title3).fontWeight(.semibold)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.bottom, 6)
                    ForEach(rows) { row in
                        TVSongRow(song: row.item) { player.play(at: row.index) }
                            .id(row.uid)
                    }
                }
                .padding(.vertical, 24)
                .padding(.horizontal, 24)   // room for the glass row's focus lift
            }
            .scrollClipDisabled()
            .onExitCommand(perform: onClose)   // Menu while browsing the queue = close the pane
            .onAppear { if let uid = currentUID { proxy.scrollTo(uid, anchor: .center) } }
            .onChange(of: player.queue.currentIndex) { _, _ in
                guard let uid = currentUID else { return }
                withAnimation { proxy.scrollTo(uid, anchor: .center) }
            }
        }
    }
}
