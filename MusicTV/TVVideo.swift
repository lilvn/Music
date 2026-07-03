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
    /// The video currently on screen (nil = normal audio Now Playing).
    private(set) var activeVideo: MediaItem?
    private(set) var avPlayer: AVPlayer?

    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var loaded = false

    private init() {}

    func loadLibrary(client: JellyfinClient) async {
        guard !loaded else { return }
        videos = (try? await client.fetchMusicVideos()) ?? []
        loaded = true
    }

    /// The library video for this song, if any.
    func videoMatching(_ song: MediaItem?) -> MediaItem? {
        guard let song else { return nil }
        let artist = song.primaryArtist.lowercased()
        let title = song.name.lowercased()
        return videos.first { video in
            let name = video.name.lowercased()
            guard !name.isEmpty else { return false }
            if !artist.isEmpty, name == artist || name.contains(artist) || artist.contains(name) { return true }
            if name == title { return true }
            return video.artistItems?.contains { $0.name.lowercased() == artist } ?? false
        }
    }

    /// Switch playback to `video`: pause the audio queue, play the video with its own audio.
    func enter(video: MediaItem, client: JellyfinClient, audio: Player) {
        guard activeVideo?.id != video.id else { return }
        guard let url = client.videoStreamURL(for: video) else { return }
        audio.pause()
        stopVideo()

        let item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 4
        let av = AVPlayer(playerItem: item)
        // Direct-play from the local server is fast — start immediately rather than letting AVPlayer
        // hold at the first frame while it decides it has "enough" buffer.
        av.automaticallyWaitsToMinimizeStalling = false
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { _ in
            // Video finished → move the queue along; the Now Playing view re-evaluates the new track
            // (next video, or exit back to audio).
            Task { @MainActor in
                TVVideoController.shared.stopVideo()
                TVVideoController.shared.activeVideo = nil
                Player.shared.nextTrack()
                Player.shared.resume()
            }
        }
        av.playImmediately(atRate: 1)
        avPlayer = av
        activeVideo = video

        // Belt-and-braces: if the pipeline stalled at the first frame, kick it once it has buffer.
        Task { [weak av] in
            try? await Task.sleep(for: .seconds(3))
            guard let av, av === self.avPlayer, av.rate == 0 else { return }
            av.playImmediately(atRate: 1)
        }
    }

    /// Leave video mode; optionally resume the paused audio queue.
    func exit(audio: Player, resumeAudio: Bool) {
        guard activeVideo != nil else { return }
        stopVideo()
        activeVideo = nil
        if resumeAudio { audio.resume() }
    }

    func togglePlayPause() {
        guard let avPlayer else { return }
        avPlayer.rate > 0 ? avPlayer.pause() : avPlayer.play()
    }

    private func stopVideo() {
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        avPlayer?.pause()
        avPlayer = nil
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
