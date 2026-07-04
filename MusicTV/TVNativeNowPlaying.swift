import SwiftUI
import AVKit

/// The NATIVE tvOS Now Playing: an AVPlayerViewController wired to the engine's AVQueuePlayer, so the
/// scrubber, play/pause feedback, time labels and the swipe-down info panel (Lyrics / Up Next) are all
/// the system's own — while OUR visuals ride in the content overlay:
///
/// - **Audio:** the skeuomorphic cover + slid-out spinning CD centred over the artwork wash.
/// - **Matched music video:** the muted video backdrop fills the screen (audio stays authoritative —
///   the native scrubber scrubs the SONG) with the artwork docked bottom-left.
/// - **Direct Music Videos playlist:** the video player itself goes native — full system video UX.
struct TVNativePlayer: UIViewControllerRepresentable {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()

        // Our skeuomorphic layer, between the video content and the native transport chrome.
        let overlay = UIHostingController(rootView: AnyView(
            TVNativeOverlay().environment(client).environment(player)
        ))
        overlay.view.backgroundColor = .clear
        if let host = vc.contentOverlayView {
            overlay.view.frame = host.bounds
            overlay.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            host.addSubview(overlay.view)
        }
        context.coordinator.overlay = overlay

        // The native swipe-down info panel: Lyrics + Up Next as system tabs.
        let lyrics = UIHostingController(rootView: AnyView(
            TVLyricsPane().environment(client).environment(player)
        ))
        lyrics.title = "Lyrics"
        let queue = UIHostingController(rootView: AnyView(
            TVQueuePane().environment(client).environment(player)
        ))
        queue.title = "Up Next"
        vc.customInfoViewControllers = [lyrics, queue]

        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        let ctl = TVVideoController.shared
        // Direct playlist → the video player goes native (system video transport). Everything else →
        // the audio engine's player (the scrubber drives the SONG; a matched video is just visuals).
        let target: AVPlayer? = ctl.direct ? ctl.avPlayer : player.nativeAVPlayer
        if vc.player !== target { vc.player = target }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    final class Coordinator {
        var overlay: UIViewController?
    }
}

/// The visuals over the native player: pure chrome, never takes input (the system transport owns the
/// remote).
private struct TVNativeOverlay: View {
    @Environment(Player.self) private var player
    private var videoCtl: TVVideoController { TVVideoController.shared }

    var body: some View {
        ZStack {
            if videoCtl.direct {
                // The native VC is rendering the video itself — nothing to add.
                Color.clear
            } else if videoCtl.activeVideo != nil, let av = videoCtl.avPlayer {
                // Matched video: muted backdrop fills the screen; artwork docks bottom-left,
                // lifted above where the native transport rises.
                TVVideoLayer(player: av)
                    .ignoresSafeArea()
                if let item = player.currentItem {
                    TVFlowCover(item: item, size: 150, discOut: true,
                                spinning: player.isPlaying,
                                showReflection: false, emphasized: true)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                        .padding(.leading, 80)
                        .padding(.bottom, 150)
                }
            } else if let item = player.currentItem {
                // Plain audio: the skeuomorphic centrepiece over the artwork wash.
                TVBackdrop(item: item)
                TVFlowCover(item: item, size: 380, discOut: true,
                            spinning: player.isPlaying,
                            showReflection: true, emphasized: true)
                    .padding(.trailing, 380 * TVSpinningDisc.pullOutRatio)
                    .padding(.bottom, 70)   // breathing room above the native transport
            } else {
                TVBackdrop(item: nil)
            }
        }
        .allowsHitTesting(false)
    }
}
