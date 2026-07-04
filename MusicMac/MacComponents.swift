import SwiftUI

// The Mac port of the app's design language: Liquid Glass chrome, the skeuomorphic spinning CD
// pulled out of the cover, and the artwork-wash fill AS the progress bar. Corner radii match the
// iPhone/TV DS so covers read the same everywhere.

enum MacDS {
    static let cover: CGFloat = 8      // album / playlist covers
    static let artwork: CGFloat = 12   // large artwork (detail header, now playing)
    static let thumb: CGFloat = 6      // row thumbnails
}

/// Artwork placeholder for items with no cover — gradient panel + a quiet mark.
struct MacPlaceholder: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(white: 0.22), Color(white: 0.12)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: "music.note")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.white.opacity(0.55))
        }
    }
}

// MARK: - Spinning CD (same geometry + speed as the iPhone/TV discs)

struct MacSpinningDisc: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    let size: CGFloat
    let spinning: Bool

    static let diameterRatio: CGFloat = 0.9
    static let pullOutRatio: CGFloat = 0.3
    static let spinSpeed: Double = 48   // degrees / second

    @State private var base: Double = 0
    @State private var ref: Date?

    private var artURL: URL? { client.artworkURL(for: item, size: 400) }

    var body: some View {
        Group {
            if spinning {
                TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
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
            LibraryImage(url: artURL, maxPixel: 200) { Color(white: 0.16) }
                .aspectRatio(contentMode: .fill)
                .frame(width: size, height: size)
                .blur(radius: size * 0.14, opaque: true)
                .saturation(1.4)
                .clipShape(Circle())

            Circle()
                .fill(RadialGradient(stops: [
                    .init(color: .white.opacity(0.22), location: 0.0),
                    .init(color: .white.opacity(0.0),  location: 0.40),
                    .init(color: .clear,               location: 0.72),
                    .init(color: .black.opacity(0.28), location: 1.0),
                ], center: .center, startRadius: 0, endRadius: size * 0.5))

            Circle().strokeBorder(.white.opacity(0.28), lineWidth: rim)
            Circle().strokeBorder(.black.opacity(0.22), lineWidth: rim).padding(rim)

            LibraryImage(url: artURL, maxPixel: 240) { MacPlaceholder() }
                .frame(width: size * 0.42, height: size * 0.42)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.45), lineWidth: rim))

            Circle().fill(.black).frame(width: size * 0.14, height: size * 0.14)
            Circle().strokeBorder(.white.opacity(0.28), lineWidth: max(0.5, rim * 0.7))
                .frame(width: size * 0.14, height: size * 0.14)
        }
        .frame(width: size, height: size)
        .compositingGroup()
        .shadow(color: .black.opacity(0.25), radius: size * 0.025, y: size * 0.012)
    }
}

/// Cover + slid-out spinning CD — the skeuomorphic centrepiece, hover-lifted like the TV's focus.
struct MacFlowCover: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    let size: CGFloat
    var discOut = true
    var spinning = false

    var body: some View {
        ZStack {
            MacSpinningDisc(item: item, size: size * MacSpinningDisc.diameterRatio, spinning: spinning)
                .offset(x: discOut ? size * MacSpinningDisc.pullOutRatio : 0)
                .opacity(discOut ? 1 : 0)

            LibraryImage(url: client.artworkURL(for: item, size: 600), maxPixel: 600) { MacPlaceholder() }
                .aspectRatio(1, contentMode: .fill)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: MacDS.cover, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: MacDS.cover, style: .continuous)
                        .stroke(.white.opacity(0.14), lineWidth: 0.5)
                )
                .overlay(alignment: .top) {
                    LinearGradient(colors: [.white.opacity(0.28), .clear],
                                   startPoint: .top, endPoint: .center)
                        .clipShape(RoundedRectangle(cornerRadius: MacDS.cover, style: .continuous))
                        .allowsHitTesting(false)
                }
                .shadow(color: .black.opacity(0.35), radius: 14, y: 8)
                .offset(x: discOut ? -size * 0.1 : 0)
        }
        .frame(width: size, height: size)
        .animation(.spring(response: 0.42, dampingFraction: 0.72), value: discOut)
    }
}

// MARK: - Cover card / shelf (hover lifts, like focus on tvOS)

struct MacCoverCard: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    var subtitle: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button(action: action) {
                LibraryImage(url: client.artworkURL(for: item, size: 600), maxPixel: 600) {
                    MacPlaceholder()
                }
                .aspectRatio(1, contentMode: .fill)
                .clipShape(RoundedRectangle(cornerRadius: MacDS.cover, style: .continuous))
                .shadow(color: .black.opacity(hovering ? 0.35 : 0.15), radius: hovering ? 14 : 6, y: hovering ? 8 : 3)
                .scaleEffect(hovering ? 1.04 : 1.0)
                .animation(.easeOut(duration: 0.15), value: hovering)
            }
            .buttonStyle(.plain)
            .onHover { hovering = $0 }

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).font(.callout).lineLimit(1)
                Text(subtitle ?? item.primaryArtist)
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// Horizontal shelf with a section title — the Home building block.
struct MacShelf: View {
    let title: String
    let items: [MediaItem]
    var subtitle: ((MediaItem) -> String)? = nil
    let action: (MediaItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3).fontWeight(.semibold)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 20) {
                    ForEach(items) { item in
                        MacCoverCard(item: item, subtitle: subtitle?(item), action: { action(item) })
                            .frame(width: 168)
                    }
                }
                .padding(.vertical, 10)   // room for the hover lift
            }
            .scrollClipDisabled()
        }
    }
}

/// A blurred wash of the artwork — fills the mini bar / HUD left→right AS the progress bar.
struct MacArtworkFill: View {
    @Environment(JellyfinClient.self) private var client
    let item: MediaItem
    var body: some View {
        LibraryImage(url: client.artworkURL(for: item, size: 160), maxPixel: 160) { Color(white: 0.2) }
            .aspectRatio(contentMode: .fill)
            .blur(radius: 24, opaque: true)
            .saturation(1.4)
            .overlay(Color.black.opacity(0.30))   // keep white text legible over it
    }
}

// MARK: - The seamless "what's playing" model (local or another device — identical UI)

/// Mirrors the iOS/tvOS priority: an ACTIVELY playing remote session outranks a locally-restored
/// (paused) track; remote sessions read identically (artist line, not the device name).
struct MacPillModel {
    let item: MediaItem
    let sub: String?
    let spinning: Bool
    let remote: SessionHub.RemoteSession?

    @MainActor
    static func current(_ player: Player) -> MacPillModel? {
        if let r = SessionHub.shared.remote, !r.isPaused, !player.isPlaying {
            return MacPillModel(item: r.item, sub: r.item.primaryArtist, spinning: true, remote: r)
        }
        if let item = player.currentItem {
            return MacPillModel(item: item, sub: item.primaryArtist, spinning: player.isPlaying, remote: nil)
        }
        if let r = SessionHub.shared.remote {
            return MacPillModel(item: r.item, sub: r.item.primaryArtist, spinning: !r.isPaused, remote: r)
        }
        return nil
    }

    @MainActor
    func progress(at date: Date, _ player: Player) -> Double {
        if let remote {
            let dur = max(remote.durationSeconds, 1)
            return min(max(remote.livePosition(at: date) / dur, 0), 1)
        }
        return player.duration > 0 ? min(max(player.currentTime / player.duration, 0), 1) : 0
    }

    /// Route a transport action to whoever is playing.
    @MainActor func togglePlayPause(_ player: Player) {
        if remote != nil { SessionHub.shared.playPauseRemote() } else { player.togglePlayPause() }
    }
    @MainActor func next(_ player: Player) {
        if remote != nil { SessionHub.shared.nextRemote() } else { player.nextTrack() }
    }
    @MainActor func previous(_ player: Player) {
        if remote != nil { SessionHub.shared.previousRemote() } else { player.previousTrack() }
    }
}
