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
/// Mini-bar mirror of a REMOTE session — visually IDENTICAL to the local MiniPlayer (spinning CD,
/// title/artist, transport on the right, the artwork-gradient fill AS the live progress) so playing on
/// another device feels seamless; only the top-right Transfer pill gives it away. The controls drive
/// the remote device. Tap to open the remote queue.
struct RemoteMiniBar: View {
    var appColorScheme: ColorScheme = .light
    @Environment(JellyfinClient.self) private var client
    private var hub: SessionHub { SessionHub.shared }
    @State private var showQueue = false
    @State private var width: CGFloat = 1
    @State private var barHeight: CGFloat = 56

    var body: some View {
        if let remote = hub.remote {
            HStack(spacing: 10) {
                SpinningDisc(artURL: client.artworkURL(for: remote.item, size: 160),
                             size: 40,
                             spinning: !remote.isPaused)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(remote.item.name)
                        .font(.subheadline).fontWeight(.semibold).lineLimit(1)
                    Text(remote.item.primaryArtist)
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }

                Spacer(minLength: 6)

                Button { hub.previousRemote() } label: {
                    Image(systemName: "backward.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
                Button { hub.playPauseRemote() } label: {
                    Image(systemName: remote.isPaused ? "play.fill" : "pause.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 34, height: 44)
                        .contentShape(Rectangle())
                }
                Button { hub.nextRemote() } label: {
                    Image(systemName: "forward.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 32, height: 44)
                        .contentShape(Rectangle())
                }
            }
            .buttonStyle(.plain)
            .foregroundStyle(.primary)
            // Same optical inset as MiniPlayer: the CD concentric with the capsule's left end cap.
            .padding(.leading, max(4, (barHeight - 40) / 2))
            .padding(.trailing, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            // The artwork-gradient fill IS the progress bar — revealed left→right, LIVE (extrapolated
            // between session polls), exactly like the local bar. No separate strip.
            .background(alignment: .leading) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let frac = remote.durationSeconds > 0
                        ? min(max(remote.livePosition(at: ctx.date) / remote.durationSeconds, 0), 1) : 0
                    ArtworkGradient(url: client.artworkURL(for: remote.item, size: 160), blur: 20)
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .overlay((appColorScheme == .dark ? Color.black : Color.white).opacity(0.34))
                        .opacity(0.82)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(0, width * frac))
                        }
                }
                .allowsHitTesting(false)
            }
            .background {
                GeometryReader { g in
                    Color.clear.onChange(of: g.size, initial: true) { _, s in
                        width = s.width; barHeight = s.height
                    }
                }
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .onTapGesture { showQueue = true }
            .sheet(isPresented: $showQueue) { RemoteQueueView() }
            .environment(\.colorScheme, appColorScheme)
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
