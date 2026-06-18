import Foundation
import AVFoundation
import SwiftUI
import Combine

#if canImport(MediaPlayer)
import MediaPlayer
#endif

@MainActor
class AudioPlayerManager: NSObject, ObservableObject {
    /// Shared instance so App Intents (Siri / Shortcuts) can drive playback outside the view tree.
    static let shared = AudioPlayerManager()

    // GAPLESS ENGINE: an AVQueuePlayer always holds the current item plus a pre-rolled "lookahead"
    // item (the next track), so when one track ends the next starts with no gap. We keep direct
    // references to those two AVPlayerItems and the lookahead's queue index, and drive everything
    // else (manual next/prev, seek, shuffle, queue edits, repeat) by re-syncing that small window.
    private var player: AVQueuePlayer?
    private var currentPlayerItem: AVPlayerItem?
    private var lookaheadItem: AVPlayerItem?
    private var lookaheadIndex: Int?

    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var currentItemObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var notificationObservers: [NSObjectProtocol] = []

    /// Set on the first `play(...)` call and reused so playback control doesn't need the API
    /// threaded through every call.
    private weak var api: JellyfinAPI?

    /// Time-observer updates are ignored until this instant (set briefly after a manual seek).
    private var seekSuppressUntil = Date.distantPast

    /// Whether the user intends playback to be running (so a freshly-loaded item auto-plays).
    private var intendedPlaying = false

    /// Playback-reporting state: the item id currently reported to Jellyfin as "playing", and a
    /// counter so the periodic time observer only scrobbles progress every ~10s.
    private var reportedItemId: String?
    private var progressTick = 0

    @Published var queue = PlaybackQueue()
    @Published var isPlaying = false
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var isLoading = false
    /// Drives the full-screen Now Playing sheet, presented once at the app's top level.
    @Published var showNowPlaying = false

    var currentItem: MediaItem? { queue.currentItem }

    override init() {
        super.init()
        configureAudioSession()
        setupRemoteControls()
        setupNotifications()
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Playback Control

    /// Start a brand-new playback context from `items`. Resets shuffle/queue state.
    func play(items: [MediaItem], from index: Int = 0, shuffled: Bool = false, api: JellyfinAPI) {
        guard !items.isEmpty else { return }
        self.api = api
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
        rebuild(at: queue.currentIndex, autoplay: true)
    }

    /// Jump to an existing item in the current queue (e.g. tapping in the Up Next list).
    func play(at index: Int) {
        guard queue.items.indices.contains(index) else { return }
        rebuild(at: index, autoplay: true)
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            intendedPlaying = false
            reportProgress(paused: true)
        } else {
            // If the track finished (queue end, repeat off), restart it from the top.
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
        // Ignore the periodic observer briefly so it doesn't report the pre-seek time.
        seekSuppressUntil = Date().addingTimeInterval(0.5)
        updateNowPlayingElapsed()
    }

    func nextTrack() {
        guard let player else { return }
        // If the next track is already pre-rolled, advance to it instantly; otherwise rebuild.
        if let n = nextIndex(after: queue.currentIndex) {
            if let look = lookaheadItem, lookaheadIndex == n {
                player.advanceToNextItem()
                didAdvance(to: look, index: n)   // sync so an immediate prev/next sees the new index
            } else {
                rebuild(at: n, autoplay: intendedPlaying || isPlaying)
            }
        }
    }

    func previousTrack() {
        if currentTime > 5 {
            seek(to: 0)
        } else if queue.currentIndex > 0 {
            rebuild(at: queue.currentIndex - 1, autoplay: intendedPlaying || isPlaying)
        } else if queue.repeatMode == .all, !queue.items.isEmpty {
            rebuild(at: queue.items.count - 1, autoplay: intendedPlaying || isPlaying)
        } else {
            seek(to: 0)
        }
    }

    func skipForward(by seconds: Double = 15) { seek(to: min(currentTime + seconds, duration)) }
    func skipBackward(by seconds: Double = 15) { seek(to: max(currentTime - seconds, 0)) }

    func toggleShuffle() { setShuffle(!queue.isShuffled) }

    func cycleRepeat() {
        queue.repeatMode.cycle()
        syncRepeatMode()
    }

    // MARK: - Scrubbing (pause playback while the user holds the playhead)

    private var wasPlayingBeforeScrub = false

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

    // MARK: - Queue editing

    func playNext(_ item: MediaItem, api: JellyfinAPI) {
        self.api = api
        guard !queue.items.isEmpty else { play(items: [item], api: api); return }
        queue.items.insert(item, at: min(queue.currentIndex + 1, queue.items.count))
        if !queue.isShuffled { queue.originalItems = queue.items }
        resyncLookahead()
    }

    func playLast(_ item: MediaItem, api: JellyfinAPI) {
        self.api = api
        guard !queue.items.isEmpty else { play(items: [item], api: api); return }
        queue.items.append(item)
        if !queue.isShuffled { queue.originalItems = queue.items }
        resyncLookahead()
    }

    /// Insert a whole set of tracks (an album/playlist) right after the current track.
    func playNext(_ items: [MediaItem], api: JellyfinAPI) {
        self.api = api
        guard !items.isEmpty else { return }
        guard !queue.items.isEmpty else { play(items: items, api: api); return }
        queue.items.insert(contentsOf: items, at: min(queue.currentIndex + 1, queue.items.count))
        if !queue.isShuffled { queue.originalItems = queue.items }
        resyncLookahead()
    }

    /// Append a whole set of tracks (an album/playlist) to the end of the queue.
    func playLast(_ items: [MediaItem], api: JellyfinAPI) {
        self.api = api
        guard !items.isEmpty else { return }
        guard !queue.items.isEmpty else { play(items: items, api: api); return }
        queue.items.append(contentsOf: items)
        if !queue.isShuffled { queue.originalItems = queue.items }
        resyncLookahead()
    }

    /// Remove an item from the Up Next list. The currently playing track can't be removed.
    func removeFromQueue(at index: Int) {
        guard queue.items.indices.contains(index), index != queue.currentIndex else { return }
        let removed = queue.items.remove(at: index)
        if index < queue.currentIndex { queue.currentIndex -= 1 }
        queue.originalItems.removeAll { $0.id == removed.id }
        resyncLookahead()
    }

    /// Stop playback entirely and clear all state (used on sign-out).
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
        // The current track keeps playing; only the pre-rolled next changes.
        resyncLookahead()
    }

    // MARK: - Gapless engine

    /// What plays after index `i` (nil = nothing to pre-roll, e.g. end of queue or repeat-one).
    private func nextIndex(after i: Int) -> Int? {
        if queue.repeatMode == .one { return nil }                       // loop handled on item end
        if i + 1 < queue.items.count { return i + 1 }
        if queue.repeatMode == .all, !queue.items.isEmpty { return 0 }    // wrap to the top
        return nil
    }

    private func makeItem(forIndex i: Int, immediate: Bool) -> AVPlayerItem? {
        guard queue.items.indices.contains(i), let url = api?.streamURL(for: queue.items[i]) else { return nil }
        let item = AVPlayerItem(url: url)
        // The immediate item starts fast on a low buffer; lookahead items keep the default
        // (automatic) buffering so they're pre-rolled and ready for a gapless hand-off.
        if immediate { item.preferredForwardBufferDuration = 1 }
        return item
    }

    /// Tear down any existing player and build a fresh queue window starting at `index`.
    private func rebuild(at index: Int, autoplay: Bool) {
        guard queue.items.indices.contains(index), let cur = makeItem(forIndex: index, immediate: true) else { return }
        reportStop()
        teardownPlayer()
        activateAudioSession()

        queue.currentIndex = index
        currentTime = 0
        duration = 0
        isLoading = true
        isPlaying = false        // fresh player — let observeStatus start it once the item is ready
        intendedPlaying = autoplay

        var items = [cur]
        currentPlayerItem = cur
        lookaheadItem = nil
        lookaheadIndex = nil
        if let n = nextIndex(after: index), let next = makeItem(forIndex: n, immediate: false) {
            items.append(next)
            lookaheadItem = next
            lookaheadIndex = n
        }

        let qp = AVQueuePlayer(items: items)
        // Let the player wait/buffer to avoid stalls — required so seeking to an unbuffered spot
        // (and gapless pre-roll of the next item) work reliably.
        qp.automaticallyWaitsToMinimizeStalling = true
        qp.actionAtItemEnd = (queue.repeatMode == .one) ? .none : .advance
        player = qp

        setupObservers(on: qp)
        observeStatus(of: cur)
        updateNowPlayingInfo()
    }

    /// Make sure the next track is pre-rolled into the queue for a gapless hand-off.
    private func ensureLookahead() {
        guard let player, lookaheadItem == nil else { return }
        guard let n = nextIndex(after: queue.currentIndex),
              let item = makeItem(forIndex: n, immediate: false),
              let cur = currentPlayerItem,
              player.canInsert(item, after: cur) else { return }
        player.insert(item, after: cur)
        lookaheadItem = item
        lookaheadIndex = n
    }

    /// Drop the pre-rolled next and re-derive it (after a queue mutation / shuffle / repeat change).
    private func resyncLookahead() {
        guard let player, let cur = currentPlayerItem else { return }
        for item in player.items() where item !== cur { player.remove(item) }
        lookaheadItem = nil
        lookaheadIndex = nil
        ensureLookahead()
    }

    private func syncRepeatMode() {
        player?.actionAtItemEnd = (queue.repeatMode == .one) ? .none : .advance
        resyncLookahead()
    }

    private func setupObservers(on qp: AVQueuePlayer) {
        // Periodic time updates (fires on .main, so run synchronously on the main actor).
        timeObserver = qp.addPeriodicTimeObserver(
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

        // The current item changing means the player advanced to the pre-rolled next (gapless),
        // or ran out of items. KVO can fire off the main thread, so hop to the main actor.
        currentItemObservation = qp.observe(\.currentItem, options: [.new]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.currentItemChanged() }
        }

        // For repeat-one we don't pre-roll a next item; loop the current one when it ends.
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self,
                      self.queue.repeatMode == .one,
                      let item = note.object as? AVPlayerItem,
                      item === self.currentPlayerItem else { return }
                self.player?.seek(to: .zero)
                self.player?.play()
                self.isPlaying = true
                self.currentTime = 0
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

    private func currentItemChanged() {
        guard let player else { return }
        guard let cur = player.currentItem else {
            handleQueueEnd()
            return
        }
        guard cur !== currentPlayerItem else { return }   // no real change (e.g. handled by a sync skip)

        if cur === lookaheadItem, let n = lookaheadIndex {
            didAdvance(to: cur, index: n)       // gapless advance into the pre-rolled next track
        } else {
            // Unexpected item (defensive) — adopt it without losing the queue index.
            currentPlayerItem = cur
            observeStatus(of: cur)
        }
    }

    /// Commit a hand-off to `item` (queue index `index`) — used by both the gapless auto-advance and
    /// a manual next, so the queue index updates synchronously and stays consistent.
    private func didAdvance(to item: AVPlayerItem, index: Int) {
        reportStop()                           // close out the previous track at its current position
        currentPlayerItem = item
        lookaheadItem = nil
        lookaheadIndex = nil
        queue.currentIndex = index
        currentTime = 0
        duration = readyDuration(item)
        reportStart()
        updateNowPlayingInfo()
        observeStatus(of: item)                // refresh duration once fully ready
        ensureLookahead()                      // pre-roll the following track
    }

    private func handleQueueEnd() {
        // Whole queue finished (repeat off) → reset to the top, paused and ready to replay.
        reportStop()
        isPlaying = false
        intendedPlaying = false
        queue.currentIndex = 0
        rebuild(at: 0, autoplay: false)
    }

    private func readyDuration(_ item: AVPlayerItem) -> Double {
        let d = item.duration.seconds
        return (d.isFinite && !d.isNaN && d > 0) ? d : 0
    }

    private func teardownPlayer() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        statusObservation?.invalidate(); statusObservation = nil
        currentItemObservation?.invalidate(); currentItemObservation = nil
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = nil
        player?.pause()
        player?.removeAllItems()
        player = nil
        currentPlayerItem = nil
        lookaheadItem = nil
        lookaheadIndex = nil
    }

    // MARK: - Audio Session

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
        guard let info = note.userInfo,
              let raw = info[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw) else { return }
        // Headphones/Bluetooth disconnected → pause, matching system music behavior.
        if reason == .oldDeviceUnavailable, isPlaying {
            player?.pause()
            isPlaying = false
            intendedPlaying = false
            updateNowPlayingRate()
        }
    }
#endif

    // MARK: - Jellyfin Playback Reporting (scrobble play/progress/stop)

    private var currentTicks: Int64 { Int64(max(0, currentTime) * 10_000_000) }

    private func reportStart() {
        guard let api, let id = currentItem?.id else { return }
        reportedItemId = id
        let ticks = currentTicks
        Task { await api.reportPlaybackStart(itemId: id, positionTicks: ticks) }
    }

    private func reportProgress(paused: Bool) {
        guard let api, let id = reportedItemId else { return }
        let ticks = currentTicks
        Task { await api.reportPlaybackProgress(itemId: id, positionTicks: ticks, isPaused: paused) }
    }

    private func reportStop() {
        guard let api, let id = reportedItemId else { return }
        reportedItemId = nil
        let ticks = currentTicks
        Task { await api.reportPlaybackStopped(itemId: id, positionTicks: ticks) }
    }

    // MARK: - Now Playing Info

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
        guard let url = api?.artworkURL(for: item, size: 600) else { return }
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

    // MARK: - Remote Controls

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

// MARK: - Duration Formatting

extension Double {
    var formattedDuration: String {
        guard isFinite && !isNaN && self >= 0 else { return "0:00" }
        let total = Int(self)
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
