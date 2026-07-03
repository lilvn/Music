import SwiftUI
import AVKit

/// Music-video mode for the TV's Now Playing. When the Jellyfin library holds a music video matching
/// the current song, playback SWITCHES to the video (its own audio): the local audio player pauses,
/// the video fills the screen, and the skeuomorphic carousel docks to the bottom. When the video ends
/// (or the user selects a track without one), the queue advances and audio playback resumes.
///
/// Matching: this library organises music videos per-ARTIST (each video's Name is the artist), so a
/// song matches when the video's name equals/contains its artist — with the song title checked too
/// for libraries that name videos per-song.
@MainActor
@Observable
final class TVVideoController {
    static let shared = TVVideoController()

    /// The music-video library (small — fetched once per launch).
    private(set) var videos: [MediaItem] = []
    /// The video currently on screen (nil = normal audio Now Playing). For a matched track this is a
    /// MUTED backdrop; for the Music Videos playlist it's the video being watched.
    private(set) var activeVideo: MediaItem?
    private(set) var avPlayer: AVPlayer?
    /// True when playing the Music Videos playlist DIRECTLY (video queue, no audio-track backing) —
    /// as opposed to a video matched to the current song.
    private(set) var direct = false
    /// Playhead fraction (0…1) for the mini bar while in direct video mode.
    private(set) var directProgress: Double = 0

    @ObservationIgnored private var directQueue: [MediaItem] = []
    @ObservationIgnored private var directIndex = 0
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var loaded = false

    private init() {}

    func loadLibrary(client: JellyfinClient) async {
        guard !loaded else { return }
        videos = (try? await client.fetchMusicVideos()) ?? []
        loaded = true
    }

    /// The library video for this song, if any. EXACT matches only (video name == the song's artist
    /// or title, or properly-tagged video artist) — the old "contains" rules false-matched wide
    /// (a video named "Che" hit every artist containing those letters) and launched random videos.
    func videoMatching(_ song: MediaItem?) -> MediaItem? {
        guard let song else { return nil }
        let artist = song.primaryArtist.trimmingCharacters(in: .whitespaces).lowercased()
        let title = song.name.trimmingCharacters(in: .whitespaces).lowercased()
        return videos.first { video in
            let name = video.name.trimmingCharacters(in: .whitespaces).lowercased()
            guard !name.isEmpty else { return false }
            if !artist.isEmpty, name == artist { return true }
            if name == title { return true }
            return video.artistItems?.contains { $0.name.trimmingCharacters(in: .whitespaces).lowercased() == artist } ?? false
        }
    }

    // MARK: - Matched video = a MUTED backdrop over the NORMAL audio track

    /// Keep the backdrop in step with the current track. The audio track is the playback — queue,
    /// timeline and scrobbling stay completely normal ("treat it like a normal track"); the matched
    /// video is a muted, looping VISUAL only. Called on every track / play-state change from the root.
    func evaluate(client: JellyfinClient, audio: Player) {
        self.client = client
        self.audio = audio
        // The audio queue changed while the Music Videos PLAYLIST was on screen — that only happens
        // when you start a real track (an album, a song). Leave the playlist so its video doesn't keep
        // running underneath the new song.
        if direct { exit(audio: audio, resumeAudio: false) }
        guard let song = audio.currentItem, let video = videoMatching(song) else {
            clearBackdrop()                                  // no video for this track → plain audio NP
            return
        }
        showBackdrop(video, client: client, playing: audio.isPlaying)
    }

    /// Mirror the audio's play/pause onto the muted backdrop so the picture freezes when you pause.
    func setPlaying(_ playing: Bool) {
        guard !direct, let avPlayer else { return }
        playing ? avPlayer.play() : avPlayer.pause()
    }

    private func showBackdrop(_ video: MediaItem, client: JellyfinClient, playing: Bool) {
        if activeVideo?.id == video.id {
            // The videos are named per-ARTIST, so every track on an artist's album matches the SAME
            // video. showBackdrop is only re-entered here on a real track change, so restart the clip
            // from the top — otherwise it drones on from the middle of the previous song ("the video
            // keeps playing even when the song is over").
            avPlayer?.seek(to: .zero)
            playing ? avPlayer?.play() : avPlayer?.pause()
            return
        }
        guard let url = client.videoStreamURL(for: video) else { clearBackdrop(); return }
        makePlayer(url: url, muted: true, loops: true)       // muted — the album track is the audio
        activeVideo = video
        if playing { avPlayer?.playImmediately(atRate: 1) }
    }

    private func clearBackdrop() {
        guard !direct, activeVideo != nil else { return }
        stopVideo()
        activeVideo = nil
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
        makePlayer(url: url, muted: false, loops: false)     // the video's own audio plays
        activeVideo = directQueue[i]
        avPlayer?.playImmediately(atRate: 1)
    }

    // MARK: - Shared engine

    @ObservationIgnored private weak var audio: Player?
    @ObservationIgnored private weak var client: JellyfinClient?

    private func makePlayer(url: URL, muted: Bool, loops: Bool) {
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
                } else if loops {
                    // Backdrop loops until the AUDIO track ends (the audio queue advances the song).
                    ctl.avPlayer?.seek(to: .zero)
                    if Player.shared.isPlaying { ctl.avPlayer?.play() }
                }
            }
        }
        // Progress for the mini bar (used in direct mode — audio mode reads the Player instead).
        timeObserver = av.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self, weak av] t in
            guard let self, let d = av?.currentItem?.duration.seconds, d.isFinite, d > 0 else { return }
            self.directProgress = min(max(t.seconds / d, 0), 1)
        }
        avPlayer = av
        // Belt-and-braces: if the pipeline stalled at the first frame, kick it once it has buffer.
        Task { [weak av] in
            try? await Task.sleep(for: .seconds(3))
            guard let av, av === self.avPlayer, av.rate == 0 else { return }
            if muted, self.audio?.isPlaying != true { return }   // a paused backdrop should stay paused
            av.playImmediately(atRate: 1)
        }
    }

    /// Leave video mode. Only the direct playlist ever paused the audio, so only it resumes it.
    func exit(audio: Player, resumeAudio: Bool) {
        guard activeVideo != nil else { return }
        let wasDirect = direct
        stopVideo()
        activeVideo = nil
        direct = false
        directQueue = []
        if wasDirect, resumeAudio { audio.resume() }
    }

    /// Play/pause for the direct playlist (the video is the sound). Matched-video mode toggles the
    /// audio Player instead, and setPlaying() mirrors it here.
    func togglePlayPause() {
        guard let avPlayer else { return }
        avPlayer.rate > 0 ? avPlayer.pause() : avPlayer.play()
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
