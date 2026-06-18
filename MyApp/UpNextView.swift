import SwiftUI

/// The Up Next queue, presented as a sheet from Now Playing. Tap a row to jump to it; swipe to
/// remove (the current track can't be removed); shuffle / repeat live in the toolbar.
struct UpNextView: View {
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(Array(player.queue.items.enumerated()), id: \.offset) { index, item in
                    row(index: index, item: item)
                        .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                        .listRowSeparator(.hidden)
                        .contentShape(Rectangle())
                        .onTapGesture { player.play(at: index) }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            if index != player.queue.currentIndex {
                                Button(role: .destructive) {
                                    player.removeFromQueue(at: index)
                                } label: { Label("Remove", systemImage: "minus.circle") }
                            }
                        }
                }
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    HStack(spacing: 4) {
                        toolbarToggle("shuffle", active: player.queue.isShuffled) { player.toggleShuffle() }
                        toolbarToggle(player.queue.repeatMode.systemImage,
                                      active: player.queue.repeatMode.isActive) { player.cycleRepeat() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
    }

    private func toolbarToggle(_ system: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .symbolVariant(.none)
                .foregroundStyle(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                .contentTransition(.symbolEffect(.replace))
        }
    }

    private func row(index: Int, item: MediaItem) -> some View {
        let isCurrent = index == player.queue.currentIndex
        return HStack(spacing: 14) {
            LibraryImage(url: client.artworkURL(for: item, size: 160), maxPixel: 180) {
                Color(.systemGray6)
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.42))
                    Image(systemName: "waveform").foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: player.isPlaying)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.primaryArtist)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            if let dur = item.durationSeconds {
                Text(dur.formattedDuration)
                    .font(.footnote).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
    }
}
