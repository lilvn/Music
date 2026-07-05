import Foundation
import Observation

/// Cross-device "shared Now Playing" — Spotify-Connect style, built entirely on Jellyfin's Sessions
/// API (no custom server):
///
/// - **Be controllable:** posts capabilities and listens on the server WebSocket for Playstate/Play
///   commands, routing them into the local `Player`. Any device (or Jellyfin Web) can drive this one.
/// - **See the others:** polls `/Sessions` for the same user's OTHER sessions and publishes the most
///   relevant one as `remote` — its track, position, queue, and paused state.
/// - **Control the others:** transport commands are POSTs to `/Sessions/{id}/Playing/…`.
/// - **Transfer here:** pulls the remote queue + position onto this device and stops the remote.
@MainActor
@Observable
final class SessionHub {
    static let shared = SessionHub()

    /// The most relevant OTHER session of this user with something playing (nil when none).
    private(set) var remote: RemoteSession?
    /// True while `transferHere()` is pulling a session over.
    private(set) var transferring = false
    /// This device auto-paused because another device took over playback (most-recent start wins).
    /// The UI shows the remote mirror while this is set; playing locally again clears it.
    private(set) var yieldedToRemote = false

    @ObservationIgnored private weak var client: JellyfinClient?
    @ObservationIgnored private weak var player: Player?
    @ObservationIgnored private var socketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?
    /// When THIS device last started real playback — the takeover rule's tiebreaker clock.
    @ObservationIgnored private var lastLocalPlayStart = Date.distantPast
    /// Last poll's remote snapshot, for detecting a REMOTE play-start between polls.
    @ObservationIgnored private var prevRemoteKey: (session: String, itemId: String, isPaused: Bool)?

    struct RemoteSession: Equatable {
        let id: String
        let deviceId: String
        let deviceName: String
        let item: MediaItem
        let positionSeconds: Double
        let isPaused: Bool
        let queueIds: [String]
        /// The remote queue with full metadata (server's NowPlayingQueueFullItems) — render-ready.
        let queueItems: [MediaItem]
        /// Extrapolation anchor: the position at `capturedAt`, already corrected for how stale the
        /// server's snapshot was (positionTicks only advances when the target reports, ~5s cadence).
        let basePosition: Double
        let capturedAt: Date
        let durationSeconds: Double

        /// The live playhead: the anchored position, advancing in real time while not paused.
        func livePosition(at now: Date) -> Double {
            guard !isPaused else { return basePosition }
            let raw = basePosition + now.timeIntervalSince(capturedAt)
            return durationSeconds > 0 ? min(raw, durationSeconds) : raw
        }

        // Equality stays coarse (id/track/pause) — the playhead is driven by TimelineView, not by
        // republishes, so onChange(of: remote) consumers don't churn every poll.
        static func == (l: Self, r: Self) -> Bool {
            l.id == r.id && l.item.id == r.item.id && l.isPaused == r.isPaused
        }
    }

    private init() {}

    // MARK: - Server-clock parsing

    private static let isoParser: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Jellyfin stamps 7 fractional digits; ISO8601DateFormatter reliably parses 3 — trim first.
    private static func parseServerDate(_ s: String?) -> Date? {
        guard var s, !s.isEmpty else { return nil }
        if let dot = s.firstIndex(of: ".") {
            var end = s.index(after: dot)
            while end < s.endIndex, s[end].isNumber { end = s.index(after: end) }
            s = String(s[..<dot]) + "." + s[s.index(after: dot)..<end].prefix(3) + String(s[end...])
        }
        guard let d = isoParser.date(from: s), d.timeIntervalSince1970 > 0 else { return nil }
        return d   // nil for the year-1 "never reported" sentinel
    }

    // MARK: - Lifecycle

    func start(client: JellyfinClient, player: Player) {
        self.client = client
        self.player = player
        restart()
    }

    /// (Re)connect for the current login — call at launch and whenever the signed-in user changes.
    func restart() {
        stop()
        guard let client, client.isAuthenticated else { return }
        Task { await client.postCapabilities() }
        openSocket()
        pollTask = Task { [weak self] in
            // Let the first layout settle before the first poll can flip `remote` (and with it the
            // mini-bar/transfer UI) — a state flip landing mid-first-layout is crash bait on tvOS.
            try? await Task.sleep(for: .seconds(2))
            while !Task.isCancelled {
                await self?.refreshSessions()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    func stop() {
        pollTask?.cancel(); pollTask = nil
        keepAliveTask?.cancel(); keepAliveTask = nil
        socketTask?.cancel(with: .goingAway, reason: nil); socketTask = nil
        remote = nil
    }

    /// App came to the foreground: the OS likely killed the socket while suspended. Re-declare
    /// capabilities, refresh the session picture NOW (not on the next poll tick), and probe the
    /// socket — a dead one errors on send and gets reopened immediately instead of after the next
    /// receive failure + backoff.
    func foregrounded() {
        guard let client, client.isAuthenticated else { return }
        Task {
            await client.postCapabilities()
            await refreshSessions()
        }
        if let task = socketTask {
            task.send(.string(#"{"MessageType":"KeepAlive"}"#)) { [weak self] error in
                guard error != nil else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.socketTask === task else { return }
                    self.socketTask?.cancel(with: .goingAway, reason: nil)
                    self.socketTask = nil
                    self.openSocket()
                }
            }
        } else {
            openSocket()
        }
    }

    // MARK: - Seeing the other sessions

    private func refreshSessions() async {
        guard let client, client.isAuthenticated else { return }
        let sessions = (try? await client.fetchSessions()) ?? []
        let mine = sessions.filter {
            $0.userId == client.userId &&
            $0.deviceId != JellyfinClient.deviceId &&
            $0.nowPlayingItem != nil
        }
        // Prefer the actively-playing session; break ties by most recent activity.
        let best = mine.sorted { a, b in
            let ap = a.playState?.isPaused ?? true
            let bp = b.playState?.isPaused ?? true
            if ap != bp { return !ap }
            return (a.lastActivityDate ?? "") > (b.lastActivityDate ?? "")
        }.first

        // Server-now anchor WITHOUT trusting the local clock: our own session's LastActivityDate was
        // just refreshed by this very fetch, so it ≈ the server's current time.
        let serverNow = sessions.first { $0.deviceId == JellyfinClient.deviceId }
            .flatMap { Self.parseServerDate($0.lastActivityDate) }

        let previous = remote
        let now = Date()
        let newRemote = best.flatMap { s -> RemoteSession? in
            guard let item = s.nowPlayingItem else { return nil }
            let reported = Double(s.playState?.positionTicks ?? 0) / 10_000_000
            let paused = s.playState?.isPaused ?? false
            let duration = item.durationSeconds ?? 0

            // The server's PositionTicks only advances when the target reports (~5s cadence) — correct
            // the snapshot's staleness by how long ago (in SERVER time) the target last checked in.
            var base = reported
            if !paused, let serverNow, let checkIn = Self.parseServerDate(s.lastPlaybackCheckIn) {
                let stale = serverNow.timeIntervalSince(checkIn)
                if stale > 0, stale < 60 { base += stale }
            }
            if duration > 0 { base = min(base, duration) }

            // Anti-jitter: if we were already extrapolating this same track and the fresh anchor lands
            // within 1.5s of where our extrapolation sits, keep the smooth value (a snap only happens
            // on real seeks/skips).
            if let previous, previous.id == s.id, previous.item.id == item.id, !paused, !previous.isPaused {
                let running = previous.livePosition(at: now)
                if abs(running - base) < 1.5 { base = running }
            }

            return RemoteSession(
                id: s.id,
                deviceId: s.deviceId ?? "",
                deviceName: s.deviceName ?? "another device",
                item: item,
                positionSeconds: reported,
                isPaused: paused,
                queueIds: s.nowPlayingQueue?.map(\.id) ?? [],
                queueItems: s.fullQueueItems,
                basePosition: base,
                capturedAt: now,
                durationSeconds: duration
            )
        }
        remote = newRemote

        // ---- Exclusive playback (passive path — catches devices whose socket is dead) ----
        // A REMOTE play-start while WE are playing: the older playback yields. The 10s grace window
        // means the device that just started (it also proactively paused the other) never yields.
        if let r = newRemote, !r.isPaused {
            let remoteStarted = prevRemoteKey == nil
                || prevRemoteKey!.session != r.id
                || prevRemoteKey!.isPaused
                || prevRemoteKey!.itemId != r.item.id
            if remoteStarted, let player, player.isPlaying,
               now.timeIntervalSince(lastLocalPlayStart) > 10 {
                player.pause()
                yieldedToRemote = true
            }
        }
        prevRemoteKey = newRemote.map { ($0.id, $0.item.id, $0.isPaused) }
        if newRemote == nil { yieldedToRemote = false }

#if os(iOS)
        // Keep the remote track on this phone's lock screen while it plays elsewhere.
        if let player { RemoteLockScreenBridge.shared.update(remote: newRemote, player: player, client: client) }
#endif
    }

    // MARK: - Exclusive playback (active path)

    /// Called from Player.reportStart() — the single choke point every real local start passes
    /// through. Starting here means THIS device wins: tell the currently-playing other device to
    /// pause (it flips to mirroring us).
    func noteLocalPlayStart() {
        lastLocalPlayStart = Date()
        yieldedToRemote = false
#if os(iOS)
        // Local playback owns the lock screen again, immediately (not on the next poll).
        if let player { RemoteLockScreenBridge.shared.disengage(player: player) }
#endif
        if let client, let r = remote, !r.isPaused {
            Task { await client.sendPlaystate(sessionId: r.id, command: "Pause") }
        }
    }

    // MARK: - Controlling the other sessions

    func playPauseRemote() { sendRemote("PlayPause") }
    func nextRemote() { sendRemote("NextTrack") }
    func previousRemote() { sendRemote("PreviousTrack") }
    func stopRemote() { sendRemote("Stop") }

    private func sendRemote(_ command: String) {
        guard let client, let r = remote else { return }
        Task {
            await client.sendPlaystate(sessionId: r.id, command: command)
            try? await Task.sleep(for: .milliseconds(600))   // give the target a beat to report back
            await refreshSessions()
        }
    }

    /// Jump the REMOTE session to queue position `index` — resends its own queue with a start index
    /// (the receiver's handlePlay honors StartIndex).
    func playRemote(at index: Int) {
        guard let client, let r = remote else { return }
        let ids = r.queueIds.isEmpty ? r.queueItems.map(\.id) : r.queueIds
        guard ids.indices.contains(index) else { return }
        Task {
            await client.sendPlay(sessionId: r.id, itemIds: ids, playCommand: "PlayNow", startIndex: index)
            try? await Task.sleep(for: .milliseconds(600))
            await refreshSessions()
        }
    }

    /// Scrub the REMOTE session's playhead.
    func seekRemote(to seconds: Double) {
        guard let client, let r = remote else { return }
        Task {
            await client.sendPlaystate(sessionId: r.id, command: "Seek",
                                       seekTicks: Int64(seconds * 10_000_000))
            try? await Task.sleep(for: .milliseconds(600))
            await refreshSessions()
        }
    }

    /// Queue tracks onto the REMOTE session (Play Next / Play Last on another device).
    func enqueueRemote(_ items: [MediaItem], next: Bool) {
        guard let client, let r = remote, !items.isEmpty else { return }
        Task {
            await client.sendPlay(sessionId: r.id, itemIds: items.map(\.id),
                                  playCommand: next ? "PlayNext" : "PlayLast")
        }
    }

    /// Pull the remote session's queue + position onto THIS device, then stop the remote — the
    /// "Transfer to this device" action.
    func transferHere() {
        guard let client, let player, let r = remote, !transferring else { return }
        guard r.item.type != "MusicVideo" else { return }   // a video can't transfer as local audio
        transferring = true
        Task {
            let ids = r.queueIds.isEmpty ? [r.item.id] : r.queueIds
            var items = (try? await client.fetchItems(ids: ids)) ?? []
            if items.isEmpty { items = [r.item] }   // metadata fetch failed → play at least the track
            // The server doesn't guarantee Ids-query order — restore the remote queue's order.
            let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let ordered = ids.compactMap { byId[$0] }
            let final = ordered.isEmpty ? items : ordered
            let index = final.firstIndex { $0.id == r.item.id } ?? 0
            await client.sendPlaystate(sessionId: r.id, command: "Stop")
            player.play(items: final, from: index, startingAt: r.positionSeconds)
            remote = nil
            transferring = false
        }
    }

    // MARK: - Being controllable (WebSocket)

    private func openSocket() {
        guard let url = client?.webSocketURL else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        socketTask = task
        task.resume()
        receive(on: task)

        keepAliveTask?.cancel()
        keepAliveTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                self?.sendSocket(#"{"MessageType":"KeepAlive"}"#)
            }
        }
    }

    private func sendSocket(_ text: String) {
        socketTask?.send(.string(text)) { _ in }
    }

    private func receive(on task: URLSessionWebSocketTask) {
        task.receive { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.socketTask === task else { return }
                switch result {
                case .success(let message):
                    self.handle(message)
                    self.receive(on: task)
                case .failure:
                    // Dropped (network change, server restart) — reconnect with a delay.
                    try? await Task.sleep(for: .seconds(5))
                    guard self.socketTask === task, self.client?.isAuthenticated == true else { return }
                    self.openSocket()
                }
            }
        }
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        guard case .string(let text) = message,
              let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["MessageType"] as? String else { return }

        switch type {
        case "ForceKeepAlive", "KeepAlive":
            sendSocket(#"{"MessageType":"KeepAlive"}"#)
        case "Playstate":
            handlePlaystate(json["Data"] as? [String: Any] ?? [:])
        case "Play":
            handlePlay(json["Data"] as? [String: Any] ?? [:])
        default:
            break
        }
    }

    private func handlePlaystate(_ data: [String: Any]) {
        guard let player else { return }
        let command = data["Command"] as? String

#if os(tvOS)
        // A video (direct playlist OR a song's matched music video) runs its own AVPlayer —
        // route transport there.
        if TVVideoController.shared.ownsPlayback {
            TVVideoController.shared.handleRemote(command ?? "")
            return
        }
#endif
        switch command {
        case "PlayPause":     player.togglePlayPause()
        case "Pause":
            // Takeover race: if BOTH devices pressed play within seconds, both sent the other a
            // Pause — without a tiebreak both would stop. Deterministic winner: within the 3s race
            // window the LOWER deviceId keeps playing and ignores the pause.
            if Date().timeIntervalSince(lastLocalPlayStart) < 3,
               let rid = remote?.deviceId, JellyfinClient.deviceId < rid {
                return
            }
            player.pause()
            if remote != nil, !(remote?.isPaused ?? true) { yieldedToRemote = true }
        case "Unpause":       player.resume()
        case "NextTrack":     player.nextTrack()
        case "PreviousTrack": player.previousTrack()
        case "Stop":          player.stop()
        case "Seek":
            let ticks = (data["SeekPositionTicks"] as? Int64)
                ?? (data["SeekPositionTicks"] as? Int).map(Int64.init)
                ?? (data["SeekPositionTicks"] as? Double).map(Int64.init)
            if let ticks { player.seek(to: Double(ticks) / 10_000_000) }
        default:
            break
        }
    }

    /// "Play these items here" — sent by another device (or Jellyfin Web) casting TO this one.
    /// PlayNow replaces the queue; PlayNext/PlayLast ENQUEUE without touching what's playing.
    private func handlePlay(_ data: [String: Any]) {
        guard let client, let player,
              let ids = data["ItemIds"] as? [String], !ids.isEmpty else { return }
        let command = data["PlayCommand"] as? String ?? "PlayNow"
        let startIndex = data["StartIndex"] as? Int ?? 0
        let ticks = (data["StartPositionTicks"] as? Int64)
            ?? (data["StartPositionTicks"] as? Int).map(Int64.init)
            ?? 0
        Task {
            let items = (try? await client.fetchItems(ids: ids)) ?? []
            guard !items.isEmpty else { return }
            let byId = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let ordered = ids.compactMap { byId[$0] }
            let final = ordered.isEmpty ? items : ordered
            switch command {
            case "PlayNext": player.playNext(final)
            case "PlayLast": player.playLast(final)
            default:
                player.play(items: final,
                            from: min(max(0, startIndex), final.count - 1),
                            startingAt: Double(ticks) / 10_000_000)
            }
        }
    }
}
