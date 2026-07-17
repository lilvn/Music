import SwiftUI

/// A custom Liquid-Glass mini bar (shown above the tab bar only while a track is loaded — see
/// RootTabView). The CD + title page horizontally like Apple Music: swipe and the previous/next
/// track's strip follows your finger and commits on release; the skip buttons use the same slide.
/// Long-press anywhere and drag to scrub; tap to open Now Playing.
struct MiniPlayer: View {
    let namespace: Namespace.ID
    /// The app's TRUE light/dark theme (passed from RootTabView). The Liquid Glass accessory adapts its
    /// local appearance to the backdrop as you navigate, which made `Color(.systemBackground)` flip
    /// light/dark; resolving against this fixed value keeps the gradient/text stable.
    var appColorScheme: ColorScheme = .light
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    /// `.inline` when the tab bar has collapsed and the mini bar is sharing that row; `.expanded`
    /// when it's the full-width bar. Drives which controls fit.
    @Environment(\.tabViewBottomAccessoryPlacement) private var accessoryPlacement
    private var minimized: Bool { accessoryPlacement == .inline }

    @State private var width: CGFloat = 1
    @State private var scrubbing = false
    @State private var scrubStart: Double = 0
    @State private var dragProgress: Double = 0
    @State private var scrubWasPlaying = false
    @State private var tick = 0
    /// Set the instant a scrub engages, so a horizontal flick is ignored after a scrub (the two
    /// gestures' `onEnded` can fire in either order).
    @State private var didScrubThisDrag = false
    /// Interactive paging offset (the strip trails the finger); a commit animates it to ±width.
    @State private var dragX: CGFloat = 0
    /// A commit slide is in flight — locks out new drags/skips until it lands.
    @State private var paging = false

    private var progress: Double {
        player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
    }
    private var displayProgress: Double { scrubbing ? dragProgress : progress }
    private var cdOut: Bool { player.isPlaying || scrubbing }

    var body: some View {
        let item = player.currentItem ?? .placeholder
        ZStack {
            // Pageable now-playing strips (CD + title): current, plus whichever neighbour the drag
            // reveals, sliding in from the edge. Masked so the title fades out under the controls.
            ZStack(alignment: .leading) {
                // Keyed by track id so a strip's view (and its already-loaded artwork) is PRESERVED
                // when it becomes the current track on commit — otherwise a not-yet-cached next track
                // re-creates its image view and flashes a placeholder for a frame.
                ForEach(pages(cur: item)) { page in
                    strip(page.track, current: page.current).offset(x: page.offset)
                }
            }
            .mask(stripsMask)

            // Controls — fixed on the right, above the sliding strips. When minimized into the tab-bar
            // row there's only room for one control, so show just play/pause; prev/next return when the
            // bar expands back to full width.
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                if !minimized {
                    control("backward.fill") { skip(forward: false) }
                }
                playPause
                if !minimized {
                    control("forward.fill") { skip(forward: true) }
                        .disabled(!player.canGoNext)
                        .opacity(player.canGoNext ? 1 : 0.3)
                }
            }
            // During a scrub the whole bar is the scrubber — stop the transport buttons from
            // catching the drag as a tap (an accidental skip / play-pause).
            .allowsHitTesting(!scrubbing)
        }
        .foregroundStyle(.primary)
        // Leading inset centres the 40pt CD in the capsule's semicircular end cap: (H − 40)/2, i.e. 8
        // in the 56pt expanded bar, ~4 in the shorter collapsed row. Driven by the DISCRETE placement,
        // NOT a GeometryReader-measured height — measuring the height while the bar animates its resize
        // formed a measure→setState→re-animate feedback loop that made the CD lag and drift before
        // settling. A discrete value just springs cleanly from 8 to 4.
        .padding(.leading, minimized ? 4 : 8)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Progress fill = the dynamic artwork gradient, toned toward the system background, revealed
        // left→right as the track plays.
        .background(alignment: .leading) {
            ArtworkGradient(url: client.artworkURL(for: item, size: 160), blur: 20)
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .overlay((appColorScheme == .dark ? Color.black : Color.white).opacity(0.34))
                .opacity(scrubbing ? 0.95 : 0.82)
                .mask(alignment: .leading) {
                    Rectangle()
                        .frame(width: max(0, width * displayProgress))
                        .animation(scrubbing ? nil : .linear(duration: 0.5), value: displayProgress)
                }
                .allowsHitTesting(false)
        }
        .background { GeometryReader { g in Color.clear.onChange(of: g.size.width, initial: true) { _, w in width = w } } }
        // The tabViewBottomAccessory supplies the Liquid Glass; we only clip our own progress fill.
        .clipShape(Capsule())
        .contentShape(Capsule())
        .matchedTransitionSource(id: "np", in: namespace)
        .onTapGesture { if abs(dragX) < 1 { player.showNowPlaying = true } }
        .simultaneousGesture(scrubGesture)
        .simultaneousGesture(pageGesture)
        .sensoryFeedback(trigger: scrubbing) { _, now in now ? .impact(weight: .heavy, intensity: 1.0) : nil }
        .sensoryFeedback(.selection, trigger: tick)
        // Lock the bar to the app's TRUE theme (the glass accessory's local appearance can flip).
        .environment(\.colorScheme, appColorScheme)
    }

    /// One now-playing strip: the spinning CD + title for a track. Both current and neighbour share the
    /// persistent spin so the CD keeps turning continuously across a commit (no snap); only the current
    /// strip tracks a scrub.
    private func strip(_ item: MediaItem, current: Bool) -> some View {
        HStack(spacing: 10) {
            SpinningDisc(artURL: client.artworkURL(for: item, size: 160),
                         size: 40,
                         spinning: cdOut,
                         scrubProgress: current && scrubbing ? dragProgress : nil,
                         persistentSpin: .miniBar,
                         // Freeze the spin while the bar is compact/compacting: a live rotation fights
                         // the tab-bar collapse morph and glitches. Off-screen neighbours don't spin either.
                         animating: (current || dragX != 0) && !minimized)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                Text(item.primaryArtist).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        // Reserve room for the controls on the right. Minimized shows only play/pause (~46pt with its
        // inset), so the title reclaims the rest of what the prev/next buttons used to take.
        .padding(.trailing, minimized ? 46 : 104)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The strips to render: the current track, plus whichever neighbour the drag reveals. Identified by
    /// track id so the neighbour's view survives becoming the current one on commit.
    private struct Page: Identifiable {
        let track: MediaItem
        let offset: CGFloat
        let current: Bool
        var id: String { track.id }
    }

    private func pages(cur: MediaItem) -> [Page] {
        // Always include both neighbours (parked off-screen at ±width). On a BUTTON skip they then slide
        // in rather than INSERTING mid-animation (which fades them, looking glitchy), and their artwork
        // is already loaded — so skipping to a not-yet-cached track no longer flashes a placeholder.
        var result = [Page(track: cur, offset: dragX, current: true)]
        if let next = player.upcomingItem, next.id != cur.id {
            result.append(Page(track: next, offset: dragX + width, current: false))
        }
        if let prev = player.previousItem, prev.id != cur.id {
            result.append(Page(track: prev, offset: dragX - width, current: false))
        }
        return result
    }

    /// Opaque over the CD + title, fading to clear under the controls on the right. When minimized the
    /// clear zone shrinks to just the play/pause button and the fade shortens, so the title stays
    /// crisp much closer to the button and shows more.
    private var stripsMask: some View {
        HStack(spacing: 0) {
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: minimized ? 16 : 26)
            Color.clear.frame(width: minimized ? 44 : 100)
        }
    }

    private var scrubGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.2, maximumDistance: 22)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                guard player.duration > 0 else { return }
                if case .second(true, let drag) = value {
                    if !scrubbing {
                        scrubbing = true
                        didScrubThisDrag = true
                        scrubStart = progress
                        dragProgress = progress
                        scrubWasPlaying = player.isPlaying
                        // Anchor the CD's scrub rotation to its current angle synchronously, BEFORE the
                        // first scrubbed frame renders — otherwise it reads a stale anchor and jumps.
                        DiscSpinState.miniBar.beginScrub(progress: progress, now: Date())
                        player.beginScrubbing()
                    }
                    if let drag {
                        dragProgress = min(max(scrubStart + drag.translation.width / width, 0), 1)
                        player.updateScrubbing(progress: dragProgress)
                        let t = Int(dragProgress * 40)
                        if t != tick { tick = t }
                    }
                }
            }
            .onEnded { _ in
                if scrubbing { player.endScrubbing(to: dragProgress * player.duration) }
                scrubbing = false
            }
    }

    /// Drag the now-playing strip horizontally to page tracks (left → next, right → previous). A
    /// deliberate hold-then-drag is a scrub instead (`didScrubThisDrag` suppresses paging then).
    private var pageGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard !scrubbing, !didScrubThisDrag, !paging else { return }
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                var dx = value.translation.width
                if dx < 0, player.upcomingItem == nil { dx *= 0.2 }   // rubber-band with no neighbour
                if dx > 0, player.previousItem == nil { dx *= 0.2 }
                dragX = dx
            }
            .onEnded { value in
                let wasScrub = didScrubThisDrag
                didScrubThisDrag = false
                guard !wasScrub, !scrubbing else { springBack(); return }
                let dx = value.translation.width, dy = value.translation.height
                let horizontal = abs(dx) > abs(dy) * 1.2
                let threshold = max(60, width * 0.26)
                if horizontal, dx < -threshold, player.upcomingItem != nil {
                    commit(forward: true)
                } else if horizontal, dx > threshold, player.previousItem != nil {
                    commit(forward: false)
                } else {
                    springBack()
                }
            }
    }

    private func springBack() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) { dragX = 0 }
    }

    /// Skip via a button — uses the same slide as the swipe so it never snaps.
    private func skip(forward: Bool) {
        guard !paging else { return }
        if forward {
            guard player.canGoNext else { return }
            guard player.upcomingItem != nil else { player.nextTrack(); return }   // wrap/edge: no preview
        } else if player.previousItem == nil {
            player.previousTrack()   // no previous track → restart current
            return
        }
        commit(forward: forward)
    }

    /// Slide the strip fully aside, then advance the player and snap the offset back with no animation,
    /// so the freshly-current track is exactly where the neighbour preview just landed — seamless.
    private func commit(forward: Bool) {
        paging = true
        withAnimation(.spring(response: 0.34, dampingFraction: 0.9)) {
            dragX = forward ? -width : width
        } completion: {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) {
                if forward { player.nextTrack() } else { player.goPrevious() }
                dragX = 0
            }
            paging = false
        }
    }

    @ViewBuilder
    private var playPause: some View {
        Button { player.togglePlayPause() } label: {
            Group {
                if player.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 34, height: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func control(_ system: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
