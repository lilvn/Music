import SwiftUI

/// The Up Next queue, presented as a Liquid-Glass sheet from Now Playing. Tap a row to jump to it;
/// swipe to remove (the current track can't be removed); shuffle (bottom-left) and repeat
/// (bottom-right) are glass buttons pinned to the corners.
struct UpNextView: View {
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @Namespace private var highlightNS

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
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
                                } label: { Label("Remove", systemImage: "trash") }
                                .tint(.red)
                            }
                        }
                }
                .onMove { player.moveInQueue(from: $0, to: $1) }

                autoplaySection
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .scrollIndicators(.hidden)
            // Glass highlight glides between rows; the Autoplay section fades when it changes.
            .animation(.spring(response: 0.4, dampingFraction: 0.82), value: player.queue.currentIndex)
            .animation(.easeInOut(duration: 0.4), value: player.autoplayTracks.count)
            .task { await player.refreshAutoplay() }
            // Open scrolled to the current track.
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo(player.queue.currentIndex, anchor: .center)
                }
            }
            // The shuffle / repeat controls live in a bottom inset (not a ZStack overlay over the
            // List) so the list never competes with them for taps.
            .safeAreaInset(edge: .bottom) {
                HStack {
                    GlassToggle(system: "shuffle", active: player.queue.isShuffled) { player.toggleShuffle() }
                    Spacer()
                    GlassToggle(system: player.queue.repeatMode.systemImage,
                                active: player.queue.repeatMode.isActive) { player.cycleRepeat() }
                }
                .padding(.horizontal, 24)
                .padding(.top, 8)
                .padding(.bottom, 12)
            }
            .navigationTitle("Up Next")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.fontWeight(.semibold)
                }
            }
            }   // ScrollViewReader
        }
        .presentationBackground {
            CrossfadeBackground(url: client.artworkURL(for: player.currentItem ?? .placeholder, size: 400))
        }
    }

    /// Apple-Music-style Autoplay footer: a toggle, with the next auto-played track shown below it.
    @ViewBuilder
    private var autoplaySection: some View {
        HStack(spacing: 12) {
            Image(systemName: "infinity")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(player.autoplayEnabled ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            Text("Autoplay").font(.headline)
            Spacer(minLength: 8)
            Toggle("", isOn: Binding(get: { player.autoplayEnabled },
                                     set: { player.setAutoplay($0) }))
                .labelsHidden()
                .tint(.green)
        }
        .padding(.horizontal, 20)
        .padding(.top, 24)
        .padding(.bottom, 8)
        .listRowInsets(EdgeInsets())
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)

        if player.autoplayEnabled {
            ForEach(Array(player.autoplayTracks.enumerated()), id: \.offset) { i, track in
                row(index: -1, item: track)
                    .opacity(0.9)
                    .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { player.playAutoplayFrom(i) }
            }
        }
    }

    /// A glass shuffle/repeat toggle. Its own `bump` state fires haptic feedback on EVERY tap — the
    /// old version keyed feedback off `active`, so a repeat cycle that didn't flip active (off→all,
    /// same icon) felt like a dead tap.
    private struct GlassToggle: View {
        let system: String
        let active: Bool
        let action: () -> Void
        @State private var bump = false

        var body: some View {
            Button {
                action()
                bump.toggle()
            } label: {
                Image(systemName: system)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(active ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.primary))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: 56, height: 56)
                    .glassEffect(active ? .regular.tint(.primary).interactive() : .regular.interactive(), in: Circle())
            }
            .buttonStyle(ScaleButtonStyle())
            .sensoryFeedback(.impact(weight: .light), trigger: bump)
        }
    }

    private func row(index: Int, item: MediaItem) -> some View {
        let isCurrent = index == player.queue.currentIndex
        return HStack(spacing: 12) {
            LibraryImage(url: client.artworkURL(for: item, size: 160), maxPixel: 180) {
                ArtworkPlaceholder()
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

            // Animated bars next to the title (not over the artwork).
            if isCurrent {
                PlayingIndicator(url: client.artworkURL(for: item, size: 160), active: player.isPlaying)
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Liquid-glass "magnifier" selector that glides between rows as the current track changes.
        .background {
            if isCurrent {
                Color.clear
                    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 18))
                    .matchedGeometryEffect(id: "upnextHighlight", in: highlightNS)
            }
        }
    }
}
