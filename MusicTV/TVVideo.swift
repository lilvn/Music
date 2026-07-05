import SwiftUI
import AVKit

/// Music-video mode for the TV's Now Playing. When the Jellyfin library holds a music video matching
/// the current song, playback SWITCHES to the video (its own audio): the audio Player yields (it never
/// sounds for a matched track — no double-playback, no sync drift) but keeps owning the queue and the
/// track identity. When the video ends the song queue advances; plain-audio tracks resume normally.
///
/// Matching is STANDARD and per-song: a music video is tied to the track whose TITLE it shares (see
/// `videoMatching`), so any server that names its music videos after their songs works unchanged.
@MainActor
@Observable
final class TVVideoController {
    static let shared = TVVideoController()

    /// The music-video library (small — fetched once per launch).
    private(set) var videos: [MediaItem] = []
    /// The video currently on screen (nil = normal audio Now Playing).
    private(set) var activeVideo: MediaItem?
    private(set) var avPlayer: AVPlayer?
    /// True when playing the Music Videos playlist DIRECTLY (video queue, no audio-track backing) —
    /// as opposed to a video matched to the current song.
    private(set) var direct = false
    /// True when the current SONG's matched video owns playback — the video's audio is the sound,
    /// the audio Player sits silenced underneath, still owning the queue and track identity.
    private(set) var matched = false
    /// The video is the sound (either mode) — transport, progress and reporting belong to it.
    var ownsPlayback: Bool { direct || matched }
    /// Playhead fraction (0…1) for the bar/pill while a video owns playback.
    private(set) var directProgress: Double = 0
    /// Whether the owning video is paused — observable so transport UI can show the right glyph.
    private(set) var directPaused = false

    @ObservationIgnored private var directQueue: [MediaItem] = []
    @ObservationIgnored private var directIndex = 0
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loaded = false
    /// The direct video currently reported to Jellyfin's session (so phones see the TV's video
    /// playback live); nil when nothing is reported.
    @ObservationIgnored private var reportedVideoId: String?
    @ObservationIgnored private var videoTick = 0

    private init() {}

    func loadLibrary(client: JellyfinClient) async {
        guard !loaded else { return }
        videos = (try? await client.fetchMusicVideos()) ?? []
        loaded = true
    }

    /// The library video for this SONG, if any. STANDARD per-song matching: a music video matches when
    /// its title equals the song's title — the normal convention where a video is named after its song,
    /// so it's tied to that track (not to the whole artist). When the video carries artist tags we also
    /// require the artist to match, so two different songs sharing a title don't cross-match.
    func videoMatching(_ song: MediaItem?) -> MediaItem? {
        guard let song else { return nil }
        let title = song.name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !title.isEmpty else { return nil }
        let artist = song.primaryArtist.trimmingCharacters(in: .whitespaces).lowercased()
        return videos.first { video in
            guard video.name.trimmingCharacters(in: .whitespaces).lowercased() == title else { return false }
            guard let tags = video.artistItems, !tags.isEmpty else { return true }
            return tags.contains { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == artist }
        }
    }

    // MARK: - Matched video OWNS playback for its song (the audio version never sounds)

    /// Re-evaluate on every track / play-state change from the root. A song with a matched video
    /// hands playback to the video; a song without one plays as plain audio.
    func evaluate(client: JellyfinClient, audio: Player) {
        self.client = client
        self.audio = audio
        // The audio queue changed while the Music Videos PLAYLIST was on screen — that only happens
        // when you start a real track (an album, a song). Leave the playlist so its video doesn't keep
        // running underneath the new song.
        if direct { exit(audio: audio, resumeAudio: false) }
        guard let song = audio.currentItem, let video = videoMatching(song) else {
            clearMatched()                                   // no video for this track → plain audio NP
            return
        }
        enterMatched(video, audio: audio, client: client)
    }

    /// The audio Player's play-state flipped. Only matters while a matched video owns playback:
    /// the audio must stay silent, and a stray resume (Siri, a remote command, the lock screen)
    /// is read as "play" and folded into the video instead.
    func audioPlayStateChanged(audio: Player) {
        guard matched else { return }
        if audio.isPlaying || audio.wantsPlayback {
            audio.yieldToExternalPlayback()
            if directPaused { togglePlayPause() }
        }
    }

    private func enterMatched(_ video: MediaItem, audio: Player, client: JellyfinClient) {
        if matched, activeVideo?.id == video.id { return }   // already showing this song's video
        guard let url = client.videoStreamURL(for: video) else { clearMatched(); return }
        // Carry the play intent across: video→video keeps the video's state; entering fresh takes
        // the audio's (isPlaying OR still-buffering intent).
        let wantsPlayback = matched ? !directPaused : (audio.isPlaying || audio.wantsPlayback)
        audio.yieldToExternalPlayback()                      // the audio version NEVER sounds on TV
        reportStopIfNeeded()
        makePlayer(url: url, muted: false)
        activeVideo = video
        matched = true
        directPaused = !wantsPlayback
        if wantsPlayback { avPlayer?.playImmediately(atRate: 1) }
        // Report the VIDEO as this session's playback so other devices mirror the truth.
        reportedVideoId = video.id
        videoTick = 0
        Task { await client.reportPlaybackStart(itemId: video.id, positionTicks: 0, queueIds: [video.id]) }
        // Exclusive playback: a matched video starting is a real local start (the audio Player's
        // own choke point never fires here) — this device owns playback, pause the other one.
        if wantsPlayback { SessionHub.shared.noteLocalPlayStart() }
    }

    /// The matched video finished — advance the SONG queue. evaluate() then swaps in the next
    /// track's video, or resumes plain audio for a track without one.
    fileprivate func matchedVideoEnded() {
        guard matched, let audio else { return }
        if audio.canGoNext {
            audio.nextTrack()                                // paused underneath → stays silent
        } else {
            clearMatched(resume: false)                      // queue over — nothing to play
        }
    }

    private func clearMatched(resume: Bool = true) {
        guard matched else { return }
        let wasPlaying = !directPaused
        matched = false
        reportStopIfNeeded()
        stopVideo()
        activeVideo = nil
        directPaused = false
        // The song moved on to a plain-audio track: restore the sound if the video was playing.
        if resume, wasPlaying { audio?.resume() }
    }

    // MARK: - Direct Music Videos playlist = video with its OWN audio

    func playDirect(_ queue: [MediaItem], from index: Int, client: JellyfinClient, audio: Player) {
        guard queue.indices.contains(index) else { return }
        directQueue = queue
        directIndex = index
        direct = true
        self.client = client
        self.audio = audio
        audio.pause()                                        // the playlist's videos ARE the sound
        playDirectAt(index)
    }

    func skipDirect(_ delta: Int, client: JellyfinClient, audio: Player) {
        guard direct else { return }
        self.client = client
        self.audio = audio
        advanceDirect(by: delta)
    }

    fileprivate func advanceDirect(by delta: Int) {
        guard direct else { return }
        let next = directIndex + delta
        guard directQueue.indices.contains(next) else {
            if let audio { exit(audio: audio, resumeAudio: false) }
            return
        }
        directIndex = next
        playDirectAt(next)
    }

    private func playDirectAt(_ i: Int) {
        guard directQueue.indices.contains(i), let url = client?.videoStreamURL(for: directQueue[i]) else { return }
        reportStopIfNeeded()                                 // close out the previous video's session
        makePlayer(url: url, muted: false)                   // the video's own audio plays
        activeVideo = directQueue[i]
        directPaused = false
        avPlayer?.playImmediately(atRate: 1)
        // Report to Jellyfin so other devices see the TV playing this video (live mini bar/mirror).
        let id = directQueue[i].id
        let ids = directQueue.map(\.id)
        reportedVideoId = id
        videoTick = 0
        Task { await client?.reportPlaybackStart(itemId: id, positionTicks: 0, queueIds: ids) }
    }

    /// Close out the reported video session, at the current playhead if we still have one.
    private func reportStopIfNeeded() {
        guard let id = reportedVideoId else { return }
        reportedVideoId = nil
        let ticks = Int64((avPlayer?.currentTime().seconds ?? 0) * 10_000_000)
        Task { await client?.reportPlaybackStopped(itemId: id, positionTicks: ticks) }
    }

    /// Route a transport command sent by another device (phone controlling the TV) at whichever
    /// video owns playback — the audio Player isn't what's sounding here.
    func handleRemote(_ command: String) {
        guard ownsPlayback else { return }
        switch command {
        case "PlayPause":     togglePlayPause()
        case "Pause":         if !directPaused { togglePlayPause() }
        case "Unpause":       if directPaused { togglePlayPause() }
        case "NextTrack":
            if direct { if let client, let audio { skipDirect(+1, client: client, audio: audio) } }
            else { audio?.nextTrack() }                      // matched: advance the song queue
        case "PreviousTrack":
            if direct { if let client, let audio { skipDirect(-1, client: client, audio: audio) } }
            else { audio?.previousTrack() }
        case "Stop":
            if direct { if let audio { exit(audio: audio, resumeAudio: false) } }
            else { clearMatched(resume: false); audio?.stop() }
        default: break
        }
    }

    // MARK: - Shared engine

    @ObservationIgnored private weak var audio: Player?
    @ObservationIgnored private weak var client: JellyfinClient?

    private func makePlayer(url: URL, muted: Bool) {
        stopVideo()
        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 4
        let av = AVPlayer(playerItem: item)
        av.isMuted = muted
        av.automaticallyWaitsToMinimizeStalling = false      // direct-play from a local server is fast
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in
            Task { @MainActor in
                let ctl = TVVideoController.shared
                if ctl.direct {
                    ctl.advanceDirect(by: 1)                 // playlist → next video
                } else if ctl.matched {
                    ctl.matchedVideoEnded()                  // song over → advance the queue
                }
            }
        }
        // Progress for the bar/pill, and session reporting while the video owns playback.
        timeObserver = av.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self, weak av] t in
            guard let self, let d = av?.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
            self.directProgress = min(max(t.seconds / d, 0), 1)
            // Report progress every ~5s (matching the audio Player's cadence) so other devices'
            // session polls see a moving playhead.
            if self.ownsPlayback, let id = self.reportedVideoId {
                self.videoTick += 1
                if self.videoTick % 10 == 0 {
                    let ticks = Int64(t.seconds * 10_000_000)
                    let ids = self.direct ? self.directQueue.map(\.id) : [id]
                    let paused = self.directPaused
                    Task { await self.client?.reportPlaybackProgress(itemId: id, positionTicks: ticks,
                                                                     isPaused: paused, queueIds: ids) }
                }
            }
        }
        avPlayer = av
        // Belt-and-braces: if the pipeline stalled at the first frame, kick it once it has buffer.
        Task { [weak av] in
            try? await Task.sleep(for: .seconds(3))
            guard let av, av === self.avPlayer, av.rate == 0 else { return }
            if self.directPaused { return }                  // a paused video should stay paused
            av.playImmediately(atRate: 1)
        }
    }

    /// Leave video mode entirely (logout, or a real track replacing the direct playlist).
    func exit(audio: Player, resumeAudio: Bool) {
        guard activeVideo != nil else { return }
        let wasDirect = direct
        reportStopIfNeeded()   // close the video's session report before tearing the player down
        stopVideo()
        activeVideo = nil
        direct = false
        matched = false
        directPaused = false
        directQueue = []
        if wasDirect, resumeAudio { audio.resume() }
    }

    /// Play/pause for whichever video owns playback (the video is the sound in BOTH modes).
    /// Intent-based, not rate-based: while buffering the rate is 0 even though we're "playing",
    /// and a Pause command arriving then must not read that as "resume".
    func togglePlayPause() {
        guard let avPlayer else { return }
        directPaused ? avPlayer.play() : avPlayer.pause()
        if ownsPlayback {
            directPaused.toggle()
            // Report the pause/resume immediately so other devices' mirrors flip without poll lag.
            if let id = reportedVideoId {
                let ticks = Int64(avPlayer.currentTime().seconds * 10_000_000)
                let ids = direct ? directQueue.map(\.id) : [id]
                let paused = directPaused
                Task { await client?.reportPlaybackProgress(itemId: id, positionTicks: ticks,
                                                            isPaused: paused, queueIds: ids) }
            }
        }
    }

    private func stopVideo() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        if let timeObserver { avPlayer?.removeTimeObserver(timeObserver) }
        timeObserver = nil
        avPlayer?.pause()
        avPlayer = nil
        directProgress = 0
    }
}

/// Bare AVPlayerLayer host — full-bleed video with NO system transport chrome (the docked carousel is
/// the UI; system VideoPlayer controls would fight the focus engine for it).
struct TVVideoLayer: UIViewRepresentable {
    let player: AVPlayer

    final class PlayerHostView: UIView {
        override static var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }

    func makeUIView(context: Context) -> PlayerHostView {
        let view = PlayerHostView()
        view.playerLayer.videoGravity = .resizeAspectFill
        view.playerLayer.player = player
        return view
    }

    func updateUIView(_ view: PlayerHostView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }
}
