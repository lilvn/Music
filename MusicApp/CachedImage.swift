import SwiftUI
import ImageIO

/// Decoded-image cache + background downsampler. `AsyncImage` re-decodes full-size images on the
/// main thread each time a cell appears (janky scrolling, high memory). This decodes ONCE on a
/// background thread, downsampled to the display size, and caches the ready-to-draw image — so a
/// re-appearing cover renders instantly with no main-thread decode.
final class ImageStore {
    static let shared = ImageStore()

    private let cache = NSCache<NSString, UIImage>()
    private let loader = Loader()

    private init() {
        cache.totalCostLimit = 120 * 1024 * 1024   // ~120 MB of decoded pixels
        cache.countLimit = 500                      // and a hard cap on object count
    }

    // Keyed by url AND target size, so the same artwork can be cached at a small (blurred gradient)
    // and a large (crisp foreground) resolution at once without one clobbering the other.
    private func key(_ url: URL, _ maxPixel: CGFloat) -> NSString {
        "\(url.absoluteString)#\(Int(maxPixel))" as NSString
    }

    func cached(_ url: URL, maxPixel: CGFloat) -> UIImage? { cache.object(forKey: key(url, maxPixel)) }

    /// Warm the cache for a batch of artwork up front, so shelves/grids show their art immediately
    /// instead of popping in as cells scroll into view. Work is off-main, downsampled, and `.utility`
    /// priority (and the loader caps how many run at once), so it never blocks the UI — eager art
    /// without the cost of rendering every cell eagerly.
    func prefetch(_ urls: [URL?], maxPixel: CGFloat) {
        for url in urls.compactMap({ $0 }) where cached(url, maxPixel: maxPixel) == nil {
            Task.detached(priority: .utility) { _ = await ImageStore.shared.load(url, maxPixel: maxPixel) }
        }
    }

    /// Fetch (via the shared URLCache), downsample, decode, and cache — all off the main thread.
    /// Concurrent requests for the SAME art coalesce into one download+decode, and the loader caps how
    /// many distinct loads run at once so a fast scroll (or a prefetch batch) can't saturate the CPU /
    /// network and stall playback.
    func load(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        let k = key(url, maxPixel)
        if let img = cache.object(forKey: k) { return img }
        return await loader.coalesced(k as String) { [cache] in
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
            let img = await Task.detached(priority: .utility) { Self.downsample(data, maxPixel: maxPixel) }.value
            if let img {
                let cost = img.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
                cache.setObject(img, forKey: k, cost: cost)
            }
            return img
        }
    }

    /// De-duplicates in-flight loads (same key → one task, all callers await it) and gates how many
    /// run concurrently with a small async semaphore.
    private actor Loader {
        private var inFlight: [String: Task<UIImage?, Never>] = [:]
        private var active = 0
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private let maxConcurrent = 6

        func coalesced(_ key: String, _ build: @escaping () async -> UIImage?) async -> UIImage? {
            if let existing = inFlight[key] { return await existing.value }
            let task = Task { [weak self] () -> UIImage? in
                await self?.acquire()
                let result = await build()
                await self?.release()
                return result
            }
            inFlight[key] = task
            let result = await task.value
            inFlight[key] = nil
            return result
        }

        private func acquire() async {
            if active < maxConcurrent { active += 1; return }
            await withCheckedContinuation { waiters.append($0) }   // resumed with a slot handed to us
        }

        private func release() {
            if waiters.isEmpty { active -= 1 }
            else { waiters.removeFirst().resume() }                // hand our slot straight to a waiter
        }
    }

    /// Decode + downsample to `maxPixel` using ImageIO (no intermediate full-size bitmap). Pure work,
    /// `nonisolated` so it runs on the detached decode task off the main actor.
    private static nonisolated func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData,
                                                    [kCGImageSourceShouldCache: false] as CFDictionary) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,           // decode now, off-main
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}

/// Drop-in efficient replacement for an artwork `AsyncImage`: instant for cached images, smooth
/// background decode/downsample for new ones. `maxPixel` is the largest pixel dimension to decode
/// to (use the same value passed to `artworkURL(size:)`).
struct LibraryImage<Placeholder: View>: View {
    private let url: URL?
    private let maxPixel: CGFloat
    private let contentMode: ContentMode
    private let placeholder: Placeholder

    @State private var image: UIImage?

    init(url: URL?, maxPixel: CGFloat, contentMode: ContentMode = .fill,
         @ViewBuilder placeholder: () -> Placeholder) {
        self.url = url
        self.maxPixel = maxPixel
        self.contentMode = contentMode
        self.placeholder = placeholder()
        // Show a cached image immediately (no placeholder flash, no decode on appear).
        _image = State(initialValue: url.flatMap { ImageStore.shared.cached($0, maxPixel: maxPixel) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        // Keyed on `url`, so a changing source (e.g. the mini player when the track changes) actually
        // reloads instead of holding the previous track's art. A cached hit swaps instantly; a miss
        // clears first so stale art never lingers under the new title.
        .task(id: url) {
            guard let url else { image = nil; return }
            if let cached = ImageStore.shared.cached(url, maxPixel: maxPixel) { image = cached; return }
            image = nil
            let loaded = await ImageStore.shared.load(url, maxPixel: maxPixel)
            if !Task.isCancelled { image = loaded }
        }
    }
}
