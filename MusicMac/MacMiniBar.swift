import SwiftUI

/// The Mac mini player — the phone's mini bar grown up: a Liquid Glass capsule with the spinning CD,
/// title/artist, transport, and the artwork-wash fill revealed left→right AS the progress bar (no
/// separate strip). Click opens Now Playing; a remote session renders IDENTICALLY (seamless), the
/// controls just drive the other device.
struct MacMiniBar: View {
    @Binding var showNowPlaying: Bool
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @State private var width: CGFloat = 1
    @State private var hoveringScrub = false

    var body: some View {
        if let m = MacPillModel.current(player) {
            HStack(spacing: 12) {
                MacSpinningDisc(item: m.item, size: 40, spinning: m.spinning)
                    .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 1) {
                    Text(m.item.name).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                    if let sub = m.sub, !sub.isEmpty {
                        Text(sub).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: 300, alignment: .leading)

                Spacer(minLength: 12)

                HStack(spacing: 6) {
                    control("backward.fill") { m.previous(player) }
                    control(m.spinning ? "pause.fill" : "play.fill", size: 17) { m.togglePlayPause(player) }
                    control("forward.fill") { m.next(player) }
                }
            }
            .padding(.leading, 8)
            .padding(.trailing, 14)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity)
            // The artwork-gradient fill IS the progress bar, live (extrapolated for remote sessions).
            .background(alignment: .leading) {
                TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                    MacArtworkFill(item: m.item)
                        .frame(width: width)
                        .frame(maxHeight: .infinity)
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: max(0, width * m.progress(at: ctx.date, player)))
                        }
                }
                .allowsHitTesting(false)
            }
            .background {
                GeometryReader { g in
                    Color.clear.onChange(of: g.size.width, initial: true) { _, w in width = w }
                }
            }
            .clipShape(Capsule())
            .glassEffect(.regular, in: .capsule)
            .contentShape(Capsule())
            .onTapGesture { showNowPlaying = true }
            // Click anywhere along the bar with Option held (or drag on the fill) to seek locally.
            .gesture(scrubGesture(m))
        }
    }

    private func control(_ icon: String, size: CGFloat = 14, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Drag horizontally along the bar to scrub (local playback: live seek; remote: seek on release).
    private func scrubGesture(_ m: MacPillModel) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onEnded { v in
                let frac = min(max(v.location.x / max(width, 1), 0), 1)
                if let r = m.remote {
                    SessionHub.shared.seekRemote(to: frac * max(r.durationSeconds, 1))
                } else if player.duration > 0 {
                    player.seek(to: frac * player.duration)
                }
            }
    }
}

/// Now Playing for the Mac — the skeuomorphic centrepiece in a sheet: cover + slid-out spinning CD,
/// artwork wash behind, transport + playhead below. Remote sessions render the same (seamless).
struct MacNowPlayingView: View {
    @Environment(JellyfinClient.self) private var client
    @Environment(Player.self) private var player
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let m = MacPillModel.current(player) {
                VStack(spacing: 26) {
                    MacFlowCover(item: m.item, size: 300, discOut: true, spinning: m.spinning)
                        .padding(.trailing, 300 * MacSpinningDisc.pullOutRatio)
                        .padding(.top, 26)

                    VStack(spacing: 3) {
                        Text(m.item.name).font(.title3).fontWeight(.semibold).lineLimit(1)
                        if let sub = m.sub { Text(sub).font(.callout).foregroundStyle(.secondary) }
                    }

                    // Live playhead + times (extrapolated for remote sessions).
                    TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
                        let frac = m.progress(at: ctx.date, player)
                        let dur = m.remote.map { max($0.durationSeconds, 1) } ?? max(player.duration, 1)
                        VStack(spacing: 5) {
                            MacScrubBar(fraction: frac) { target in
                                if let r = m.remote { SessionHub.shared.seekRemote(to: target * max(r.durationSeconds, 1)) }
                                else { player.seek(to: target * max(player.duration, 1)) }
                            }
                            HStack {
                                Text((frac * dur).formattedDuration)
                                Spacer()
                                Text(dur.formattedDuration)
                            }
                            .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                        }
                        .frame(width: 420)
                    }

                    HStack(spacing: 30) {
                        npControl("backward.fill") { m.previous(player) }
                        npControl(m.spinning ? "pause.fill" : "play.fill", size: 26) { m.togglePlayPause(player) }
                        npControl("forward.fill") { m.next(player) }
                    }
                    .padding(.bottom, 26)
                }
                .frame(width: 620)
                .background {
                    // The artwork blurred into a wash — same backdrop language as the phone/TV.
                    LibraryImage(url: client.artworkURL(for: m.item, size: 400), maxPixel: 400) { Color.black }
                        .aspectRatio(contentMode: .fill)
                        .blur(radius: 80, opaque: true)
                        .saturation(1.3)
                        .overlay(Color.black.opacity(0.45))
                        .ignoresSafeArea()
                }
                .preferredColorScheme(.dark)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "music.note").font(.system(size: 40, weight: .ultraLight))
                    Text("Nothing playing").foregroundStyle(.secondary)
                }
                .frame(width: 420, height: 300)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(12)
        }
    }

    private func npControl(_ icon: String, size: CGFloat = 19, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .semibold))
                .frame(width: 46, height: 46)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }
}

/// A clickable/draggable playhead bar (macOS pointers make real scrubbing natural).
struct MacScrubBar: View {
    let fraction: Double
    let onSeek: (Double) -> Void
    @State private var drag: Double?
    @State private var hovering = false

    var body: some View {
        GeometryReader { g in
            let shown = drag ?? fraction
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Capsule().fill(.white.opacity(0.9))
                    .frame(width: max(4, g.size.width * shown))
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in drag = min(max(v.location.x / g.size.width, 0), 1) }
                    .onEnded { v in
                        let f = min(max(v.location.x / g.size.width, 0), 1)
                        drag = nil
                        onSeek(f)
                    }
            )
        }
        .frame(height: hovering || drag != nil ? 8 : 5)
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
    }
}
