#if os(iOS)
import AVFoundation
import MediaPlayer
import UIKit

/// Puts a REMOTE session (music physically playing on the TV) onto this iPhone's lock screen /
/// Control Center — the Spotify-Connect trick: while another device of this account is actively
/// playing and we're silent, a muted looping audio keeps our audio session (and the app) alive, so
/// iOS treats us as the Now Playing app and shows the REMOTE track. Lock-screen buttons route to the
/// remote device via Player's MPRemoteCommandCenter handlers (they branch on `active`).
///
/// Engaged/refreshed from SessionHub's poll; disengaged the moment local playback starts (or the
/// remote stops), restoring the local track's info.
@MainActor
final class RemoteLockScreenBridge {
    static let shared = RemoteLockScreenBridge()
    private init() {}

    /// True while the lock screen is showing a remote session (Player's command handlers check this).
    private(set) var active = false

    private var silence: AVAudioPlayer?
    /// The item id whose artwork is on the info center, so we only re-fetch on track change.
    private var artworkItemId: String?

    /// Called on every session poll. Engages/refreshes while the remote plays and we don't;
    /// disengages otherwise.
    func update(remote: SessionHub.RemoteSession?, player: Player, client: JellyfinClient) {
        if let remote, !remote.isPaused, !player.isPlaying {
            engage(remote, client: client)
        } else if active {
            disengage(player: player)
        }
    }

    private func engage(_ remote: SessionHub.RemoteSession, client: JellyfinClient) {
        if silence == nil { silence = Self.makeSilencePlayer() }
        if silence?.isPlaying != true {
            try? AVAudioSession.sharedInstance().setActive(true)
            silence?.play()
        }
        active = true

        // Mirror the remote track. Elapsed is the live-extrapolated position; rate 1 keeps the
        // lock-screen playhead advancing on its own between our 5s polls.
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: remote.item.name,
            MPMediaItemPropertyArtist: remote.item.primaryArtist,
            MPMediaItemPropertyAlbumTitle: remote.item.album ?? "",
            MPNowPlayingInfoPropertyElapsedPlaybackTime: remote.livePosition(at: Date()),
            MPMediaItemPropertyPlaybackDuration: remote.durationSeconds,
            MPNowPlayingInfoPropertyPlaybackRate: 1.0,
        ]
        // Keep the already-fetched artwork across refreshes of the same track.
        if artworkItemId == remote.item.id,
           let art = MPNowPlayingInfoCenter.default().nowPlayingInfo?[MPMediaItemPropertyArtwork] {
            info[MPMediaItemPropertyArtwork] = art
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if artworkItemId != remote.item.id {
            artworkItemId = remote.item.id
            guard let url = client.artworkURL(for: remote.item, size: 600) else { return }
            let itemId = remote.item.id
            Task { [weak self] in
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let image = UIImage(data: data) else { return }
                await MainActor.run {
                    guard let self, self.active, self.artworkItemId == itemId else { return }
                    var current = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
                    current[MPMediaItemPropertyArtwork] =
                        MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                    MPNowPlayingInfoCenter.default().nowPlayingInfo = current
                }
            }
        }
    }

    /// Stop the keepalive and hand the info center back — to the local track if one is loaded,
    /// else cleared.
    func disengage(player: Player) {
        guard active else { return }
        active = false
        artworkItemId = nil
        silence?.stop()
        if player.currentItem != nil {
            player.republishNowPlayingInfo()
        } else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        }
    }

    /// One second of silent 16-bit mono PCM in a WAV wrapper, looped forever at volume 0.
    private static func makeSilencePlayer() -> AVAudioPlayer? {
        var data = Data()
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        data.append(contentsOf: Array("data".utf8)); u32(dataSize)
        data.append(Data(count: Int(dataSize)))
        let p = try? AVAudioPlayer(data: data)
        p?.numberOfLoops = -1
        p?.volume = 0
        return p
    }
}
#endif
