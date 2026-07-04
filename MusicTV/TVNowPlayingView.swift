import SwiftUI

/// Shared Now Playing UI state — the nav bar's transport pill toggles the panes, the Now Playing page
/// renders them, so it lives outside both views.
@MainActor
@Observable
final class TVNowPlayingUI {
    static let shared = TVNowPlayingUI()
    enum Pane { case lyrics, queue }
    var pane: Pane? {
        didSet { bumpChrome() }
    }
    func toggle(_ p: Pane) { pane = (pane == p) ? nil : p }

    /// While a music video plays and the remote is idle, the nav bar hides (cinema mode) — any
    /// interaction brings it back. `chromeVisible` only ever goes false while a video is active.
    private(set) var chromeVisible = true
    @ObservationIgnored private var chromeIdle: Task<Void, Never>?

    /// Show the chrome and restart the idle countdown. Call on ANY remote interaction. The hide only
    /// fires if a video is still playing when the countdown lands (audio-only never hides the bar).
    func bumpChrome() {
        chromeVisible = true
        chromeIdle?.cancel()
        chromeIdle = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            if TVVideoController.shared.activeVideo != nil { chromeVisible = false }
        }
    }

    private init() {}
}

/// Now Playing for the TV — the skeuomorphic centrepiece, and nothing else: transport, progress and
/// the lyrics/queue buttons all live in the nav bar's mini-bar transport pill (like the iOS mini bar).
///
/// **Audio mode:** the queue as a big centered cover-flow carousel (3D cover, CD out and spinning,
/// reflection) over the artwork wash.
/// **Video mode:** the matched video fills the screen and the carousel docks bottom-left.
/// **Panes:** lyrics or the queue fill the centre while the artwork docks bottom-left.
struct TVNowPlayingView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    private var videoCtl: TVVideoController { TVVideoController.shared }
    private var inVideoMode: Bool { videoCtl.activeVideo != nil }
    private var ui: TVNowPlayingUI { TVNowPlayingUI.shared }

    var body: some View {
        Group {
            if videoCtl.direct {
                // Music Videos playlist: the video IS the content (its own audio). No audio carousel.
                Color.clear
            } else if SessionHub.shared.yieldedToRemote, let remote = SessionHub.shared.remote {
                // Another device took over playback (exclusive-playback rule) — mirror it.
                remoteMirror(remote)
            } else if let remote = SessionHub.shared.remote, !remote.isPaused, !player.isPlaying {
                // Another device is ACTIVELY playing and we're not — its live playback outranks
                // the locally-restored (paused) track.
                remoteMirror(remote)
            } else if player.currentItem != nil {
                // The skeuomorphic cover-flow carousel. Centred for plain audio; when a music video
                // is the backdrop OR a pane (lyrics/queue) is open it shrinks and DOCKS bottom-left.
                let docked = inVideoMode || ui.pane != nil
                ZStack {
                    TVNowPlayingArtwork(coverSize: docked ? 150 : 400, docked: docked,
                                        onInteract: { ui.bumpChrome() })
                        .frame(maxWidth: .infinity, maxHeight: .infinity,
                               alignment: docked ? .bottomLeading : .center)
                        .padding(.leading, docked ? 80 : 0)
                        .padding(.bottom, docked ? 40 : 0)
                        .animation(.spring(response: 0.5, dampingFraction: 0.86), value: docked)

                    if let pane = ui.pane {
                        paneView(pane)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: ui.pane)
            } else {
                VStack(spacing: 16) {
                    Image(systemName: "music.note")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(.secondary)
                    Text("Nothing playing")
                        .font(.title3).foregroundStyle(.secondary)
                    Text("Pick an album or playlist to start listening.")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onDisappear { ui.pane = nil }   // leaving the tab closes any open pane
        .background {
            ZStack {
                if inVideoMode, let av = videoCtl.avPlayer {
                    TVVideoLayer(player: av).ignoresSafeArea().transition(.opacity)
                } else {
                    // The artwork blurred into a colour wash — Now Playing and the detail views are
                    // the only artwork-tinted pages; browse pages stay system-theme.
                    TVBackdrop(item: player.currentItem ?? SessionHub.shared.remote?.item)
                }
                // A pane needs contrast over whatever's behind (especially a playing video).
                if ui.pane != nil {
                    Color.black.opacity(0.45).ignoresSafeArea().allowsHitTesting(false)
                }
            }
        }
        // Only the Music Videos PLAYLIST needs the screen itself to take focus (no carousel then):
        // trackpad swipes skip between its videos. Audio skips live on the carousel + transport pill.
        .focusable(videoCtl.direct)
        .onMoveCommand { direction in
            ui.bumpChrome()
            guard videoCtl.direct else { return }
            switch direction {
            case .left:  videoCtl.skipDirect(-1, client: client, audio: player)
            case .right: videoCtl.skipDirect(+1, client: client, audio: player)
            default: break
            }
        }
        // NOTE: video mode is owned by the APP ROOT (MusicTVApp evaluates on track/play changes), not
        // this view — so the video keeps playing in the background when you browse other pages. This
        // view only renders the current state; the fullscreen layer reattaches when you come back.
    }

    /// The open pane, centred in the free area while the artwork docks bottom-left. Bottom padding
    /// keeps its content clear of the docked cover.
    @ViewBuilder
    private func paneView(_ pane: TVNowPlayingUI.Pane) -> some View {
        Group {
            switch pane {
            case .lyrics: TVLyricsPane()
            case .queue:  TVQueuePane { ui.pane = nil }
            }
        }
        .frame(maxWidth: 1040)
        .frame(maxWidth: .infinity)
        .padding(.top, 130)   // clear the overlaid nav bar / transport pill
        .padding(.bottom, 60)
        .transition(.opacity.combined(with: .move(edge: .trailing)))
    }

    /// A remote session's Now Playing — SEAMLESS: the SAME skeuomorphic centrepiece as local playback
    /// (cover + slid-out spinning CD + reflection + label). The nav bar's Transfer pill is the only
    /// tell; the transport pill drives the remote device; the fill shows its live playhead.
    private func remoteMirror(_ remote: SessionHub.RemoteSession) -> some View {
        TVFlowCover(item: remote.item,
                    size: 400,
                    discOut: true,
                    spinning: !remote.isPaused,
                    showReflection: true,
                    emphasized: true)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
