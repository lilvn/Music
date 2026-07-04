import SwiftUI

/// The watch is a REMOTE for whatever this account is playing (phone, TV, Mac) — the wrist version
/// of the mini bar: artwork, title/artist, transport, a live playhead ring, and Digital Crown
/// scrubbing. Seamless: it reads identically no matter which device is the source.
struct WatchRootView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    private var hub: SessionHub { SessionHub.shared }

    /// Digital Crown accumulator (0…1 playhead position while scrubbing).
    @State private var crown: Double = 0
    @State private var scrubbing = false
    @State private var scrubIdle: Task<Void, Never>?

    var body: some View {
        Group {
            if let remote = hub.remote {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    let dur = max(remote.durationSeconds, 1)
                    let live = min(max(remote.livePosition(at: ctx.date) / dur, 0), 1)
                    let shown = scrubbing ? crown : live

                    VStack(spacing: 8) {
                        // Artwork inside a live progress ring — the watch-native take on the fill.
                        ZStack {
                            Circle()
                                .stroke(.white.opacity(0.15), lineWidth: 4)
                            Circle()
                                .trim(from: 0, to: shown)
                                .stroke(.white.opacity(scrubbing ? 1 : 0.8),
                                        style: StrokeStyle(lineWidth: 4, lineCap: .round))
                                .rotationEffect(.degrees(-90))
                            LibraryImage(url: client.artworkURL(for: remote.item, size: 300), maxPixel: 300) {
                                Circle().fill(Color(white: 0.18))
                            }
                            .frame(width: 74, height: 74)
                            .clipShape(Circle())
                        }
                        .frame(width: 88, height: 88)

                        VStack(spacing: 1) {
                            Text(remote.item.name)
                                .font(.footnote).fontWeight(.semibold).lineLimit(1)
                            Text(scrubbing
                                 ? (crown * dur).formattedDuration
                                 : remote.item.primaryArtist)
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                .monospacedDigit()
                        }

                        HStack(spacing: 14) {
                            Button { hub.previousRemote() } label: {
                                Image(systemName: "backward.fill")
                            }
                            Button { hub.playPauseRemote() } label: {
                                Image(systemName: remote.isPaused ? "play.fill" : "pause.fill")
                                    .font(.title3)
                            }
                            Button { hub.nextRemote() } label: {
                                Image(systemName: "forward.fill")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                    // Digital Crown scrubs the remote playhead; the seek fires when the crown rests.
                    .focusable(true)
                    .digitalCrownRotation($crown, from: 0, through: 1, by: 0.005,
                                          sensitivity: .medium,
                                          isContinuous: false, isHapticFeedbackEnabled: true)
                    .onChange(of: crown) { _, newValue in
                        guard abs(newValue - live) > 0.01 || scrubbing else { return }
                        scrubbing = true
                        scrubIdle?.cancel()
                        scrubIdle = Task {
                            try? await Task.sleep(for: .milliseconds(600))
                            guard !Task.isCancelled else { return }
                            SessionHub.shared.seekRemote(to: newValue * dur)
                            try? await Task.sleep(for: .seconds(2))   // let the poll re-anchor
                            if !Task.isCancelled { scrubbing = false }
                        }
                    }
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "hifispeaker.2.fill")
                        .font(.title2).foregroundStyle(.secondary)
                    Text("Nothing playing")
                        .font(.footnote).foregroundStyle(.secondary)
                    Text("Start music on your phone, TV or Mac and control it from here.")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 8)
            }
        }
        .containerBackground(for: .navigation) { Color.black }
    }
}

/// Watch login — server + account, dictation/scribble friendly.
struct WatchLoginView: View {
    @Environment(JellyfinClient.self) private var client
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var busy = false
    @State private var failed = false

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Connect to Jellyfin")
                    .font(.footnote).foregroundStyle(.secondary)
                TextField("Server", text: $server)
                TextField("User", text: $username)
                SecureField("Password", text: $password)
                if failed {
                    Text("Couldn't connect").font(.caption2).foregroundStyle(.red)
                }
                Button {
                    busy = true; failed = false
                    Task {
                        do { try await client.authenticate(server: server, username: username, password: password) }
                        catch { failed = true }
                        busy = false
                    }
                } label: {
                    if busy { ProgressView() } else { Text("Connect") }
                }
                .disabled(busy || server.isEmpty || username.isEmpty)
            }
        }
    }
}
