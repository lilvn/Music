import Foundation
import AVFoundation
import Observation

#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// Audio playback engine. PHASE 1: a single `AVPlayer` that advances on item-end. The public API
/// is final so Phase 2 can swap in the gapless `AVQueuePlayer` lookahead engine with zero call-site
/// changes. The `JellyfinClient` is stored at init, so play methods take no `api:` parameter.
@MainActor
@Observable
final class Player {
    /// Shared instance so App Intents (Siri / Shortcuts) can drive playback outside the view tree.
    static let shared = Player(client: .shared)

    // Observable UI state.
    var queue = PlaybackQueue()
    var isPlaying = false
    var currentTime: Double = 0
    var duration: Double = 0
    var isLoading = false
    /// Drives the full Now Playing presentation, shown once at the app's top level.
    var showNowPlaying = false
    /// Name of the current audio output (e.g. "iPhone", "AirPods Pro", an AirPlay device).
    var outputRouteName = "iPhone"

    var currentItem: MediaItem? { queue.currentItem }

    @ObservationIgnored private let client: JellyfinClient
    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var currentPlayerItem: AVPlayerItem?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var notificationObservers: [NSObjectProtocol] = []

    /// Whether the user intends playback to be running (so a freshly-loaded item auto-plays).
    @ObservationIgnored private var intendedPlaying = false
    /// Time-observer updates are ignored until this instant (set briefly after a manual seek).
    @ObservationIgnored private var seekSuppressUntil = Date.distantPast
    /// The item id currently reported to Jellyfin as "playing", + a counter to throttle progress.
    @ObservationIgnored private var reportedItemId: String?
    @ObservationIgnored private var progressTick = 0
    @ObservationIgnored private var wasPlayingBeforeScrub = false

    init(client: JellyfinClient) {
        self.client = client
        configureAudioSession()
        setupRemoteControls()
        setupNotifications()
        updateOutputRoute()
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public playback control

    /// Start a brand-new playback context from `items`. Resets shuffle/queue state.
    func play(items: [MediaItem], from index: Int = 0, shuffled: Bool = false) {
        guard !items.isEmpty else { return }
        queue.originalItems = items
        if shuffled {
            queue.items = items.shuffled()
            queue.currentIndex = 0
            queue.isShuffled = true
        } else {
            queue.items = items
            queue.currentIndex = min(max(index, 0), items.count - 1)
            queue.isShuffled = false
        }
        loadAndPlay(at: queue.currentIndex, autoplay: true)
    }

    /// Jump to an existing item in the current queue (e.g. tapping in the Up Next list).
    func play(at index: Int) {
        guard queue.items.indices.contains(index) else { return }
        loadAndPlay(at: index, autoplay: true)
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            intendedPlaying = false
            reportProgress(paused: true)
        } else {
            if duration > 0, currentTime >= duration - 0.5 { seek(to: 0) }
            player.play()
            isPlaying = true
            intendedPlaying = true
            if reportedItemId == nil { reportStart() } else { reportProgress(paused: false) }
        }
        updateNowPlayingRate()
    }

    func seek(to time: Double) {
        let clamped = duration > 0 ? min(max(time, 0), duration) : max(time, 0)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        seekSuppressUntil = Date().addingTimeInterval(0.5)
        updateNowPlayingElapsed()
    }

    func nextTrack() {
        guard let n = nextIndex(after: queue.currentIndex) else { return }
        loadAndPlay(at: n, autoplay: intendedPlaying || isPlaying)
    }

    func previousTrack() {
        if currentTime > 5 {
            seek(to: 0)
        } else if queue.currentIndex > 0 {
            loadAndPlay(at: queue.currentIndex - 1, autoplay: intendedPlaying || isPlaying)
        } else if queue.repeatMode == .all, !queue.items.isEmpty {
            loadAndPlay(at: queue.items.count - 1, autoplay: intendedPlaying || isPlaying)
        } else {
            seek(to: 0)
        }
    }

    func skipForward(by seconds: Double = 15) { seek(to: min(currentTime + seconds, duration)) }
    func skipBackward(by seconds: Double = 15) { seek(to: max(currentTime - seconds, 0)) }

    func toggleShuffle() { setShuffle(!queue.isShuffled) }

    func cycleRepeat() { queue.repeatMode.cycle() }

    func stop() {
        reportStop()
        teardownPlayer()
        queue = PlaybackQueue()
        isPlaying = false
        intendedPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        clearNowPlayingInfo()
    }

    // MARK: - Scrubbing (pause while the user holds the playhead)

    func beginScrubbing() {
        wasPlayingBeforeScrub = isPlaying
        if isPlaying {
            player?.pause()
            isPlaying = false
            updateNowPlayingRate()
        }
    }

    func endScrubbing(to time: Double) {
        seek(to: time)
        if wasPlayingBeforeScrub {
            player?.play()
            isPlaying = true
            updateNowPlayingRate()
        }
        wasPlayingBeforeScrub = false
        reportProgress(paused: !isPlaying)
    }

    // MARK: - Shuffle

    private func setShuffle(_ on: Bool) {
        guard on != queue.isShuffled else { return }
        let current = queue.currentItem
        queue.isShuffled = on
        if on {
            guard let current else { return }
            var rest = queue.originalItems.filter { $0.id != current.id }
            rest.shuffle()
            queue.items = [current] + rest
            queue.currentIndex = 0
        } else {
            queue.items = queue.originalItems
            if let current, let idx = queue.items.firstIndex(where: { $0.id == current.id }) {
                queue.currentIndex = idx
            }
        }
        // The current track keeps playing; only the upcoming order changes.
    }

    // MARK: - Engine (single-player; Phase 2 swaps this for the gapless queue)

    /// What plays after index `i` (nil = nothing, e.g. end of queue or repeat-one).
    private func nextIndex(after i: Int) -> Int? {
        if queue.repeatMode == .one { return nil }                      // loop handled on item end
        if i + 1 < queue.items.count { return i + 1 }
        if queue.repeatMode == .all, !queue.items.isEmpty { return 0 }   // wrap to the top
        return nil
    }

    private func loadAndPlay(at index: Int, autoplay: Bool) {
        guard queue.items.indices.contains(index),
              let url = client.streamURL(for: queue.items[index]) else { return }
        reportStop()

        queue.currentIndex = index
        currentTime = 0
        duration = 0
        isLoading = true
        isPlaying = false           // observeStatus starts it once the item is ready
        intendedPlaying = autoplay

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 1     // start fast on a low buffer
        currentPlayerItem = item
        observeEnd(of: item)

        activateAudioSession()
        if let player {
            player.replaceCurrentItem(with: item)
        } else {
            let p = AVPlayer(playerItem: item)
            p.automaticallyWaitsToMinimizeStalling = true
            player = p
            addTimeObserver(to: p)
        }
        observeStatus(of: item)
        updateNowPlayingInfo()
    }

    private func addTimeObserver(to player: AVPlayer) {
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                if Date() < self.seekSuppressUntil { return }
                self.currentTime = time.seconds
                if let d = self.player?.currentItem?.duration.seconds, d.isFinite, !d.isNaN, d > 0 {
                    self.duration = d
                }
                self.updateNowPlayingElapsed()
                self.progressTick += 1
                if self.progressTick % 20 == 0 { self.reportProgress(paused: false) }   // ~every 10s
            }
        }
    }

    private func observeStatus(of item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.new, .initial]) { [weak self] it, _ in
            Task { @MainActor [weak self] in
                guard let self, self.currentPlayerItem === it else { return }
                switch it.status {
                case .readyToPlay:
                    self.isLoading = false
                    let d = it.duration.seconds
                    if d.isFinite, !d.isNaN, d > 0 { self.duration = d }
                    if self.intendedPlaying, !self.isPlaying {
                        self.player?.play()
                        self.isPlaying = true
                        if self.reportedItemId == nil { self.reportStart() }
                        self.updateNowPlayingRate()
                    }
                case .failed:
                    self.isLoading = false
                default:
                    break
                }
            }
        }
    }

    private func observeEnd(of item: AVPlayerItem) {
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleItemEnd() }
        }
    }

    private func handleItemEnd() {
        if queue.repeatMode == .one {
            seek(to: 0)
            player?.play()
            isPlaying = true
            return
        }
        if let n = nextIndex(after: queue.currentIndex) {
            loadAndPlay(at: n, autoplay: true)
        } else {
            // Whole queue finished → reset to the top, paused and ready to replay.
            reportStop()
            isPlaying = false
            intendedPlaying = false
            loadAndPlay(at: 0, autoplay: false)
        }
    }

    private func teardownPlayer() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        statusObservation?.invalidate(); statusObservation = nil
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        currentPlayerItem = nil
    }

    // MARK: - Audio session

    private func configureAudioSession() {
#if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
#endif
    }

    private func activateAudioSession() {
#if os(iOS) || os(tvOS)
        try? AVAudioSession.sharedInstance().setActive(true)
#endif
    }

    private func updateOutputRoute() {
#if os(iOS) || os(tvOS)
        outputRouteName = AVAudioSession.sharedInstance().currentRoute.outputs.first?.portName ?? "iPhone"
#endif
    }

    private func setupNotifications() {
#if os(iOS) || os(tvOS)
        let nc = NotificationCenter.default
        notificationObservers.append(
            nc.addObserver(forName: AVAudioSession.interruptionNotification,
                           object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in self?.handleInterruption(note) }
            }
        )
        notificationObservers.append(
            nc.addObserver(forName: AVAudioSession.routeChangeNotification,
                           object: nil, queue: .main) { [weak self] note in
                Task { @MainActor [weak self] in self?.handleRouteChange(note) }
            }
        )
#endif
    }

#if os(iOS) || os(tvOS)
    private func handleInterruption(_ note: Notification) {
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            if isPlaying {
                player?.pause()
                isPlaying = false
                reportProgress(paused: true)
                updateNowPlayingRate()
            }
        case .ended:
            if let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optsRaw).contains(.shouldResume),
               player != nil {
                activateAudioSession()
                player?.play()
                isPlaying = true
                intendedPlaying = true
                reportProgress(paused: false)
                updateNowPlayingRate()
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(_ note: Notification) {
        updateOutputRoute()
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Headphones / Bluetooth disconnected → pause, matching system music behaviour.
        if reason == .oldDeviceUnavailable, isPlaying {
            player?.pause()
            isPlaying = false
            intendedPlaying = false
            updateNowPlayingRate()
        }
    }
#endif

    // MARK: - Jellyfin playback reporting (scrobble play / progress / stop)

    private var currentTicks: Int64 { Int64(max(0, currentTime) * 10_000_000) }

    private func reportStart() {
        guard let id = currentItem?.id else { return }
        reportedItemId = id
        let ticks = currentTicks
        Task { await client.reportPlaybackStart(itemId: id, positionTicks: ticks) }
    }

    private func reportProgress(paused: Bool) {
        guard let id = reportedItemId else { return }
        let ticks = currentTicks
        Task { await client.reportPlaybackProgress(itemId: id, positionTicks: ticks, isPaused: paused) }
    }

    private func reportStop() {
        guard let id = reportedItemId else { return }
        reportedItemId = nil
        let ticks = currentTicks
        Task { await client.reportPlaybackStopped(itemId: id, positionTicks: ticks) }
    }

    // MARK: - Now Playing info (lock screen / Control Center)

    private func updateNowPlayingInfo() {
#if canImport(MediaPlayer)
        guard let item = currentItem else { return }
        let info: [String: Any] = [
            MPMediaItemPropertyTitle: item.name,
            MPMediaItemPropertyArtist: item.primaryArtist,
            MPMediaItemPropertyAlbumTitle: item.album ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: currentTime,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

#if os(iOS) || os(tvOS)
        guard let url = client.artworkURL(for: item, size: 600) else { return }
        let trackId = item.id
        Task { [weak self] in
            guard let (data, _) = try? await URLSession.shared.data(from: url),
                  let image = UIImage(data: data) else { return }
            await MainActor.run {
                guard let self, self.currentItem?.id == trackId else { return }
                var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                current[MPMediaItemPropertyArtwork] =
                    MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                MPNowPlayingInfoCenter.default().nowPlayingInfo = current
            }
        }
#endif
#endif
    }

    private func updateNowPlayingRate() {
#if canImport(MediaPlayer)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyPlaybackRate] = isPlaying ? 1.0 : 0.0
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
#endif
    }

    private func updateNowPlayingElapsed() {
#if canImport(MediaPlayer)
        var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = currentTime
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
#endif
    }

    private func clearNowPlayingInfo() {
#if canImport(MediaPlayer)
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
#endif
    }

    // MARK: - Remote controls (lock screen / headphones)

    private func setupRemoteControls() {
#if canImport(MediaPlayer) && (os(iOS) || os(tvOS) || os(watchOS))
        let cc = MPRemoteCommandCenter.shared()

        cc.playCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .noSuchContent }
            self.player?.play()
            self.isPlaying = true
            self.intendedPlaying = true
            self.updateNowPlayingRate()
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .noSuchContent }
            self.player?.pause()
            self.isPlaying = false
            self.intendedPlaying = false
            self.updateNowPlayingRate()
            return .success
        }
        cc.togglePlayPauseCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .noSuchContent }
            self.togglePlayPause()
            return .success
        }
        cc.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            self?.seek(to: e.positionTime)
            return .success
        }
        cc.nextTrackCommand.addTarget { [weak self] _ in
            guard let self, self.nextIndex(after: self.queue.currentIndex) != nil else { return .noSuchContent }
            self.nextTrack()
            return .success
        }
        cc.previousTrackCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .noSuchContent }
            self.previousTrack()
            return .success
        }
        cc.nextTrackCommand.isEnabled = true
        cc.previousTrackCommand.isEnabled = true
#endif
    }
}
