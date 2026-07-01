import Foundation
import Observation
import Network

/// Keeps audio on disk so playback survives a network drop and works offline.
///
/// Two pools, one lookup:
/// - **Downloads** (pinned): Liked Songs, Most Played, and every playlist's tracks, kept automatically.
/// - **Cache** (transient): the next few queue tracks, pre-buffered for resilience; trimmed by age.
///
/// Everything is **Wi-Fi only** (downloads pause on cellular / "expensive" links). `localURL(for:)` is
/// what the player checks first — if a track is on disk it plays from the file, otherwise it streams.
@Observable
final class AudioStore {
    static let shared = AudioStore()

    /// Track ids present on disk (either pool) — drives "downloaded" UI.
    private(set) var downloadedIds: Set<String> = []
    /// Whether we're on an un-metered (Wi-Fi/ethernet) link right now.
    private(set) var onWiFi = false
    /// Master switch for the whole offline feature (persisted).
    var offlineEnabled: Bool {
        didSet { UserDefaults.standard.set(offlineEnabled, forKey: Self.enabledKey); pump() }
    }

    @ObservationIgnored private static let enabledKey = "offlineEnabled"
    @ObservationIgnored private let fm = FileManager.default
    @ObservationIgnored private let downloadsDir: URL
    @ObservationIgnored private let cacheDir: URL
    @ObservationIgnored private var fileIndex: [String: URL] = [:]   // id -> file on disk
    @ObservationIgnored private var pinned: [MediaItem] = []         // collections to keep offline
    @ObservationIgnored private var prefetch: [MediaItem] = []       // upcoming queue (transient)
    @ObservationIgnored private var inFlight: Set<String> = []       // currently downloading
    @ObservationIgnored private var failed: Set<String> = []         // failed this session; retried on reconnect
    @ObservationIgnored private var activeCount = 0
    @ObservationIgnored private let maxConcurrent = 3
    @ObservationIgnored private let maxCacheFiles = 80               // transient-pool cap (LRU by mtime)
    @ObservationIgnored private let monitor = NWPathMonitor()
    @ObservationIgnored private weak var client: JellyfinClient?

    private init() {
        offlineEnabled = (UserDefaults.standard.object(forKey: Self.enabledKey) as? Bool) ?? true
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        downloadsDir = base.appendingPathComponent("AudioDownloads", isDirectory: true)
        cacheDir = base.appendingPathComponent("AudioCache", isDirectory: true)
        for d in [downloadsDir, cacheDir] {
            try? fm.createDirectory(at: d, withIntermediateDirectories: true)
            excludeFromBackup(d)
        }
        reindex()
        monitor.pathUpdateHandler = { path in
            let wifi = path.status == .satisfied && !path.isExpensive
            Task { @MainActor in AudioStore.shared.setWiFi(wifi) }
        }
        monitor.start(queue: DispatchQueue(label: "audiostore.network"))
    }

    /// Give the store the authenticated client so it can build stream URLs.
    func attach(_ client: JellyfinClient) { self.client = client; pump() }

    // MARK: - Lookup (used by the player)

    /// On-disk file for this track, if present and still on disk — else nil (caller should stream).
    func localURL(for id: String) -> URL? {
        guard let u = fileIndex[id], fm.fileExists(atPath: u.path) else { return nil }
        return u
    }
    func isDownloaded(_ id: String) -> Bool { downloadedIds.contains(id) }

    // MARK: - What to keep

    /// Replace the set of tracks to keep permanently offline (Liked Songs + Most Played + playlists).
    func setPinnedLibrary(_ items: [MediaItem]) {
        pinned = items.filter { !$0.id.isEmpty }
        pump()
    }

    /// Pre-buffer upcoming queue tracks (transient). Cheap to call repeatedly.
    func prefetchUpcoming(_ items: [MediaItem]) {
        let have = Set(prefetch.map(\.id))
        prefetch += items.filter { !$0.id.isEmpty && !have.contains($0.id) }
        pump()
    }

    /// Gather Liked Songs + Most Played + all playlist tracks and keep them downloaded.
    func refreshPinnedLibrary() {
        guard offlineEnabled, let client else { return }
        Task {
            async let liked = client.fetchFavoriteSongs()
            async let most = client.fetchMostPlayed(limit: 50)
            async let lists = client.fetchPlaylists()
            var items: [MediaItem] = ((try? await liked) ?? []) + ((try? await most) ?? [])
            for pl in (try? await lists) ?? [] {
                items += (try? await client.fetchPlaylistItems(playlistId: pl.id)) ?? []
            }
            var seen = Set<String>()
            setPinnedLibrary(items.filter { seen.insert($0.id).inserted })
        }
    }

    // MARK: - Storage management

    /// Total bytes used by both pools.
    func storageBytes() -> Int64 {
        [downloadsDir, cacheDir].reduce(0) { sum, dir in
            let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
            return sum + files.reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        }
    }

    /// Delete everything and stop tracking it.
    func clearAll() {
        for dir in [downloadsDir, cacheDir] {
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                try? fm.removeItem(at: f)
            }
        }
        fileIndex.removeAll(); downloadedIds = []; failed = []
    }

    // MARK: - Engine

    private func setWiFi(_ wifi: Bool) {
        onWiFi = wifi
        if wifi { failed.removeAll() }   // a fresh link is worth a retry
        pump()
    }

    /// Start as many downloads as we're allowed, prioritising the upcoming queue.
    private func pump() {
        guard offlineEnabled, onWiFi, client != nil else { return }
        while activeCount < maxConcurrent, let item = nextToDownload() {
            start(item.item, pinned: item.pinned)
        }
    }

    private func nextToDownload() -> (item: MediaItem, pinned: Bool)? {
        if let item = prefetch.first(where: needsDownload) { return (item, false) }
        if let item = pinned.first(where: needsDownload) { return (item, true) }
        return nil
    }
    private func needsDownload(_ item: MediaItem) -> Bool {
        localURL(for: item.id) == nil && !inFlight.contains(item.id) && !failed.contains(item.id)
    }

    private func start(_ item: MediaItem, pinned: Bool) {
        guard let client, let url = client.streamURL(for: item) else { return }
        inFlight.insert(item.id); activeCount += 1
        let id = item.id
        let dir = pinned ? downloadsDir : cacheDir
        Task.detached {
            var dest: URL?
            do {
                let (tmp, resp) = try await URLSession.shared.download(from: url)
                let target = dir.appendingPathComponent("\(id).\(AudioStore.fileExtension(for: resp))")
                try? FileManager.default.removeItem(at: target)
                try FileManager.default.moveItem(at: tmp, to: target)
                dest = target
            } catch { dest = nil }
            let final = dest
            await MainActor.run { AudioStore.shared.finish(id, dest: final, transient: !pinned) }
        }
    }

    private func finish(_ id: String, dest: URL?, transient: Bool) {
        inFlight.remove(id); activeCount = max(0, activeCount - 1)
        if let dest {
            fileIndex[id] = dest
            downloadedIds.insert(id)
            if transient { trimCache() }
        } else {
            failed.insert(id)   // don't hammer a failing item; retried on reconnect
        }
        pump()
    }

    // MARK: - Disk helpers

    private func reindex() {
        fileIndex.removeAll()
        for dir in [downloadsDir, cacheDir] {   // downloads scanned first → wins on id collision
            for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
                let id = f.deletingPathExtension().lastPathComponent
                if fileIndex[id] == nil { fileIndex[id] = f }
            }
        }
        downloadedIds = Set(fileIndex.keys)
    }

    /// Keep the transient cache bounded — evict the oldest files past the cap.
    private func trimCache() {
        let key: URLResourceKey = .contentModificationDateKey
        let files = (try? fm.contentsOfDirectory(at: cacheDir, includingPropertiesForKeys: [key])) ?? []
        guard files.count > maxCacheFiles else { return }
        let oldestFirst = files.sorted {
            let a = (try? $0.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [key]).contentModificationDate) ?? .distantPast
            return a < b
        }
        for f in oldestFirst.prefix(files.count - maxCacheFiles) {
            try? fm.removeItem(at: f)
            let id = f.deletingPathExtension().lastPathComponent
            if fileIndex[id] == f { fileIndex[id] = nil; downloadedIds.remove(id) }
        }
    }

    private func excludeFromBackup(_ url: URL) {
        var u = url
        var rv = URLResourceValues(); rv.isExcludedFromBackup = true
        try? u.setResourceValues(rv)
    }

    /// Pick a sensible file extension from the response so AVPlayer can read the local file.
    nonisolated static func fileExtension(for response: URLResponse) -> String {
        if let name = response.suggestedFilename,
           let ext = name.split(separator: ".").last, (1...5).contains(ext.count) {
            return ext.lowercased()
        }
        switch response.mimeType {
        case "audio/mpeg":               return "mp3"
        case "audio/mp4", "audio/x-m4a": return "m4a"
        case "audio/flac", "audio/x-flac": return "flac"
        case "audio/ogg", "audio/opus":  return "ogg"
        case "audio/wav", "audio/x-wav": return "wav"
        case "audio/aac":                return "aac"
        default:                          return "m4a"
        }
    }
}
