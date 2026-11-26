import Foundation
import MapLibre

/// Whole-state offline downloads, like the Android app's one-tap states: routing tiles and the
/// search index (from this project's GitHub release, built by tools/ios-offline) plus the
/// OpenFreeMap map tiles for the state (MapLibre offline packs, day and night styles).
@MainActor
final class OfflineStore: NSObject, ObservableObject {
    static let shared = OfflineStore()
    static let manifestURL = URL(string: "https://github.com/JDavis008/Roadwise/releases/download/offline-v1/manifest.json")!
    /// Map tiles go down to street level, the same as Android.
    static let maxZoom = 14
    /// Most states fit at street level (Texas is about 480,000 tiles). Bigger ones, like
    /// Alaska at 7 million, stop a zoom level or two higher so the download stays sane.
    static let maxTiles = 600_000

    /// The deepest map zoom to download for a box within the tile budget.
    nonisolated static func mapZoom(_ b: [Double]) -> Int {
        var z = maxZoom
        while z > 10 && tileCount(b, maxZoom: z) > maxTiles { z -= 1 }
        return z
    }

    struct Job: Equatable {
        var step: String
        var progress: Double
        var error: String?
    }

    let data: OfflineData
    @Published private(set) var states: [OfflineState] = []
    @Published private(set) var installed: [String: InstalledState] = [:]
    @Published private(set) var jobs: [String: Job] = [:]
    /// Map tile download progress per state, 0...1.
    @Published private(set) var mapProgress: [String: Double] = [:]
    @Published private(set) var manifestError: String?
    @Published private(set) var loading = false

    private var tasks: [String: Task<Void, Never>] = [:]

    init(data: OfflineData = .shared) {
        self.data = data
        super.init()
        installed = data.installed
        if let d = try? Data(contentsOf: manifestCache), let m = try? JSONDecoder().decode(OfflineManifest.self, from: d) { states = m.states }
        NotificationCenter.default.addObserver(forName: OfflineData.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.installed = self?.data.installed ?? [:] }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(packProgress(_:)), name: .MLNOfflinePackProgressChanged, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(packError(_:)), name: .MLNOfflinePackError, object: nil)
        // Packs load asynchronously at launch; finish any that were cut off.
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in MainActor.assumeIsolated { self?.resumePacks() } }
    }

    private var manifestCache: URL { data.root.appendingPathComponent("manifest.json") }

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            var req = URLRequest(url: Self.manifestURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
            req.setValue("Roadwise-iOS", forHTTPHeaderField: "User-Agent")
            let (d, resp) = try await URLSession.shared.data(for: req)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw OfflineError(message: "The download list isn't available yet") }
            let m = try JSONDecoder().decode(OfflineManifest.self, from: d)
            states = m.states.sorted { $0.name < $1.name }
            try? d.write(to: manifestCache, options: .atomic)
            manifestError = nil
        } catch {
            if states.isEmpty { manifestError = Connectivity.shared.online ? error.localizedDescription : "Connect to the internet to see the states you can download." }
        }
    }

    func state(containing c: Coord) -> OfflineState? {
        states.filter { $0.contains(c) }.min { area($0) < area($1) }
    }

    private func area(_ s: OfflineState) -> Double { (s.bbox[2] - s.bbox[0]) * (s.bbox[3] - s.bbox[1]) }

    /// Rough map tile size for a state, from its tile count (country tiles are small).
    func mapEstimateBytes(_ s: OfflineState) -> Int64 {
        let b = s.mapBounds
        let tiles = Self.tileCount(b, maxZoom: Self.mapZoom(b))
        let kb = tiles > 200_000 ? 9.0 : tiles > 40_000 ? 13.0 : 22.0
        return Int64(Double(tiles) * kb * 1024)
    }

    nonisolated static func tileCount(_ b: [Double], maxZoom: Int) -> Int {
        func x(_ lon: Double, _ z: Int) -> Int { Int((lon + 180) / 360 * Double(1 << z)) }
        func y(_ lat: Double, _ z: Int) -> Int {
            let r = lat * .pi / 180
            return Int((1 - log(tan(r) + 1 / cos(r)) / .pi) / 2 * Double(1 << z))
        }
        var n = 0
        for z in 0...maxZoom { n += (abs(x(b[3], z) - x(b[1], z)) + 1) * (abs(y(b[0], z) - y(b[2], z)) + 1) }
        return n
    }

    // MARK: Download

    func download(_ s: OfflineState) {
        guard tasks[s.id] == nil else { return }
        jobs[s.id] = Job(step: "Starting", progress: 0)
        let data = self.data
        tasks[s.id] = Task { [weak self] in
            do {
                guard let url = URL(string: s.url) else { throw OfflineError(message: "Bad download link") }
                let file = data.root.appendingPathComponent("\(s.id).tar.xz.download")
                try await Downloader.download(url, to: file) { p in
                    Task { @MainActor in self?.jobs[s.id] = Job(step: "Downloading", progress: p) }
                }
                defer { try? FileManager.default.removeItem(at: file) }
                try Task.checkCancellation()
                try await Task.detached(priority: .userInitiated) {
                    try data.install(packFile: file, state: s) { step, p in
                        Task { @MainActor in self?.jobs[s.id] = Job(step: step, progress: p) }
                    }
                }.value
                self?.jobs[s.id] = nil
                self?.startMapPacks(s)
            } catch is CancellationError {
                self?.jobs[s.id] = nil
            } catch {
                self?.jobs[s.id] = Job(step: "Failed", progress: 0, error: error.localizedDescription)
            }
            self?.tasks[s.id] = nil
        }
    }

    func cancel(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        jobs[id] = nil
    }

    func delete(_ id: String) {
        cancel(id)
        try? data.remove(id)
        installed = data.installed
        removePacks(id)
    }

    func bytesUsed() -> Int64 {
        let mapBytes = (MLNOfflineStorage.shared.packs ?? []).reduce(Int64(0)) { $0 + Int64($1.progress.countOfBytesCompleted) }
        return data.bytesUsed() + mapBytes
    }

    // MARK: Map tiles (MapLibre offline packs)

    private struct PackTag: Codable { let state: String; let style: String }

    private func tag(_ pack: MLNOfflinePack) -> PackTag? { try? JSONDecoder().decode(PackTag.self, from: pack.context) }

    func startMapPacks(_ s: OfflineState) {
        let existing = (MLNOfflineStorage.shared.packs ?? []).filter { tag($0)?.state == s.id }
        let b = s.mapBounds
        let bounds = MLNCoordinateBounds(sw: Coord(latitude: b[0], longitude: b[1]), ne: Coord(latitude: b[2], longitude: b[3]))
        let zoom = Double(Self.mapZoom(b))
        for (style, url) in [("day", MapStyles.day), ("night", MapStyles.night)] {
            if let p = existing.first(where: { tag($0)?.style == style }) {
                if p.state != .complete { p.resume() }
                continue
            }
            let region = MLNTilePyramidOfflineRegion(styleURL: url, bounds: bounds, fromZoomLevel: 0, toZoomLevel: zoom)
            guard let ctx = try? JSONEncoder().encode(PackTag(state: s.id, style: style)) else { continue }
            MLNOfflineStorage.shared.addPack(for: region, withContext: ctx) { pack, _ in pack?.resume() }
        }
        mapProgress[s.id] = mapProgress[s.id] ?? 0
    }

    private func removePacks(_ id: String) {
        for p in MLNOfflineStorage.shared.packs ?? [] where tag(p)?.state == id {
            MLNOfflineStorage.shared.removePack(p, withCompletionHandler: nil)
        }
        mapProgress[id] = nil
    }

    func resumePacks() {
        for p in MLNOfflineStorage.shared.packs ?? [] {
            guard let t = tag(p), installed[t.state] != nil else { continue }
            if p.state != .complete { p.resume() } else { updateProgress(t.state) }
        }
        // States downloaded before their map tiles started (or whose packs were lost).
        for s in installed.values.map(\.state) where !(MLNOfflineStorage.shared.packs ?? []).contains(where: { tag($0)?.state == s.id }) {
            startMapPacks(s)
        }
    }

    private func updateProgress(_ id: String) {
        let packs = (MLNOfflineStorage.shared.packs ?? []).filter { tag($0)?.state == id }
        guard !packs.isEmpty else { return }
        var done = 0.0
        for p in packs {
            let pr = p.progress
            done += p.state == .complete ? 1 : (pr.countOfResourcesExpected > 0 ? Double(pr.countOfResourcesCompleted) / Double(pr.countOfResourcesExpected) : 0)
        }
        mapProgress[id] = done / 2
    }

    @objc private func packProgress(_ n: Notification) {
        guard let pack = n.object as? MLNOfflinePack, let t = tag(pack) else { return }
        updateProgress(t.state)
    }

    @objc private func packError(_ n: Notification) {
        guard let pack = n.object as? MLNOfflinePack, let t = tag(pack) else { return }
        // Network hiccup: try again in a bit.
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            MainActor.assumeIsolated { if self?.installed[t.state] != nil, pack.state != .complete { pack.resume() } }
        }
    }
}

/// A file download with progress, written straight to `dest`.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var continuation: CheckedContinuation<Void, Error>?
    private let dest: URL
    private let progress: (Double) -> Void
    private let lock = NSLock()

    private init(dest: URL, progress: @escaping (Double) -> Void) {
        self.dest = dest
        self.progress = progress
    }

    static func download(_ url: URL, to dest: URL, progress: @escaping (Double) -> Void) async throws {
        let d = Downloader(dest: dest, progress: progress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                d.lock.lock(); d.continuation = c; d.lock.unlock()
                session.downloadTask(with: url).resume()
            }
        } onCancel: {
            session.invalidateAndCancel()
        }
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(with: result)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        if let code = (downloadTask.response as? HTTPURLResponse)?.statusCode, code != 200 {
            finish(.failure(OfflineError(message: "Download failed (HTTP \(code))")))
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }
}
