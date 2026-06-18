import SwiftUI
import AVKit
import MediaPlayer

/// System AirPlay / output-route picker (wraps `AVRoutePickerView`). Use `tint: .clear` to make it
/// an invisible tap target layered over a custom pill.
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

/// System volume slider (wraps `MPVolumeView`). The route button is hidden — AirPlay lives in the
/// pill. Note: only functional on a real device; the simulator has no volume hardware.
struct VolumeSlider: UIViewRepresentable {
    func makeUIView(context: Context) -> MPVolumeView {
        let v = MPVolumeView()
        v.showsRouteButton = false
        v.tintColor = UIColor.label
        return v
    }
    func updateUIView(_ uiView: MPVolumeView, context: Context) {}
}

/// Now Playing — a standard sheet that slides up from the bottom and swipes down to close.
/// Up Next / Lyrics use the same presentation so the close behaviour is consistent.
struct NowPlayingView: View {
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var api: JellyfinAPI
    @State private var showQueue = false
    @State private var showLyrics = false
    @State private var detailRoute: LibraryRoute?
    @Namespace private var sheetZoom

    private var seed: Int {
        (player.currentItem?.id ?? "x").unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 18)
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
        .padding(.top, 12)
        .padding(.bottom, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background { Color(.systemBackground).ignoresSafeArea() }
        .fullScreenCover(isPresented: $showQueue) {
            QueueSheet()
                .background { Color(.systemBackground).ignoresSafeArea() }
                .navigationTransition(.zoom(sourceID: "queue", in: sheetZoom))
        }
        .fullScreenCover(isPresented: $showLyrics) {
            LyricsView()
                .background { Color(.systemBackground).ignoresSafeArea() }
                .navigationTransition(.zoom(sourceID: "lyrics", in: sheetZoom))
        }
        .fullScreenCover(item: $detailRoute) { route in
            NavigationStack {
                destinationView(for: route)
                    .cardNavigation()
                    .toolbar {
                        ToolbarItem(placement: .topBarLeading) {
                            Button { detailRoute = nil } label: {
                                Image(systemName: "chevron.down").fontWeight(.semibold)
                            }
                            .tint(.primary)
                        }
                    }
            }
        }
    }

    private var albumArt: some View {
        LibraryImage(url: api.artworkURL(for: player.currentItem ?? .placeholder, size: 1000), maxPixel: 1000) {
            Color(.secondarySystemBackground)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: 64, weight: .ultraLight))
                        .foregroundStyle(.tertiary)
                }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 24, y: 14)
        .scaleEffect(player.isPlaying ? 1.0 : 0.9)
        .animation(.spring(response: 0.55, dampingFraction: 0.72), value: player.isPlaying)
        .layoutPriority(1)   // claim space first so the added rows don't squeeze the artwork
    }

    private var trackInfo: some View {
        Menu {
            if player.currentItem?.albumId != nil {
                Button { goToAlbum() } label: { Label("Go to Album", systemImage: "square.stack") }
            }
            if player.currentItem?.artistItems?.first != nil {
                Button { goToArtist() } label: { Label("Go to Artist", systemImage: "music.mic") }
            }
        } label: {
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
        }
        .tint(.primary)
    }

    private func goToAlbum() {
        guard let id = player.currentItem?.albumId else { return }
        Task { if let item = try? await api.fetchItem(id: id) { detailRoute = .album(item) } }
    }

    private func goToArtist() {
        guard let id = player.currentItem?.artistItems?.first?.id else { return }
        Task { if let item = try? await api.fetchItem(id: id) { detailRoute = .artist(item) } }
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
            .disabled(!player.queue.hasNext)
            .opacity(player.queue.hasNext ? 1 : 0.4)
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
            roundSecondary(icon: "list.bullet", source: "queue") { showQueue = true }
            airPlayPill
            roundSecondary(icon: "quote.bubble", source: "lyrics") { showLyrics = true }
        }
    }

    private func roundSecondary(icon: String, source: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.primary)
                .frame(width: 54, height: 54)
                .background(Color(.secondarySystemBackground), in: .circle)
        }
        .buttonStyle(.plain)
        .matchedTransitionSource(id: source, in: sheetZoom)
    }

    /// Wide pill showing the current output device; the whole pill opens the AirPlay menu
    /// (an invisible `AVRoutePickerView` is layered over the custom content).
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
            .background(Color(.secondarySystemBackground), in: .capsule)

            AirPlayButton(tint: .clear)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

// MARK: - Waveform Scrubber

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

                    // Skinny red playhead — magnifies a lot while scrubbing.
                    Capsule()
                        .fill(Color.red)
                        .frame(width: scrubbing ? 6 : 2, height: scrubbing ? h + 44 : h)
                        .shadow(color: .red.opacity(scrubbing ? 0.6 : 0), radius: 6)
                        .offset(x: min(max(x - (scrubbing ? 3 : 1), 0), w - (scrubbing ? 6 : 2)))
                        .animation(.spring(response: 0.28, dampingFraction: 0.7), value: scrubbing)
                }
                .frame(width: w, height: h)
                .contentShape(Rectangle())
                // Hold to magnify + scrub relative to the playhead's position.
                .simultaneousGesture(
                    LongPressGesture(minimumDuration: 0.16, maximumDistance: 40)
                        .sequenced(before: DragGesture(minimumDistance: 0))
                        .onChanged { value in
                            guard duration > 0 else { return }
                            if case .second(true, let drag) = value {
                                if !scrubbing { scrubbing = true; didHold = true; scrubStart = progress; onScrubBegin() }
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
                // Quick tap jumps to that spot.
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

// MARK: - Lyrics

struct LyricsView: View {
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var api: JellyfinAPI
    @State private var lines: [LyricLine] = []
    @State private var loading = true

    private var synced: Bool { lines.contains { $0.seconds != nil } }

    private var activeIndex: Int? {
        guard synced else { return nil }
        let t = player.currentTime + 0.25
        return lines.lastIndex { ($0.seconds ?? .infinity) <= t }
    }

    var body: some View {
        Group {
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if lines.isEmpty {
                ContentUnavailableView("No Lyrics",
                                       systemImage: "quote.bubble",
                                       description: Text("No lyrics available for this track."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 18) {
                            Text(player.currentItem?.name ?? "Lyrics")
                                .font(.title).fontWeight(.bold)
                                .padding(.bottom, 4)
                            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                                let active = i == activeIndex
                                Text(line.text.isEmpty ? " " : line.text)
                                    .font(.title2).fontWeight(.bold)
                                    .foregroundStyle(active ? Color.primary : Color.secondary.opacity(synced ? 0.45 : 1))
                                    .scaleEffect(active ? 1.02 : 1, anchor: .leading)
                                    .animation(.easeInOut(duration: 0.25), value: active)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(i)
                                    .onTapGesture {
                                        if let s = line.seconds { player.seek(to: s) }
                                    }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 36)
                        .padding(.bottom, 80)
                        .killScrollBounce()
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: activeIndex) { _, idx in
                        guard let idx else { return }
                        withAnimation(.easeInOut(duration: 0.35)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                }
            }
        }
        .task {
            if let id = player.currentItem?.id {
                lines = (try? await api.fetchLyrics(itemId: id)) ?? []
            }
            loading = false
        }
    }
}

// MARK: - Up Next

struct QueueSheet: View {
    @EnvironmentObject var player: AudioPlayerManager
    @EnvironmentObject var api: JellyfinAPI

    var body: some View {
        ZStack(alignment: .bottom) {
            List {
                Section {
                    ForEach(Array(player.queue.items.enumerated()), id: \.offset) { index, item in
                        row(index: index, item: item)
                            .listRowInsets(EdgeInsets(top: 6, leading: 20, bottom: 6, trailing: 20))
                            .listRowSeparator(.hidden)
                            .contentShape(Rectangle())
                            .onTapGesture { player.play(at: index) }
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                if index != player.queue.currentIndex {
                                    Button(role: .destructive) {
                                        player.removeFromQueue(at: index)
                                    } label: { Label("Remove", systemImage: "minus.circle") }
                                }
                            }
                    }
                } header: {
                    Text("Up Next")
                        .font(.title2).fontWeight(.bold)
                        .foregroundStyle(.primary)
                        .textCase(nil)
                        .padding(.bottom, 4)
                        .killScrollBounce()
                }
                Color.clear.frame(height: 84)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .scrollIndicators(.hidden)
            .scrollContentBackground(.hidden)

            // Shuffle / repeat pinned to the bottom corners — behave like the lock-screen
            // flashlight: a glass circle that fills when on, with a firm-press depress + haptics.
            HStack {
                LockGlassButton(system: "shuffle", active: player.queue.isShuffled) {
                    player.toggleShuffle()
                }
                Spacer()
                LockGlassButton(system: player.queue.repeatMode.systemImage,
                                active: player.queue.repeatMode.isActive) {
                    player.cycleRepeat()
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 8)
        }
    }

    private func row(index: Int, item: MediaItem) -> some View {
        let isCurrent = index == player.queue.currentIndex
        return HStack(spacing: 14) {
            LibraryImage(url: api.artworkURL(for: item, size: 160), maxPixel: 180) {
                Color(.systemGray6)
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                if isCurrent {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.black.opacity(0.42))
                    Image(systemName: "waveform").foregroundStyle(.white)
                        .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: player.isPlaying)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(item.primaryArtist)
                    .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }

            Spacer()

            if let dur = item.durationSeconds {
                Text(dur.formattedDuration)
                    .font(.footnote).foregroundStyle(.tertiary).monospacedDigit()
            }
        }
        .padding(.vertical, 2)
    }

}

/// A circular glass toggle modeled on the lock-screen flashlight: glass when off, a bright
/// high-contrast fill when on, with a firm-press depress and heavy/selection haptics.
struct LockGlassButton: View {
    let system: String
    let active: Bool
    let action: () -> Void
    @State private var pressing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(active ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color(.secondarySystemBackground)))
                .shadow(color: .black.opacity(0.14), radius: 7, y: 2)
            Image(systemName: system)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(active ? AnyShapeStyle(Color(.systemBackground)) : AnyShapeStyle(.primary))
                .contentTransition(.symbolEffect(.replace))
        }
        .frame(width: 58, height: 58)
        .scaleEffect(pressing ? 0.84 : 1)
        .animation(.spring(response: 0.22, dampingFraction: 0.55), value: pressing)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: active)
        .contentShape(Circle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !pressing { pressing = true } }
                .onEnded { _ in pressing = false; action() }
        )
        // Firm "3D click": a sharp rigid impact on press-down, a heavy thunk on toggle.
        .sensoryFeedback(trigger: pressing) { _, now in
            now ? .impact(flexibility: .rigid, intensity: 1.0) : nil
        }
        .sensoryFeedback(trigger: active) { _, _ in .impact(weight: .heavy, intensity: 1.0) }
    }
}
