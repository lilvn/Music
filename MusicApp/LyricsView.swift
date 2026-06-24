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
            // Static (animated: false): a drifting full-screen blur behind the lyrics was a heavy,
            // continuous GPU cost. The track-to-track cross-fade still animates.
            CrossfadeBackground(url: client.artworkURL(for: player.currentItem ?? .placeholder, size: 400),
                                animated: false)
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
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                        let active = i == activeIndex
                        Text(line.text.isEmpty ? " " : line.text)
                            // No line ever scales ABOVE 1.0 — a full-width active line magnified past 1.0
                            // overflowed off the right edge. Instead the active line sits at full size and
                            // the others shrink, so it still reads as magnified without ever clipping.
                            .font(.system(size: 20, weight: .bold))
                            .foregroundStyle(active ? AnyShapeStyle(.primary)
                                                    : AnyShapeStyle(.secondary.opacity(synced ? 0.4 : 1)))
                            .scaleEffect(active ? 1 : 0.85, anchor: .leading)
                            .animation(.spring(response: 0.34, dampingFraction: 0.82), value: active)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(i)
                            .onTapGesture {
                                if let s = line.seconds { player.seek(to: s) }
                            }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 24)
                .padding(.bottom, 100)
            }
            .scrollIndicators(.hidden)
            // Open already positioned on the current line (the .onChange below only fires on a CHANGE).
            .onAppear {
                guard let idx = activeIndex else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
            .onChange(of: activeIndex) { _, idx in
                guard let idx else { return }
                withAnimation(.easeInOut(duration: 0.35)) {
                    proxy.scrollTo(idx, anchor: .center)
                }
            }
        }
    }
}
