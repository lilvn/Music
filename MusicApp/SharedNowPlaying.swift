import SwiftUI

/// "Transfer to this device" pill — appears on any device that isn't the one currently playing (iOS:
/// floating top-right; tvOS: a focusable pill in the custom nav bar) and pulls the remote session
/// (queue + position) onto this device.
struct TransferButton: View {
    @Environment(Player.self) private var player
    private var hub: SessionHub { SessionHub.shared }
#if os(tvOS)
    @FocusState private var focused: Bool
#endif

    var body: some View {
        // (A video can't transfer as local audio — hide the pill for MusicVideo sessions.)
        if let remote = hub.remote, !player.isPlaying, remote.item.type != "MusicVideo" {
            Button {
                hub.transferHere()
            } label: {
                HStack(spacing: 8) {
                    if hub.transferring {
                        ProgressView()
                    } else {
                        Image(systemName: "airplayaudio")
                    }
                    Text("Transfer Here")
                        .fontWeight(.semibold)
                }
                .font(.subheadline)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .glassEffect(.regular.interactive(), in: .capsule)
            }
#if os(iOS)
            .buttonStyle(.plain)
#else
            // Bare style (no white platter) + an explicit ring/grow so it reads focused in the nav bar.
            .buttonStyle(.tvBare)
            .focused($focused)
            .overlay(Capsule().strokeBorder(.white.opacity(focused ? 0.95 : 0), lineWidth: 2))
            .scaleEffect(focused ? 1.05 : 1.0)
            .animation(.easeOut(duration: 0.15), value: focused)
#endif
            .disabled(hub.transferring)
            .accessibilityLabel("Transfer playback from \(remote.deviceName) to this device")
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
        }
    }
}

#if os(iOS)
/// Mini-bar mirror of a REMOTE session — shown in the bottom accessory when nothing is loaded locally
/// (or this device yielded playback to another). The controls drive the remote device; the thin strip
/// along the bottom is its LIVE playhead (extrapolated between session polls — works for the TV's
/// music videos too). Tap to open the remote queue.
struct RemoteMiniBar: View {
    @Environment(JellyfinClient.self) private var client
    private var hub: SessionHub { SessionHub.shared }
    @State private var showQueue = false

    var body: some View {
        if let remote = hub.remote {
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let frac = remote.durationSeconds > 0
                    ? min(max(remote.livePosition(at: ctx.date) / remote.durationSeconds, 0), 1) : 0
                HStack(spacing: 10) {
                    LibraryImage(url: client.artworkURL(for: remote.item, size: 160), maxPixel: 160) {
                        Color(.systemGray5)
                    }
                    .frame(width: 40, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                    VStack(alignment: .leading, spacing: 1) {
                        Text(remote.item.name)
                            .font(.subheadline).fontWeight(.medium).lineLimit(1)
                        Text("Playing on \(remote.deviceName)")
                            .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }

                    Spacer(minLength: 6)

                    Button { hub.previousRemote() } label: {
                        Image(systemName: "backward.fill").font(.body)
                    }
                    Button { hub.playPauseRemote() } label: {
                        Image(systemName: remote.isPaused ? "play.fill" : "pause.fill")
                            .font(.title3)
                            .frame(width: 32, height: 32)
                    }
                    Button { hub.nextRemote() } label: {
                        Image(systemName: "forward.fill").font(.body)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
                // The live playhead strip, pinned along the bottom edge of the capsule.
                .overlay(alignment: .bottom) {
                    GeometryReader { g in
                        Capsule().fill(.secondary.opacity(0.22))
                            .overlay(alignment: .leading) {
                                Capsule().fill(.primary.opacity(0.65))
                                    .frame(width: max(4, (g.size.width - 24) * frac))
                            }
                            .frame(height: 3)
                            .padding(.horizontal, 12)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                            .padding(.bottom, 5)
                    }
                    .allowsHitTesting(false)
                }
            }
            .onTapGesture { showQueue = true }
            .sheet(isPresented: $showQueue) { RemoteQueueView() }
        }
    }
}

/// The REMOTE session's queue + transport, managed from this device: see what's up next on the TV,
/// jump to any track, scrub, skip — all without touching local playback.
struct RemoteQueueView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    private var hub: SessionHub { SessionHub.shared }
    /// Non-nil while the user is dragging the scrubber (overrides the live position until release).
    @State private var scrub: Double?
    /// Fallback queue fetched by ids when the session didn't carry full items.
    @State private var fetched: [MediaItem] = []

    private func rows(_ remote: SessionHub.RemoteSession) -> [MediaItem] {
        if !remote.queueItems.isEmpty { return remote.queueItems }
        if !fetched.isEmpty { return fetched }
        return [remote.item]
    }

    var body: some View {
        NavigationStack {
            Group {
                if let remote = hub.remote {
                    let queue = rows(remote)
                    let currentIndex = queue.firstIndex { $0.id == remote.item.id }
                    List {
                        Section { transport(remote) }
                            .listRowSeparator(.hidden)
                            .listRowBackground(Color.clear)
                        Section("Up Next on \(remote.deviceName)") {
                            ForEach(Array(queue.enumerated()), id: \.offset) { i, item in
                                Button { hub.playRemote(at: i) } label: {
                                    HStack(spacing: 12) {
                                        LibraryImage(url: client.artworkURL(for: item, size: 120), maxPixel: 120) {
                                            Color(.systemGray6)
                                        }
                                        .frame(width: 44, height: 44)
                                        .clipShape(RoundedRectangle(cornerRadius: DS.cornerThumb, style: .continuous))
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(item.name)
                                                .font(.callout)
                                                .fontWeight(i == currentIndex ? .semibold : .regular)
                                                .lineLimit(1)
                                            Text(item.primaryArtist)
                                                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer()
                                        if i == currentIndex {
                                            Image(systemName: "waveform")
                                                .foregroundStyle(.secondary)
                                                .symbolEffect(.variableColor.iterative, isActive: !remote.isPaused)
                                        }
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listStyle(.plain)
                } else {
                    ContentUnavailableView("Nothing playing remotely", systemImage: "airplayaudio")
                }
            }
            .navigationTitle(hub.remote.map { "On \($0.deviceName)" } ?? "Remote")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .task {
                // Session carried only ids → materialise them once for the list.
                if let r = hub.remote, r.queueItems.isEmpty, !r.queueIds.isEmpty {
                    fetched = (try? await client.fetchItems(ids: r.queueIds)) ?? []
                }
            }
        }
    }

    /// Artwork + live scrubber + transport for the remote session.
    private func transport(_ remote: SessionHub.RemoteSession) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 14) {
                LibraryImage(url: client.artworkURL(for: remote.item, size: 300), maxPixel: 300) {
                    Color(.systemGray6)
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: DS.cornerThumb, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(remote.item.name).font(.headline).lineLimit(1)
                    Text(remote.item.primaryArtist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
            }

            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let dur = max(remote.durationSeconds, 1)
                let pos = scrub ?? min(remote.livePosition(at: ctx.date), dur)
                VStack(spacing: 4) {
                    Slider(value: Binding(get: { pos }, set: { scrub = $0 }), in: 0...dur) { editing in
                        if !editing, let s = scrub { hub.seekRemote(to: s); scrub = nil }
                    }
                    HStack {
                        Text(pos.formattedDuration)
                        Spacer()
                        Text(dur.formattedDuration)
                    }
                    .font(.caption2).monospacedDigit().foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 44) {
                Button { hub.previousRemote() } label: { Image(systemName: "backward.fill").font(.title3) }
                Button { hub.playPauseRemote() } label: {
                    Image(systemName: remote.isPaused ? "play.fill" : "pause.fill").font(.title)
                }
                Button { hub.nextRemote() } label: { Image(systemName: "forward.fill").font(.title3) }
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 8)
    }
}
#endif
