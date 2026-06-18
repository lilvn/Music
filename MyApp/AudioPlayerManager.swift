import Foundation
import AVFoundation
import SwiftUI
import Combine

#if canImport(MediaPlayer)
import MediaPlayer
#endif

@MainActor
class AudioPlayerManager: NSObject, ObservableObject {
    private var player: AVPlayer?
    private var timeObserver: Any?
    private var statusObservation: NSKeyValueObservation?
    private var endObserver: NSObjectProtocol?
    private var notificationObservers: [NSObjectProtocol] = []

    /// Set on the first `play(...)` call and reused so playback control (next/previous,
    /// track-end advance, remote commands) doesn't need the API threaded through every call.
    private weak var api: JellyfinAPI?

    /// Time-observer updates are ignored until this instant (set briefly after a manual seek).
    private var seekSuppressUntil = Date.distantPast

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
        loadAndPlay()
    }

    /// Jump to an existing item in the current queue (e.g. tapping in the Up Next list)
    /// without rebuilding the queue or disturbing shuffle state.
    func play(at index: Int) {
        guard queue.items.indices.contains(index) else { return }
        queue.currentIndex = index
        loadAndPlay()
    }

    func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            // If the track finished (queue end, repeat off), restart it from the top.
            if duration > 0, currentTime >= duration - 0.5 { seek(to: 0) }
            player.play()
            isPlaying = true
        }
        updateNowPlayingRate()
    }

    func seek(to time: Double) {
        let clamped = duration > 0 ? min(max(time, 0), duration) : max(time, 0)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        // Ignore the periodic observer briefly so it doesn't report the pre-seek time and
        // make the playhead jump back before the seek settles.
        seekSuppressUntil = Date().addingTimeInterval(0.5)
        updateNowPlayingElapsed()
    }

    func nextTrack() {
        guard queue.hasNext else { return }
        queue.advanceToNext()
        loadAndPlay()
    }

    func previousTrack() {
        if currentTime > 5 {
            seek(to: 0)
        } else if queue.hasPrevious {
            queue.advanceToPrevious()
            loadAndPlay()
        } else {
            seek(to: 0)
        }
    }

    func skipForward(by seconds: Double = 15) {
        seek(to: min(currentTime + seconds, duration))
    }

    func skipBackward(by seconds: Double = 15) {
        seek(to: max(currentTime - seconds, 0))
    }

    func toggleShuffle() { setShuffle(!queue.isShuffled) }

    func cycleRepeat() { queue.repeatMode.cycle() }

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
    }

    // MARK: - Queue editing

    func playNext(_ item: MediaItem, api: JellyfinAPI) {
        self.api = api
        guard !queue.items.isEmpty else { play(items: [item], api: api); return }
        queue.items.insert(item, at: min(queue.currentIndex + 1, queue.items.count))
        if !queue.isShuffled { queue.originalItems = queue.items }
    }

    func playLast(_ item: MediaItem, api: JellyfinAPI) {
        self.api = api
        guard !queue.items.isEmpty else { play(items: [item], api: api); return }
        queue.items.append(item)
        if !queue.isShuffled { queue.originalItems = queue.items }
    }

    /// Remove an item from the Up Next list. The currently playing track can't be removed.
    func removeFromQueue(at index: Int) {
        guard queue.items.indices.contains(index), index != queue.currentIndex else { return }
        let removed = queue.items.remove(at: index)
        if index < queue.currentIndex { queue.currentIndex -= 1 }
        queue.originalItems.removeAll { $0.id == removed.id }
    }

    /// Stop playback entirely and clear all state (used on sign-out).
    func stop() {
        cleanup()
        player?.pause()
        player = nil
        queue = PlaybackQueue()
        isPlaying = false
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
            // Keep the currently playing track first, shuffle everything after it.
            guard let current else { return }
            var rest = queue.originalItems.filter { $0.id != current.id }
            rest.shuffle()
            queue.items = [current] + rest
            queue.currentIndex = 0
        } else {
            // Restore canonical order, staying on the current track.
            queue.items = queue.originalItems
            if let current, let idx = queue.items.firstIndex(where: { $0.id == current.id }) {
                queue.currentIndex = idx
            }
        }
    }

    // MARK: - Private Loading

    private func loadAndPlay() {
        guard let item = queue.currentItem,
              let api,
              let url = api.streamURL(for: item) else { return }

        activateAudioSession()
        cleanup()
        isLoading = true
        currentTime = 0
        duration = 0

        let avItem = AVPlayerItem(url: url)
        // Start as soon as a little is buffered instead of pre-buffering ahead — much faster
        // first play on a fast/local server.
        avItem.preferredForwardBufferDuration = 1

        if player == nil {
            player = AVPlayer(playerItem: avItem)
        } else {
            player?.replaceCurrentItem(with: avItem)
        }
        player?.automaticallyWaitsToMinimizeStalling = false

        // KVO: ready to play
        statusObservation = avItem.observe(\.status, options: [.new]) { [weak self] playerItem, _ in
            let status = playerItem.status
            let dur = playerItem.duration.seconds
            Task { @MainActor [weak self] in
                guard let self else { return }
                if status == .readyToPlay {
                    self.isLoading = false
                    if dur.isFinite && !dur.isNaN && dur > 0 { self.duration = dur }
                    self.player?.play()
                    self.isPlaying = true
                    self.updateNowPlayingInfo()
                } else if status == .failed {
                    self.isLoading = false
                    self.isPlaying = false
                }
            }
        }

        // Periodic time updates. The observer fires on `.main`, so we run synchronously on the
        // main actor — using a `Task` here would add an async hop that can reorder a stale time
        // value to run *after* a seek, making the scrubber jump backwards.
        timeObserver = player?.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600),
            queue: .main
        ) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.isPlaying else { return }
                if Date() < self.seekSuppressUntil { return }
                self.currentTime = time.seconds
                if let d = self.player?.currentItem?.duration.seconds,
                   d.isFinite, !d.isNaN, d > 0 {
                    self.duration = d
                }
                self.updateNowPlayingElapsed()
            }
        }

        // Track ended
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: avItem, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleTrackEnd() }
        }
    }

    private func handleTrackEnd() {
        if queue.repeatMode == .one {
            seek(to: 0)
            player?.play()
        } else if queue.hasNext {
            queue.advanceToNext()
            loadAndPlay()
        } else {
            isPlaying = false
            currentTime = duration
            updateNowPlayingRate()
        }
    }

    private func cleanup() {
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        statusObservation?.invalidate()
        statusObservation = nil
        if let obs = endObserver { NotificationCenter.default.removeObserver(obs) }
        endObserver = nil
    }

    // MARK: - Audio Session

    private func configureAudioSession() {
        // Only set the category at launch — don't activate yet, or we'd interrupt any audio the
        // user already has playing before they've asked us to play anything.
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
                updateNowPlayingRate()
            }
        case .ended:
            if let optsRaw = info[AVAudioSessionInterruptionOptionKey] as? UInt,
               AVAudioSession.InterruptionOptions(rawValue: optsRaw).contains(.shouldResume),
               player != nil {
                player?.play()
                isPlaying = true
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
            updateNowPlayingRate()
        }
    }
#endif

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
                // Only attach if we're still on the same track (avoids clobbering after a skip).
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
            self.updateNowPlayingRate()
            return .success
        }
        cc.pauseCommand.addTarget { [weak self] _ in
            guard let self, self.player != nil else { return .noSuchContent }
            self.player?.pause()
            self.isPlaying = false
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
            guard let self, self.queue.hasNext else { return .noSuchContent }
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
