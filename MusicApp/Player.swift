import Foundation
import AVFoundation
import Observation
#if canImport(UIKit)
import UIKit
#endif

#if canImport(MediaPlayer)
import MediaPlayer
#endif

/// Audio playback engine. PHASE 2: a gapless `AVQueuePlayer` that always holds the current item plus
/// a pre-rolled "lookahead" (next) item, so one track hands off to the next with no gap. The public
/// API is unchanged from Phase 1 — the engine swap is entirely internal. The `JellyfinClient` is
/// stored at init, so play methods take no `api:` parameter.
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

    /// Live scrub state, published so EVERY disc/progress view (mini bar + cover-flow CD) tracks the
    /// same drag in lockstep. `scrubProgress` is 0…1 and only meaningful while `isScrubbing`.
    var isScrubbing = false
    var scrubProgress: Double = 0

    /// Autoplay: when the queue runs out, keep playing a server-generated instant mix of similar songs.
    var autoplayEnabled = true
    /// Upcoming Autoplay songs (an instant mix) — shown under the Up Next list, played when the queue ends.
    var autoplayTracks: [MediaItem] = []

    /// A detail route requested from Now Playing; RootTabView presents it AFTER the player closes.
    var pendingRoute: LibraryRoute?

    /// Releases the user explicitly chose to play (drives the home "Recently Played" shelf) — NOT
    /// auto-advance / Autoplay / queue jumps.
    var recentManualPlays: [ManualPlay] = []

    var currentItem: MediaItem? { queue.currentItem }
    /// Forward is allowed if there's a next track OR Autoplay can take over at the end of the queue.
    var canGoNext: Bool { queue.hasNext || (autoplayEnabled && !autoplayTracks.isEmpty) }

    @ObservationIgnored private let client: JellyfinClient

    // GAPLESS ENGINE: the AVQueuePlayer holds the current item + a pre-rolled lookahead (next) item.
    // Manual next/prev, seek, shuffle, queue edits, and repeat are driven by re-syncing that window.
    @ObservationIgnored private var player: AVQueuePlayer?
    @ObservationIgnored private var currentPlayerItem: AVPlayerItem?
    @ObservationIgnored private var lookaheadItem: AVPlayerItem?
    @ObservationIgnored private var lookaheadIndex: Int?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var statusObservation: NSKeyValueObservation?
    @ObservationIgnored private var currentItemObservation: NSKeyValueObservation?
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
    /// Position to seek to once the (lazily-built) player becomes ready — resumes a restored session.
    @ObservationIgnored private var pendingSeekTime: Double?
    @ObservationIgnored private let sessionDefaultsKey = "lastPlaybackSession"
    @ObservationIgnored private var autoplaySeedId: String?
    @ObservationIgnored private let autoplayDefaultsKey = "autoplayEnabled"
    @ObservationIgnored private let manualPlaysKey = "recentManualPlays"
#if os(iOS)
    @ObservationIgnored private let skipFeedback = UIImpactFeedbackGenerator(style: .medium)
#endif

    init(client: JellyfinClient) {
        self.client = client
        configureAudioSession()
        setupRemoteControls()
        setupNotifications()
        updateOutputRoute()
        autoplayEnabled = UserDefaults.standard.object(forKey: autoplayDefaultsKey) as? Bool ?? true
        if let data = UserDefaults.standard.data(forKey: manualPlaysKey),
           let plays = try? JSONDecoder().decode([ManualPlay].self, from: data) {
            recentManualPlays = plays
        }
        restoreSession()   // show the last-played track in the mini bar (paused, ready to resume)
    }

    deinit {
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Public playback control

    /// Start a brand-new playback context from `items`. Resets shuffle/queue state.
    func play(items: [MediaItem], from index: Int = 0, shuffled: Bool = false) {
        guard !items.isEmpty else { return }
        pendingSeekTime = nil   // a fresh context never resumes the restored position
        let clicked = min(max(index, 0), items.count - 1)
        recordManualPlay(track: items[clicked], isAlbum: index == 0 && items.count > 1)
        skipHaptic()
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
        autoplaySeedId = nil
        Task { await refreshAutoplay() }
    }

    /// Jump to an existing item in the current queue (e.g. tapping in the Up Next list).
    func play(at index: Int) {
        guard queue.items.indices.contains(index) else { return }
        pendingSeekTime = nil
        skipHaptic()
        rebuild(at: index, autoplay: true)
    }

    func togglePlayPause() {
        // A restored session has its queue but no live player yet — build it at the saved spot,
        // resume the saved position, and play.
        if player == nil {
            guard queue.currentItem != nil else { return }
            pendingSeekTime = currentTime > 0 ? currentTime : nil
            rebuild(at: queue.currentIndex, autoplay: true)
            return
        }
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
        saveSession()
    }

    func seek(to time: Double) {
        let clamped = duration > 0 ? min(max(time, 0), duration) : max(time, 0)
        player?.seek(to: CMTime(seconds: clamped, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        currentTime = clamped
        seekSuppressUntil = Date().addingTimeInterval(0.5)
        updateNowPlayingElapsed()
        saveSession()
    }

    func nextTrack() {
        skipHaptic()
        guard let player else {
            // Restored session with no live player yet — build the next track and play.
            if let n = nextIndex(after: queue.currentIndex) { pendingSeekTime = nil; rebuild(at: n, autoplay: true) }
            else if autoplayEnabled { Task { await continueWithAutoplay() } }
            return
        }
        // If the next track is already pre-rolled, advance to it instantly; otherwise rebuild.
        if let n = nextIndex(after: queue.currentIndex) {
            if let look = lookaheadItem, lookaheadIndex == n {
                player.advanceToNextItem()
                didAdvance(to: look, index: n)   // sync so an immediate prev/next sees the new index
            } else {
                rebuild(at: n, autoplay: intendedPlaying || isPlaying)
            }
        } else if autoplayEnabled {
            // Last track + Autoplay on → continue with the instant mix.
            Task { await continueWithAutoplay() }
        }
    }

    /// Tapping a track in the Autoplay list jumps to it (the whole mix is appended to the queue).
    func playAutoplayFrom(_ index: Int) {
        guard autoplayTracks.indices.contains(index) else { return }
        skipHaptic()
        let mix = autoplayTracks
        autoplayTracks = []
        autoplaySeedId = nil
        let startIndex = queue.items.count
        queue.items.append(contentsOf: mix)
        queue.originalItems = queue.items
        pendingSeekTime = nil
        rebuild(at: startIndex + index, autoplay: true)
        Task { await refreshAutoplay() }
    }

    func previousTrack() {
        skipHaptic()
        guard player != nil else {
            // Restored session with no live player yet — start the current track.
            pendingSeekTime = nil
            rebuild(at: queue.currentIndex, autoplay: true)
            return
        }
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

    private func skipHaptic() {
#if os(iOS)
        skipFeedback.impactOccurred()
        skipFeedback.prepare()   // keep it warm for the next skip
#endif
    }

    /// Record a release the user explicitly chose to play, for the home "Recently Played" shelf.
    private func recordManualPlay(track: MediaItem, isAlbum: Bool) {
        let entry = ManualPlay(track: track, isAlbum: isAlbum)
        recentManualPlays.removeAll { $0.id == entry.id }
        recentManualPlays.insert(entry, at: 0)
        if recentManualPlays.count > 24 { recentManualPlays = Array(recentManualPlays.prefix(24)) }
        if let data = try? JSONEncoder().encode(recentManualPlays) {
            UserDefaults.standard.set(data, forKey: manualPlaysKey)
        }
    }

    func toggleShuffle() { setShuffle(!queue.isShuffled) }

    func cycleRepeat() {
        queue.repeatMode.cycle()
        syncRepeatMode()
    }

    func stop() {
        reportStop()
        teardownPlayer()
        queue = PlaybackQueue()
        isPlaying = false
        intendedPlaying = false
        isLoading = false
        currentTime = 0
        duration = 0
        pendingSeekTime = nil
        clearSession()
        clearNowPlayingInfo()
    }

    // MARK: - Queue editing (Up Next)

    /// Insert a track right after the current one.
    func playNext(_ item: MediaItem) {
        guard !queue.items.isEmpty else { play(items: [item]); return }
        queue.items.insert(item, at: min(queue.currentIndex + 1, queue.items.count))
        if !queue.isShuffled { queue.originalItems = queue.items }
        resyncLookahead()
    }

    /// Append a track to the end of the queue.
    func playLast(_ item: MediaItem) {
        guard !queue.items.isEmpty else { play(items: [item]); return }
        queue.items.append(item)
        if !queue.isShuffled { queue.originalItems = queue.items }
        resyncLookahead()
    }

    /// Insert a whole set of tracks (an album/playlist) right after the current track.
    func playNext(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        guard !queue.items.isEmpty else { play(items: items); return }
        queue.items.insert(contentsOf: items, at: min(queue.currentIndex + 1, queue.items.count))
        if !queue.isShuffled { queue.originalItems = queue.items }
        resyncLookahead()
    }

    /// Append a whole set of tracks (an album/playlist) to the end of the queue.
    func playLast(_ items: [MediaItem]) {
        guard !items.isEmpty else { return }
        guard !queue.items.isEmpty else { play(items: items); return }
        queue.items.append(contentsOf: items)
        if !queue.isShuffled { queue.originalItems = queue.items }
        resyncLookahead()
    }

    /// Remove an item from Up Next. The currently playing track can't be removed.
    func removeFromQueue(at index: Int) {
        guard queue.items.indices.contains(index), index != queue.currentIndex else { return }
        let removed = queue.items.remove(at: index)
        if index < queue.currentIndex { queue.currentIndex -= 1 }
        queue.originalItems.removeAll { $0.id == removed.id }
        resyncLookahead()
        saveSession()
    }

    /// Reorder Up Next (drag to move), keeping the current track's index in sync. Implements the
    /// `move(fromOffsets:toOffset:)` semantics without pulling SwiftUI into the model layer.
    func moveInQueue(from source: IndexSet, to destination: Int) {
        let current = queue.currentItem
        let sorted = source.sorted()
        let moving = sorted.map { queue.items[$0] }
        var result = queue.items
        for i in sorted.reversed() { result.remove(at: i) }
        let insertIndex = destination - sorted.filter { $0 < destination }.count
        result.insert(contentsOf: moving, at: min(max(0, insertIndex), result.count))
        queue.items = result
        if !queue.isShuffled { queue.originalItems = queue.items }
        if let current, let idx = queue.items.firstIndex(where: { $0.id == current.id }) {
            queue.currentIndex = idx
        }
        resyncLookahead()
        saveSession()
    }

    /// Warm the decoded-image cache for the current track and its neighbours, so skipping never
    /// flashes a placeholder anywhere (now playing, mini bar, lists).
    private func prefetchArtwork() {
        for i in [queue.currentIndex - 1, queue.currentIndex, queue.currentIndex + 1]
        where queue.items.indices.contains(i) {
            let item = queue.items[i]
            for size in [1000, 400, 160] {
                guard let url = client.artworkURL(for: item, size: size) else { continue }
                let maxPixel = CGFloat(size)
                Task.detached(priority: .utility) { _ = await ImageStore.shared.load(url, maxPixel: maxPixel) }
            }
        }
    }

    // MARK: - Scrubbing (pause while the user holds the playhead)

    func beginScrubbing() {
        wasPlayingBeforeScrub = isPlaying
        isScrubbing = true
        scrubProgress = duration > 0 ? min(max(currentTime / duration, 0), 1) : 0
        if isPlaying {
            player?.pause()
            isPlaying = false
            updateNowPlayingRate()
        }
    }

    /// Called continuously as the user drags any scrubber, so the disc(s) turn with the playhead.
    func updateScrubbing(progress: Double) {
        scrubProgress = min(max(progress, 0), 1)
    }

    func endScrubbing(to time: Double) {
        isScrubbing = false
        seek(to: time)
        if wasPlayingBeforeScrub {
            player?.play()
            isPlaying = true
            updateNowPlayingRate()
        }
        wasPlayingBeforeScrub = false
        reportProgress(paused: !isPlaying)
    }

    // MARK: - Session persistence (restore the last-played track across launches)

    private struct PersistedSession: Codable {
        var items: [MediaItem]
        var originalItems: [MediaItem]
        var index: Int
        var time: Double
        var isShuffled: Bool
        var repeatMode: String
    }

    /// Snapshot the current queue + position so the next launch can show it in the mini bar.
    private func saveSession() {
        guard !queue.items.isEmpty, queue.items.indices.contains(queue.currentIndex) else { return }
        let session = PersistedSession(
            items: queue.items,
            originalItems: queue.originalItems,
            index: queue.currentIndex,
            time: max(0, currentTime),
            isShuffled: queue.isShuffled,
            repeatMode: queue.repeatMode.rawValue
        )
        guard let data = try? JSONEncoder().encode(session) else { return }
        UserDefaults.standard.set(data, forKey: sessionDefaultsKey)
    }

    /// Load the last session into the queue WITHOUT building a player or auto-playing — so the mini
    /// bar shows the track (paused) and the first play resumes it at the saved position.
    private func restoreSession() {
        guard let data = UserDefaults.standard.data(forKey: sessionDefaultsKey),
              let session = try? JSONDecoder().decode(PersistedSession.self, from: data),
              !session.items.isEmpty, session.items.indices.contains(session.index) else { return }
        queue.items = session.items
        queue.originalItems = session.originalItems.isEmpty ? session.items : session.originalItems
        queue.currentIndex = session.index
        queue.isShuffled = session.isShuffled
        queue.repeatMode = RepeatMode(rawValue: session.repeatMode) ?? .off
        currentTime = max(0, session.time)
        duration = session.items[session.index].durationSeconds ?? 0
        isPlaying = false
        intendedPlaying = false
    }

    private func clearSession() {
        UserDefaults.standard.removeObject(forKey: sessionDefaultsKey)
    }

    /// When there's no locally-saved session (e.g. a fresh install), seed the mini bar with the last
    /// track the server has on record, so launch isn't blank. Paused — the first play starts it.
    func restoreFromServerIfNeeded() async {
        guard queue.items.isEmpty, player == nil else { return }
        guard let track = (try? await client.fetchRecentlyPlayed(limit: 1))?.first else { return }
        guard queue.items.isEmpty, player == nil else { return }   // nothing started while we fetched
        queue.items = [track]
        queue.originalItems = [track]
        queue.currentIndex = 0
        currentTime = 0
        duration = track.durationSeconds ?? 0
        isPlaying = false
        intendedPlaying = false
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
        if queue.repeatMode == .one { return nil }                      // loop handled on item end
        if i + 1 < queue.items.count { return i + 1 }
        if queue.repeatMode == .all, !queue.items.isEmpty { return 0 }   // wrap to the top
        return nil
    }

    private func makeItem(forIndex i: Int, immediate: Bool) -> AVPlayerItem? {
        guard queue.items.indices.contains(i), let url = client.streamURL(for: queue.items[i]) else { return nil }
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
        saveSession()
        prefetchArtwork()
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
                if self.progressTick % 20 == 0 {                  // ~every 10s
                    self.reportProgress(paused: false)
                    self.saveSession()
                }
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
                    if let t = self.pendingSeekTime {   // resume a restored session at its saved spot
                        self.pendingSeekTime = nil
                        self.seek(to: t)
                    }
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
        saveSession()
        prefetchArtwork()
    }

    private func handleQueueEnd() {
        reportStop()
        if autoplayEnabled {
            Task { await continueWithAutoplay() }
            return
        }
        // Autoplay off → reset to the top, paused and ready to replay.
        isPlaying = false
        intendedPlaying = false
        queue.currentIndex = 0
        rebuild(at: 0, autoplay: false)
    }

    // MARK: - Autoplay (continue with an instant mix when the queue ends)

    /// Persist + apply the Autoplay toggle.
    func setAutoplay(_ on: Bool) {
        autoplayEnabled = on
        UserDefaults.standard.set(on, forKey: autoplayDefaultsKey)
        if on {
            Task { await refreshAutoplay() }
        } else {
            autoplayTracks = []
            autoplaySeedId = nil
        }
    }

    /// Refresh the upcoming Autoplay tracks — an instant mix seeded by the last queued track, with
    /// anything already queued filtered out. No-op if the seed hasn't changed.
    func refreshAutoplay() async {
        guard autoplayEnabled, let seed = queue.items.last else {
            autoplayTracks = []; autoplaySeedId = nil; return
        }
        if seed.id == autoplaySeedId, !autoplayTracks.isEmpty { return }
        autoplaySeedId = seed.id
        let mix = (try? await client.fetchInstantMix(itemId: seed.id, limit: 20)) ?? []
        guard autoplaySeedId == seed.id else { return }   // seed changed mid-fetch
        let queued = Set(queue.items.map(\.id))
        autoplayTracks = mix.filter { !queued.contains($0.id) }
    }

    private func continueWithAutoplay() async {
        if autoplayTracks.isEmpty { await refreshAutoplay() }
        guard autoplayEnabled, !autoplayTracks.isEmpty else {
            isPlaying = false
            intendedPlaying = false
            queue.currentIndex = 0
            rebuild(at: 0, autoplay: false)
            return
        }
        let mix = autoplayTracks
        autoplayTracks = []
        autoplaySeedId = nil
        let startIndex = queue.items.count
        queue.items.append(contentsOf: mix)
        queue.originalItems = queue.items
        rebuild(at: startIndex, autoplay: true)
        await refreshAutoplay()   // seed the following batch
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

    /// Re-read the current output device name (e.g. when Now Playing appears).
    func refreshOutputRoute() { updateOutputRoute() }

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
