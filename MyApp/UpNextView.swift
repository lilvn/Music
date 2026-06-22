import SwiftUI

/// The Up Next queue, presented as a Liquid-Glass sheet from Now Playing. Tap a row to jump to it;
/// swipe to remove (the current track can't be removed); shuffle (bottom-left) and repeat
/// (bottom-right) are glass buttons pinned to the corners.
struct UpNextView: View {
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                List {
                    ForEach(Array(player.queue.items.enumerated()), id: \.offset) { index, item in
                        row(index: index, item: item)
                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
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
                    Color.clear.frame(height: 80)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)

                HStack {
                    glassToggle("shuffle", active: player.queue.isShuffled) { player.toggleShuffle() }
                    Spacer()
                    glassToggle(player.queue.repeatMode.systemImage,
                                active: player.queue.repeatMode.isActive) { player.cycleRepeat() }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 12)
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
        }
        .presentationBackground(.thinMaterial)
    }

    private func glassToggle(_ system: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 56, height: 56)
                .glassEffect(active ? .regular.tint(.primary).interactive() : .regular.interactive(), in: Circle())
        }
        .buttonStyle(ScaleButtonStyle())
        .sensoryFeedback(.impact(weight: .light), trigger: active)
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
