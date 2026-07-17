import SwiftUI

/// The Up Next queue, presented as a Liquid-Glass sheet from Now Playing. One unified list holds the
/// queue, the Autoplay divider, and the suggestion mix, so a track can be dragged ACROSS the divider to
/// move between the queue and Autoplay. Tap a row to jump to it; swipe to remove; shuffle/repeat are
/// pinned to the bottom corners.
struct UpNextView: View {
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client

    /// One entry in the unified list: a queue/Autoplay track, or the Autoplay toggle divider.
    private enum Entry: Identifiable {
        case track(item: MediaItem, autoplay: Bool, index: Int, uid: String)
        case toggle
        var id: String {
            switch self {
            case .track(_, _, _, let uid): return uid
            case .toggle: return "__toggle__"
            }
        }
    }

    private var entries: [Entry] {
        // The same song can appear MORE THAN ONCE in the queue (e.g. you "play next" a playlist that
        // contains the current track). A plain `item.id` would collide and SwiftUI's ForEach would drop
        // the duplicate row — which is why the current track vanished. So tag each row with the item id
        // PLUS its occurrence number: unique per row, and stable for the common (no-dupes) case.
        var seen: [String: Int] = [:]
        func uid(_ item: MediaItem) -> String {
            let n = seen[item.id, default: 0]
            seen[item.id] = n + 1
            return "\(item.id)#\(n)"
        }

        var result = player.queue.items.enumerated().map {
            Entry.track(item: $0.element, autoplay: false, index: $0.offset, uid: uid($0.element))
        }
        result.append(.toggle)
        if player.autoplayEnabled {
            result += player.autoplayTracks.enumerated().map {
                Entry.track(item: $0.element, autoplay: true, index: $0.offset, uid: uid($0.element))
            }
        }
        return result
    }

    private var currentID: String? {
        let idx = player.queue.currentIndex
        guard player.queue.items.indices.contains(idx) else { return nil }
        let item = player.queue.items[idx]
        // Match the row's uid (item id + its occurrence count) so scroll-to-current lands on it.
        let occurrence = player.queue.items[0..<idx].filter { $0.id == item.id }.count
        return "\(item.id)#\(occurrence)"
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(entries) { entry in
                        entryRow(entry)
                    }
                    .onMove { player.moveUpNext(from: $0, to: $1) }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .scrollIndicators(.hidden)
                // Glass highlight glides when the playing track changes. (No implicit count animations
                // here — they made drag-reorder drops settle with a slow ease that fought the gesture;
                // the List animates its own row insert/remove/move.)
                .animation(.spring(response: 0.4, dampingFraction: 0.82), value: player.queue.currentIndex)
                .task { await player.refreshAutoplay() }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        if let currentID { proxy.scrollTo(currentID, anchor: .center) }
                    }
                }
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
                // No Done button — the sheet dismisses with the standard swipe-down.
            }   // ScrollViewReader
        }
        .presentationBackground {
            // A SOLID sheet background with only a faint art tint fading out over the top — so the
            // reorderable list scrolls over an opaque surface instead of a full-bleed blur the system
            // has to composite every frame. (The reorder machinery is the bigger cost; this trims the
            // background's share of it.)
            ZStack(alignment: .top) {
                Color(.systemBackground)
                ArtworkGradient(url: client.artworkURL(for: player.currentItem ?? .placeholder, size: 400),
                                blur: 50, animated: false)
                    .frame(height: 240)
                    .opacity(0.4)
                    .mask(LinearGradient(colors: [.black, .black.opacity(0)],
                                         startPoint: .top, endPoint: .bottom))
                    .ignoresSafeArea(edges: .top)
            }
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: Entry) -> some View {
        switch entry {
        case .toggle:
            autoplayToggle
                .listRowInsets(EdgeInsets(top: 18, leading: 20, bottom: 8, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .moveDisabled(true)   // the divider is a fixed marker — never draggable
        case .track(let item, let autoplay, let index, _):
            let isCurrent = !autoplay && index == player.queue.currentIndex
            trackRow(item: item, autoplay: autoplay, index: index)
                .opacity(autoplay ? 0.9 : 1)
                .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .moveDisabled(isCurrent)   // the playing track stays put (no forced snap-back)
                .contentShape(Rectangle())
                .onTapGesture {
                    if autoplay { player.playAutoplayFrom(index) } else { player.play(at: index) }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    if autoplay {
                        Button(role: .destructive) { player.removeAutoplay(at: index) }
                            label: { Label("Remove", systemImage: "trash") }.tint(.red)
                    } else if index != player.queue.currentIndex {
                        Button(role: .destructive) { player.removeFromQueue(at: index) }
                            label: { Label("Remove", systemImage: "trash") }.tint(.red)
                    }
                }
        }
    }

    /// Apple-Music-style Autoplay divider: an infinity icon, label, and the toggle.
    private var autoplayToggle: some View {
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
    }

    private func trackRow(item: MediaItem, autoplay: Bool, index: Int) -> some View {
        let isCurrent = !autoplay && index == player.queue.currentIndex
        return HStack(spacing: 12) {
            LibraryImage(url: client.artworkURL(for: item, size: 160), maxPixel: 180) {
                ArtworkPlaceholder()
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: DS.cornerThumb, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.primaryArtist)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer(minLength: 8)

            // The live waveform on the playing track; a grab handle on every other (reorderable) row.
            if isCurrent {
                PlayingIndicator(url: client.artworkURL(for: item, size: 160), active: player.isPlaying)
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // No highlight on the playing row — the waveform playing-indicator already marks it.
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
                    // No `.interactive()` — its own touch handling competed with the button and made
                    // taps land inconsistently; ScaleButtonStyle already gives press feedback.
                    .glassEffect(active ? .regular.tint(.primary) : .regular, in: Circle())
                    .padding(8)                  // enlarge the tap target past the visible circle
                    .contentShape(Rectangle())   // …and make the whole padded area hittable
            }
            .buttonStyle(ScaleButtonStyle())
            .sensoryFeedback(.impact(weight: .light), trigger: bump)
        }
    }
}
