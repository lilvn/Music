import SwiftUI
import UIKit

// The Now Playing background: an audio-reactive "lava lamp" — a slow-drifting MeshGradient built from
// the current album art's dominant colors, whose motion swells with the music (player.audioLevel is a
// smoothed 0…1 RMS scalar from the shared MTAudioProcessingTap pipeline, already live on tvOS).
//
// THERMAL: animated ONLY here, on Now Playing (project memory — animated backgrounds elsewhere caused
// lag/heat). 3x3 mesh at ≤30fps, paused when the scene isn't active. Every other page keeps TVBackdrop.

// MARK: - Palette extraction

enum ArtworkPalette {
    /// Palette per artwork URL — track skips back to a seen album are instant.
    private static var cache: [URL: [Color]] = [:]

    /// Dark desaturated fallback (matches TVBackdrop's black base) for missing/failed artwork.
    static let fallback: [Color] = [
        Color(red: 0.16, green: 0.16, blue: 0.19),
        Color(red: 0.10, green: 0.10, blue: 0.13),
        Color(red: 0.22, green: 0.20, blue: 0.24),
        Color(red: 0.06, green: 0.06, blue: 0.08),
    ]

    /// 4-5 dominant, TV-friendly colors from the artwork. Pure CPU work on a 24x24 downsample —
    /// runs off-main once per track change.
    static func extract(from url: URL?) async -> [Color] {
        guard let url else { return fallback }
        if let hit = await MainActor.run(body: { cache[url] }) { return hit }
        guard let image = await ImageStore.shared.load(url, maxPixel: 32),
              let cg = image.cgImage else { return fallback }

        let colors = await Task.detached(priority: .utility) { () -> [Color] in
            let w = 24, h = 24
            var pixels = [UInt8](repeating: 0, count: w * h * 4)
            guard let ctx = CGContext(data: &pixels, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
                return fallback
            }
            ctx.interpolationQuality = .low
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

            // Histogram at 4 bits/channel; rank buckets by count weighted toward saturated colors.
            var buckets: [Int: (count: Int, r: Double, g: Double, b: Double)] = [:]
            for i in stride(from: 0, to: pixels.count, by: 4) {
                let r = Double(pixels[i]) / 255, g = Double(pixels[i + 1]) / 255, b = Double(pixels[i + 2]) / 255
                let key = (Int(r * 15) << 8) | (Int(g * 15) << 4) | Int(b * 15)
                var e = buckets[key] ?? (0, 0, 0, 0)
                e.count += 1; e.r += r; e.g += g; e.b += b
                buckets[key] = e
            }
            struct Candidate { let r, g, b, score: Double }
            let ranked = buckets.values.map { e -> Candidate in
                let n = Double(e.count)
                let r = e.r / n, g = e.g / n, b = e.b / n
                let mx = max(r, g, b), mn = min(r, g, b)
                let sat = mx > 0 ? (mx - mn) / mx : 0
                return Candidate(r: r, g: g, b: b, score: n * (0.35 + sat))
            }.sorted { $0.score > $1.score }

            // Greedy pick with a minimum spread so the palette doesn't collapse to one hue.
            var picked: [(r: Double, g: Double, b: Double)] = []
            for c in ranked where picked.count < 5 {
                let distinct = picked.allSatisfy { p in
                    abs(p.r - c.r) + abs(p.g - c.g) + abs(p.b - c.b) > 0.35
                }
                if distinct { picked.append((c.r, c.g, c.b)) }
            }
            guard !picked.isEmpty else { return fallback }

            // Boost into a TV-friendly range: saturation up a touch, brightness clamped off the extremes.
            return picked.map { p in
                let ui = UIColor(red: p.r, green: p.g, blue: p.b, alpha: 1)
                var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, a: CGFloat = 0
                ui.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &a)
                return Color(hue: hue, saturation: min(1, sat * 1.25), brightness: min(0.85, max(0.18, bri)))
            }
        }.value

        await MainActor.run { cache[url] = colors }
        return colors
    }
}

// MARK: - The lava lamp

struct TVLavaLampBackdrop: View {
    @Environment(Player.self) private var player
    @Environment(JellyfinClient.self) private var client
    @Environment(\.scenePhase) private var scenePhase
    let item: MediaItem?

    @State private var palette: [Color] = ArtworkPalette.fallback
    /// Per-frame smoothed audio level — a plain (non-observed) box so mutating it during render is
    /// safe and never triggers an invalidation loop.
    private final class LevelBox { var value: Double = 0 }
    @State private var level = LevelBox()

    var body: some View {
        ZStack {
            Color.black
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: scenePhase != .active)) { ctx in
                mesh(t: ctx.date.timeIntervalSinceReferenceDate)
            }
            // Legibility scrim, mirroring TVBackdrop's tone-down.
            Color.black.opacity(0.35)
        }
        .ignoresSafeArea()
        .task(id: item?.id) {
            let url = item.flatMap { client.artworkURL(for: $0, size: 160) }
            let colors = await ArtworkPalette.extract(from: url)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 1.0)) { palette = colors }
        }
    }

    private func mesh(t: TimeInterval) -> some View {
        // Fast-attack / slow-release smoothing so the swell feels musical, not jittery. Gate on
        // isPlaying: the tap freezes on pause, leaving audioLevel stuck at a stale value.
        let raw = player.isPlaying ? min(1, max(0, player.audioLevel)) : 0
        let s = level.value
        level.value = raw > s ? s + (raw - s) * 0.4 : s + (raw - s) * 0.12
        let amp = 0.5 + 1.0 * level.value

        // 3x3 grid: corners pinned, edge midpoints slide along their edges, the centre roams free —
        // summed incommensurate sines give the aimless lava drift (periods 30-150s), scaled by amp.
        func drift(_ a: Double, _ b: Double, _ p1: Double, _ p2: Double) -> Float {
            Float(0.5 + a * amp * sin(t * 0.11 + p1) + b * amp * sin(t * 0.043 + p2))
        }
        let points: [SIMD2<Float>] = [
            [0, 0], [drift(0.14, 0.06, 0.0, 2.1), 0], [1, 0],
            [0, drift(0.12, 0.07, 1.3, 4.2)],
            [drift(0.16, 0.08, 2.6, 0.7), drift(0.13, 0.07, 3.9, 1.9)],
            [1, drift(0.12, 0.07, 5.2, 3.1)],
            [0, 1], [drift(0.14, 0.06, 4.4, 5.5), 1], [1, 1],
        ]

        // Deterministic palette→9-slot mapping (stable across frames so crossfades don't flicker);
        // the centre glows toward white with the music.
        let p = palette
        func c(_ i: Int) -> Color { p[i % p.count] }
        let colors: [Color] = [
            c(3), c(1), c(2),
            c(2), c(0).mix(with: .white, by: level.value * 0.22), c(1),
            c(1), c(2), c(3),
        ]
        return MeshGradient(width: 3, height: 3, points: points, colors: colors)
    }
}
