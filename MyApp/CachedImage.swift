import SwiftUI
import ImageIO

/// Decoded-image cache + background downsampler. `AsyncImage` re-decodes full-size images on the
/// main thread each time a cell appears (janky scrolling, high memory). This decodes ONCE on a
/// background thread, downsampled to the display size, and caches the ready-to-draw image — so a
/// re-appearing cover renders instantly with no main-thread decode.
final class ImageStore {
    static let shared = ImageStore()

    private let cache = NSCache<NSURL, UIImage>()

    private init() {
        cache.totalCostLimit = 120 * 1024 * 1024   // ~120 MB of decoded pixels
    }

    func cached(_ url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    /// Fetch (via the shared URLCache), downsample, decode, and cache — all off the main thread.
    func load(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        if let img = cached(url) { return img }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
        let img = await Task.detached(priority: .utility) { Self.downsample(data, maxPixel: maxPixel) }.value
        if let img {
            let cost = img.cgImage.map { $0.bytesPerRow * $0.height } ?? data.count
            cache.setObject(img, forKey: url as NSURL, cost: cost)
        }
        return img
    }

    /// Decode + downsample to `maxPixel` using ImageIO (no intermediate full-size bitmap).
    private static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
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
        _image = State(initialValue: url.flatMap { ImageStore.shared.cached($0) })
    }

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: url) {
            guard image == nil, let url else { return }
            let loaded = await ImageStore.shared.load(url, maxPixel: maxPixel)
            if !Task.isCancelled { image = loaded }
        }
    }
}
