import SwiftUI

// The tvOS port of the app's ONE bespoke element: the skeuomorphic iTunes-style cover flow, here as
// the Now Playing queue carousel. 3D-rotated covers, the current track's cover slides aside with a
// reflective spinning CD pulled out, and a faded reflection below — same visual language and geometry
// as the iPhone's Featured shelf (CoverFlow.swift), rebuilt focus-first for the 10-foot UI.

// MARK: - Spinning CD

struct TVSpinningDisc: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    let size: CGFloat
    let spinning: Bool

    // Same geometry + speed as the iPhone disc, so the two feel like the same object.
    static let diameterRatio: CGFloat = 0.9
    static let pullOutRatio: CGFloat = 0.3
    static let spinSpeed: Double = 48   // degrees / second

    @State private var base: Double = 0
    @State private var ref: Date?

    private var artURL: URL? { client.artworkURL(for: item, size: 400) }

    var body: some View {
        // Branch instead of `.animation(paused:)`: a paused animation TimelineView didn't render at
        // all on tvOS in testing — the still disc draws directly, the TimelineView only while spinning.
        Group {
            if spinning {
                TimelineView(.animation) { context in
                    disc.rotationEffect(.degrees(angle(at: context.date)))
                }
            } else {
                disc.rotationEffect(.degrees(base))
            }
        }
        .onAppear { reconcile(Date()) }
        .onChange(of: spinning) { _, _ in reconcile(Date()) }
    }

    private func angle(at date: Date) -> Double {
        if spinning, let ref { return base + date.timeIntervalSince(ref) * Self.spinSpeed }
        return base
    }

    /// Fold elapsed rotation into `base` when the spin starts/stops so the angle never jumps.
    private func reconcile(_ now: Date) {
        if spinning, ref == nil {
            ref = now
        } else if !spinning, let r = ref {
            base += now.timeIntervalSince(r) * Self.spinSpeed
            ref = nil
        }
    }

    private var disc: some View {
        let rim = max(0.5, size * 0.012)
        return ZStack {
            // Disc body: the artwork blurred into a soft colour wash (the TV equivalent of
            // ArtworkGradient, which lives in the iOS-only Components file).
            LibraryImage(url: artURL, maxPixel: 200) { Color(white: 0.16) }
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .blur(radius: size * 0.14, opaque: true)
                .saturation(1.4)
                .clipShape(Circle())

            // Doming + edge vignette so it reads as a physical disc.
            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: .white.opacity(0.22), location: 0.0),
                    .init(color: .white.opacity(0.0),  location: 0.40),
                    .init(color: .clear,               location: 0.72),
                    .init(color: .black.opacity(0.28), location: 1.0),
                ], center: .center, startRadius: 0, endRadius: size * 0.5))

            Circle().strokeBorder(.white.opacity(0.28), lineWidth: rim)
            Circle().strokeBorder(.black.opacity(0.22), lineWidth: rim).padding(rim)

            // Crisp centre label.
            LibraryImage(url: artURL, maxPixel: 240) { TVPlaceholder() }
                .frame(width: size * 0.42, height: size * 0.42)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: rim))

            // Hub + spindle hole.
            Circle().fill(.black).frame(width: size * 0.14, height: size * 0.14)
            Circle().strokeBorder(.white.opacity(0.28), lineWidth: max(0.5, rim * 0.7))
                .frame(width: size * 0.14, height: size * 0.14)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: size * 0.025, y: size * 0.012)
    }
}

// MARK: - One carousel cover (cover + slide-out CD + reflection)

struct TVFlowCover: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    let size: CGFloat
    let isCurrent: Bool
    let spinning: Bool
    /// Reflection is shown in the big centered mode, trimmed off in the docked (video) mode.
    var showReflection = true

    private var artworkStack: some View {
        ZStack {
            TVSpinningDisc(item: item, size: size * TVSpinningDisc.diameterRatio, spinning: spinning)
                .offset(x: isCurrent ? size * TVSpinningDisc.pullOutRatio : 0)
                .opacity(isCurrent ? 1 : 0)

            cover
                .offset(x: isCurrent ? -size * 0.1 : 0)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.55, dampingFraction: 0.74), value: isCurrent)
    }

    var body: some View {
        VStack(spacing: 0) {
            artworkStack

            if showReflection {
                let fraction: CGFloat = 0.30
                artworkStack
                    .scaleEffect(y: -1)
                    .frame(height: size * fraction, alignment: .top)
                    .mask(
                        LinearGradient(colors: [.white.opacity(0.18), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .frame(width: size * 2.4, height: size * fraction)
                    )
                    .allowsHitTesting(false)
            }
        }
        .frame(width: size)
    }

    private var cover: some View {
        LibraryImage(url: client.artworkURL(for: item, size: 600), maxPixel: 600) { TVPlaceholder() }
            .aspectRatio(1, contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.white.opacity(0.14), lineWidth: 0.5)
            )
            .overlay(alignment: .top) {
                // Glass-catch light along the top edge — same as the phone's covers.
                LinearGradient(colors: [.white.opacity(0.28), .clear],
                               startPoint: .top, endPoint: .center)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.35), radius: 18, y: 10)
    }
}

// MARK: - The queue carousel

/// The Now Playing queue as an iTunes-style cover flow driven directly by the remote — the exact feel
/// of the iPhone's Featured shelf. The CENTER cover IS the now-playing track (centre = selected, so no
/// focus platter/highlight): swiping left/right on the remote changes tracks, the flow springs across,
/// and the CD stays slid out under the centre cover. Select toggles play/pause.
///
/// No per-cover Buttons: positions derive from each item's distance to the current index, so the
/// carousel is a pure function of the queue — nothing for the focus engine to decorate.
struct TVQueueCarousel: View {
    @Environment(Player.self) private var player
    let coverSize: CGFloat
    var showReflection = true
    @FocusState private var focused: Bool

    var body: some View {
        let items = player.queue.items
        let current = player.queue.currentIndex

        ZStack {
            ForEach(visibleRange(count: items.count, current: current), id: \.self) { i in
                let rel = i - current
                TVFlowCover(item: items[i],
                            size: coverSize,
                            isCurrent: rel == 0,
                            spinning: rel == 0 && player.isPlaying,
                            showReflection: showReflection)
                    .scaleEffect(rel == 0 ? 1 : 0.74)
                    .rotation3DEffect(.degrees(rel == 0 ? 0 : (rel < 0 ? 44 : -44)),
                                      axis: (x: 0, y: 1, z: 0),
                                      anchor: .center, perspective: 0.45)
                    .offset(x: xOffset(rel))
                    .brightness(rel == 0 ? 0 : -0.07)     // side covers recede, centre reads as "selected"
                    .opacity(abs(rel) >= 5 ? 0 : 1)       // fade out at the stack's ends
                    .zIndex(Double(50 - abs(rel)))        // centre above its neighbours
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: coverSize * (showReflection ? 1.34 : 1.06))
        .contentShape(Rectangle())
        .focusable()
        .focused($focused)
        .scaleEffect(focused ? 1.02 : 1.0)   // the whole flow breathes subtly when the remote is on it
        .onMoveCommand { direction in
            switch direction {
            case .left where current > 0:
                player.play(at: current - 1)
            case .right where current < items.count - 1:
                player.play(at: current + 1)
            case .up, .down:
                focused = false   // hand focus back to the rest of the screen (tab bar)
            default:
                break
            }
        }
        .onTapGesture { player.togglePlayPause() }   // remote click on the flow = play/pause
        .animation(.spring(response: 0.55, dampingFraction: 0.78), value: current)
        .animation(.easeOut(duration: 0.2), value: focused)
    }

    /// Only lay out the covers near the centre — a 2,000-song queue must not build 2,000 views.
    private func visibleRange(count: Int, current: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        return max(0, current - 5)..<min(count, current + 6)
    }

    /// Classic cover-flow spacing: a clear gap to the first neighbour, then a tight overlapped stack.
    private func xOffset(_ rel: Int) -> CGFloat {
        guard rel != 0 else { return 0 }
        let first = coverSize * 0.74
        let step = coverSize * 0.30
        return CGFloat(rel.signum()) * (first + CGFloat(abs(rel) - 1) * step)
    }
}
