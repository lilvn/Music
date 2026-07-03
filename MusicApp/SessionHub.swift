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

    @ObservationIgnored private weak var client: JellyfinClient?
    @ObservationIgnored private weak var player: Player?
    @ObservationIgnored private var socketTask: URLSessionWebSocketTask?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var keepAliveTask: Task<Void, Never>?

    struct RemoteSession: Equatable {
        let id: String
        let deviceName: String
        let item: MediaItem
        let positionSeconds: Double
        let isPaused: Bool
        let queueIds: [String]

        static func == (l: Self, r: Self) -> Bool {
            l.id == r.id && l.item.id == r.item.id && l.isPaused == r.isPaused
        }
    }

    private init() {}

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
        remote = best.flatMap { s in
            guard let item = s.nowPlayingItem else { return nil }
            return RemoteSession(
                id: s.id,
                deviceName: s.deviceName ?? "another device",
                item: item,
                positionSeconds: Double(s.playState?.positionTicks ?? 0) / 10_000_000,
                isPaused: s.playState?.isPaused ?? false,
                queueIds: s.nowPlayingQueue?.map(\.id) ?? []
            )
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

    /// Pull the remote session's queue + position onto THIS device, then stop the remote — the
    /// "Transfer to this device" action.
    func transferHere() {
        guard let client, let player, let r = remote, !transferring else { return }
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
        switch data["Command"] as? String {
        case "PlayPause":     player.togglePlayPause()
        case "Pause":         player.pause()
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
    private func handlePlay(_ data: [String: Any]) {
        guard let client, let player,
              let ids = data["ItemIds"] as? [String], !ids.isEmpty else { return }
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
            player.play(items: final,
                        from: min(max(0, startIndex), final.count - 1),
                        startingAt: Double(ticks) / 10_000_000)
        }
    }
}
