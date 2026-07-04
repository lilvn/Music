import AppKit
import SwiftUI

/// The notch "dynamic island" (Alcove-style): a borderless, always-on-top panel hugging the notch at
/// the top-center of the screen. While something plays (here or on another device — seamless), a
/// slim black wing peeks out under the camera housing with a tiny spinning CD; hover it and it
/// expands into a full player — artwork CD, title/artist, transport, and the artwork-wash fill as
/// the progress bar. Black-on-black so it reads as part of the notch, exactly like Alcove.
@MainActor
final class NotchHUD {
    static let shared = NotchHUD()
    private init() {}

    private var panel: NSPanel?
    private var poll: Timer?
    let model = NotchHUDModel()

    static let compactSize = NSSize(width: 320, height: 40)
    static let expandedSize = NSSize(width: 560, height: 170)

    func attach(client: JellyfinClient, player: Player) {
        guard panel == nil else { return }
        // Prefer the screen that actually has a notch; fall back to the main screen (the HUD still
        // works there — it just drops from the top edge).
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let screen else { return }

        let content = NotchHUDView(model: model)
            .environment(client)
            .environment(player)
        let host = NSHostingView(rootView: AnyView(content))

        let p = NSPanel(contentRect: NSRect(origin: .zero, size: Self.compactSize),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovable = false
        p.contentView = host
        panel = p
        model.onExpandChange = { [weak self] in self?.applyFrame() }
        applyFrame(on: screen)

        // Lightweight heartbeat: show the wing only while something is playing anywhere; also lets
        // the panel get out of the way (mouse-transparent) when idle.
        poll = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
            Task { @MainActor in NotchHUD.shared.tick(player: player) }
        }
        tick(player: player)
    }

    private func tick(player: Player) {
        guard let panel else { return }
        let active = MacPillModel.current(player) != nil
        if active {
            if !panel.isVisible { panel.orderFrontRegardless() }
            panel.ignoresMouseEvents = false
        } else {
            model.expanded = false
            panel.orderOut(nil)
        }
    }

    private func applyFrame(on target: NSScreen? = nil) {
        guard let panel else { return }
        let screen = target ?? panel.screen ?? NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
        guard let screen else { return }
        let size = model.expanded ? Self.expandedSize : Self.compactSize
        let frame = NSRect(x: screen.frame.midX - size.width / 2,
                           y: screen.frame.maxY - size.height,
                           width: size.width,
                           height: size.height)
        panel.setFrame(frame, display: true, animate: false)   // SwiftUI animates the content
    }
}

/// Hover/expansion state shared between the panel (frame) and the SwiftUI content (layout).
@MainActor
@Observable
final class NotchHUDModel {
    var expanded = false {
        didSet { onExpandChange?() }
    }
    @ObservationIgnored var onExpandChange: (() -> Void)?
}

/// The HUD content. Top-anchored: a compact wing normally, the full player when hovered.
struct NotchHUDView: View {
    let model: NotchHUDModel
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 0, bottomLeadingRadius: 16,
                               bottomTrailingRadius: 16, topTrailingRadius: 0, style: .continuous)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let m = MacPillModel.current(player) {
                Group {
                    if model.expanded {
                        expandedPlayer(m)
                    } else {
                        compactWing(m)
                    }
                }
                .background(Color.black)         // notch camouflage
                .clipShape(shape)
                .onHover { hovering in
                    withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
                        model.expanded = hovering
                    }
                }
            }
            Spacer(minLength: 0)                 // keep everything hugging the top edge
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }

    /// The idle wing: a slim black extension under the notch with a tiny CD + live level dots.
    private func compactWing(_ m: MacPillModel) -> some View {
        HStack {
            MacSpinningDisc(item: m.item, size: 22, spinning: m.spinning)
                .padding(.leading, 14)
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .symbolEffect(.variableColor.iterative, isActive: m.spinning)
                .padding(.trailing, 16)
        }
        .frame(width: NotchHUD.compactSize.width, height: NotchHUD.compactSize.height - 4)
    }

    /// The hovered player: CD + title/artist + transport, with the artwork fill as the playhead.
    private func expandedPlayer(_ m: MacPillModel) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 14) {
                MacSpinningDisc(item: m.item, size: 64, spinning: m.spinning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(m.item.name).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                    if let sub = m.sub, !sub.isEmpty {
                        Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 10)
                HStack(spacing: 8) {
                    hudControl("backward.fill") { m.previous(player) }
                    hudControl(m.spinning ? "pause.fill" : "play.fill", size: 17) { m.togglePlayPause(player) }
                    hudControl("forward.fill") { m.next(player) }
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)

            // Playhead: the artwork wash revealed left→right (live for remote sessions too),
            // clickable to seek.
            TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                let frac = m.progress(at: ctx.date, player)
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.18))
                        MacArtworkFill(item: m.item)
                            .frame(width: g.size.width)
                            .mask(alignment: .leading) {
                                Capsule().frame(width: max(4, g.size.width * frac))
                            }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0).onEnded { v in
                            let f = min(max(v.location.x / g.size.width, 0), 1)
                            if let r = m.remote { SessionHub.shared.seekRemote(to: f * max(r.durationSeconds, 1)) }
                            else if player.duration > 0 { player.seek(to: f * player.duration) }
                        }
                    )
                }
                .frame(height: 6)
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 16)
        }
        .frame(width: NotchHUD.expandedSize.width)
    }

    private func hudControl(_ icon: String, size: CGFloat = 13, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 30, height: 30)
                .background(Circle().fill(.white.opacity(0.10)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}
