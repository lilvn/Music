import SwiftUI
import AVKit
import MediaPlayer

/// System AirPlay / output-route picker (wraps `AVRoutePickerView`). `tint: .clear` makes it an
/// invisible tap target layered over the custom pill.
struct AirPlayButton: UIViewRepresentable {
    var tint: UIColor = .label
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.backgroundColor = .clear
        v.tintColor = tint
        v.activeTintColor = tint
        v.prioritizesVideoDevices = false
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {
        uiView.tintColor = tint
        uiView.activeTintColor = tint
    }
}

/// System volume slider (wraps `MPVolumeView`). Route button hidden — AirPlay lives in the pill.
/// Only functional on a real device; the simulator has no volume hardware.
struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView()
        v.showsRouteButton = false
        v.tintColor = .label
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Full Now Playing — presented as a `fullScreenCover` zoom-expanding from the mini player:
/// artwork, title, waveform scrubber, transport, volume slider, and a round Up Next / Lyrics pair
/// flanking a wide AirPlay pill. Shuffle / repeat live in the Up Next sheet.
struct NowPlayingView: View {
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    @Environment(\.dismiss) private var dismiss
    @State private var showQueue = false
    @State private var showLyrics = false

    /// Close the player, then ask RootTabView to navigate (so it doesn't open over the player).
    private func navigate(_ route: LibraryRoute) {
        player.pendingRoute = route
        dismiss()
    }

    private var seed: Int {
        (player.currentItem?.id ?? "x").unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    }

    /// A minimal album item for navigation; AlbumDetailView fetches full metadata by id.
    private var albumItem: MediaItem {
        let t = player.currentItem ?? .placeholder
        return MediaItem(id: t.albumId ?? t.id, name: t.album ?? t.name, type: "MusicAlbum",
                         sortName: nil, albumArtist: t.albumArtist, albumArtists: nil, album: nil, albumId: nil,
                         artistItems: t.artistItems, indexNumber: nil, parentIndexNumber: nil, runTimeTicks: nil,
                         productionYear: nil, imageTags: nil, albumPrimaryImageTag: nil, childCount: nil,
                         overview: nil, playlistItemId: nil)
    }

    private var artistRoute: LibraryRoute? {
        guard let a = player.currentItem?.artistItems?.first else { return nil }
        return .artist(MediaItem(id: a.id, name: a.name, type: "MusicArtist",
                                 sortName: nil, albumArtist: nil, albumArtists: nil, album: nil, albumId: nil,
                                 artistItems: nil, indexNumber: nil, parentIndexNumber: nil, runTimeTicks: nil,
                                 productionYear: nil, imageTags: nil, albumPrimaryImageTag: nil, childCount: nil,
                                 overview: nil, playlistItemId: nil))
    }

    var body: some View {
        @Bindable var player = player

        VStack(spacing: 0) {
            grabber
            Spacer(minLength: 8)
            albumArt
            Spacer(minLength: 26)
            trackInfo
            Spacer(minLength: 20)
            WaveformScrubber(
                currentTime: $player.currentTime,
                duration: player.duration,
                seed: seed,
                onScrubBegin: { player.beginScrubbing() },
                onScrubEnd: { player.endScrubbing(to: $0) },
                onTap: { player.seek(to: $0) }
            )
            Spacer(minLength: 24)
            mainControls
            Spacer(minLength: 22)
            volumeRow
            Spacer(minLength: 22)
            secondaryRow
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 28)
        .padding(.top, 10)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Cross-fade the art background between tracks instead of snapping.
        .background {
            CrossfadeBackground(url: client.artworkURL(for: player.currentItem ?? .placeholder, size: 400))
        }
        .onAppear { player.refreshOutputRoute() }
        .sheet(isPresented: $showQueue) {
            UpNextView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showLyrics) {
            LyricsView()
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var grabber: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 44, height: 36)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, alignment: .center)
    }

    private var albumArt: some View {
        // Corner radius scales with the (full-width) artwork, so the large now-playing art reads as
        // round as the smaller artwork elsewhere instead of looking nearly square.
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            LibraryImage(url: client.artworkURL(for: player.currentItem ?? .placeholder, size: 1000), maxPixel: 1000) {
                ArtworkPlaceholder()
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.1, style: .continuous))
            .shadow(color: .black.opacity(0.22), radius: 24, y: 14)
            .scaleEffect(player.isPlaying ? 1.0 : 0.9)
            .animation(.spring(response: 0.55, dampingFraction: 0.72), value: player.isPlaying)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .layoutPriority(1)
    }

    private var trackInfo: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(player.currentItem?.name ?? "Not Playing")
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(player.currentItem?.primaryArtist ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        // 3D-touch (long-press) the title/artist for View Album / View Artist — not a plain tap.
        .contextMenu {
            Button { navigate(.album(albumItem)) } label: { Label("Go to Album", systemImage: "square.stack") }
            if let artistRoute {
                Button { navigate(artistRoute) } label: { Label("Go to Artist", systemImage: "music.mic") }
            }
        }
    }

    private var mainControls: some View {
        HStack(spacing: 56) {
            Button { player.previousTrack() } label: {
                Image(systemName: "backward.fill").font(.system(size: 28))
            }
            .foregroundStyle(.primary)

            Button { player.togglePlayPause() } label: {
                Group {
                    if player.isLoading {
                        ProgressView()
                    } else {
                        Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 46))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: 52, height: 52)
            }
            .foregroundStyle(.primary)

            Button { player.nextTrack() } label: {
                Image(systemName: "forward.fill").font(.system(size: 28))
            }
            .foregroundStyle(.primary)
            .disabled(!player.canGoNext)
            .opacity(player.canGoNext ? 1 : 0.4)
        }
        .frame(maxWidth: .infinity)
    }

    /// System volume slider flanked by speaker glyphs (works on a real device).
    private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "speaker.fill").font(.caption).foregroundStyle(.secondary)
            VolumeSlider().frame(height: 30)
            Image(systemName: "speaker.wave.3.fill").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Round Up Next (left) and Lyrics (right) flanking a wide AirPlay pill.
    private var secondaryRow: some View {
        HStack(spacing: 14) {
            roundSecondary(icon: "quote.bubble") { showLyrics = true }
            airPlayPill
            roundSecondary(icon: "list.bullet") { showQueue = true }
        }
    }

    private func roundSecondary(icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 54, height: 54)
                .glassEffect(.regular.interactive(), in: .circle)
        }
        .buttonStyle(ScaleButtonStyle())
    }

    /// Wide pill showing the current output device; the whole pill opens the AirPlay menu (an
    /// invisible `AVRoutePickerView` is layered over the custom content).
    private var airPlayPill: some View {
        ZStack {
            HStack(spacing: 8) {
                Image(systemName: "airplayaudio")
                Text(player.outputRouteName).lineLimit(1)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .glassEffect(.regular.interactive(), in: .capsule)

            AirPlayButton(tint: .clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Waveform scrubber (hold to magnify + scrub; quick tap to jump)

struct WaveformScrubber: View {
    @Binding var currentTime: Double
    let duration: Double
    let seed: Int
    let onScrubBegin: () -> Void
    let onScrubEnd: (Double) -> Void
    let onTap: (Double) -> Void

    @State private var scrubbing = false
    @State private var scrubStart: Double = 0
    @State private var dragProgress: Double = 0
    @State private var bars: [CGFloat] = []
    @State private var tick = 0
    @State private var didHold = false

    private var progress: Double { duration > 0 ? min(max(currentTime / duration, 0), 1) : 0 }
    private var displayProgress: Double { scrubbing ? dragProgress : progress }
    private var displayTime: Double { displayProgress * duration }

    var body: some View {
        VStack(spacing: 14) {
            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let x = w * CGFloat(displayProgress)

                ZStack(alignment: .leading) {
                    barRow(color: .primary.opacity(0.2), height: h)
                    barRow(color: .primary, height: h)
                        .mask(alignment: .leading) { Rectangle().frame(width: max(0, x)) }

                    Capsule()
                        .fill(Color.red)
                        .frame(width: scrubbing ? 6 : 2, height: scrubbing ? h + 44 : h)
                        .shadow(color: .red.opacity(scrubbing ? 0.6 : 0), radius: 6)
                        .offset(x: min(max(x - (scrubbing ? 3 : 1), 0), w - (scrubbing ? 6 : 2)))
                        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: scrubbing)
                }
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.16, maximumDistance: 40)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            guard duration > 0 else { return }
                            if case .second(true, let drag) = value {
                                if !scrubbing { scrubbing = true; didHold = true; scrubStart = progress; dragProgress = progress; onScrubBegin() }
                                if let drag {
                                    dragProgress = min(max(scrubStart + drag.translation.width / w, 0), 1)
                                    let t = Int(dragProgress * 60)
                                    if t != tick { tick = t }
                                }
                            }
                        }
                        .onEnded { value in
                            if scrubbing, case .second(_, let drag?) = value {
                                _ = drag
                                onScrubEnd(dragProgress * duration)
                            }
                            scrubbing = false
                        }
                )
                .simultaneousGesture(
                    SpatialTapGesture()
                        .onEnded { value in
                            if !didHold, duration > 0 {
                                onTap(min(max(value.location.x / w, 0), 1) * duration)
                            }
                            didHold = false
                        }
                )
            }
            .frame(height: 56)

            HStack {
                Text(displayTime.formattedDuration)
                Spacer()
                Text("-\(max(0, duration - displayTime).formattedDuration)")
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .monospacedDigit()
        }
        .sensoryFeedback(trigger: scrubbing) { _, now in now ? .impact(weight: .heavy, intensity: 1.0) : nil }
        .sensoryFeedback(.selection, trigger: tick)
        .onAppear { regenerate() }
        .onChange(of: seed) { _, _ in regenerate() }
    }

    private func barRow(color: Color, height: CGFloat) -> some View {
        HStack(spacing: 2) {
            ForEach(bars.indices, id: \.self) { i in
                Capsule()
                    .fill(color)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(3, bars[i] * height))
            }
        }
        .frame(height: height)
    }

    private func regenerate() {
        var rng = seed == 0 ? 1 : seed
        var out: [CGFloat] = []
        for _ in 0..<54 {
            rng = (rng &* 1103515245 &+ 12345) & 0x7fffffff
            let v = Double(rng % 1000) / 1000.0
            out.append(CGFloat(0.2 + v * 0.8))
        }
        bars = out
    }
}
