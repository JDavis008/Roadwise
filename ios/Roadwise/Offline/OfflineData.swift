import Foundation
import CryptoKit

/// The offline data on the phone: unpacked routing tiles and search indexes, which states they
/// came from, and the engines that read them. Thread-safe and usable off the main actor, so
/// RoutingService and SearchService can call it from anywhere. OfflineStore drives downloads.
final class OfflineData: @unchecked Sendable {
    static let shared = OfflineData(root: OfflineData.defaultRoot)
    static let changed = Notification.Name("RoadwiseOfflineDataChanged")

    static var defaultRoot: URL {
        let support = (try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Offline", isDirectory: true)
    }

    let root: URL
    let router: OfflineRouter
    let search: OfflineSearch
    private let lock = NSLock()
    private var _installed: [String: InstalledState] = [:]

    var tileDir: URL { root.appendingPathComponent("valhalla_tiles", isDirectory: true) }
    var placesDir: URL { root.appendingPathComponent("places", isDirectory: true) }
    private var indexURL: URL { root.appendingPathComponent("installed.json") }

    init(root: URL, configName: String = "roadwise-valhalla.json") {
        self.root = root
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("valhalla_tiles"), withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: root.appendingPathComponent("places"), withIntermediateDirectories: true)
        // Keep big downloads out of iCloud backups.
        var r = root
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? r.setResourceValues(values)
        router = OfflineRouter(tileDir: root.appendingPathComponent("valhalla_tiles", isDirectory: true), configName: configName)
        search = OfflineSearch(dir: root.appendingPathComponent("places", isDirectory: true))
        if let data = try? Data(contentsOf: root.appendingPathComponent("installed.json")),
           let list = try? JSONDecoder().decode([String: InstalledState].self, from: data) {
            _installed = list
        }
    }

    var installed: [String: InstalledState] { lock.lock(); defer { lock.unlock() }; return _installed }

    var hasData: Bool { !installed.isEmpty }

    /// True when a downloaded state covers this point.
    func covers(_ c: Coord) -> Bool { installed.values.contains { $0.state.contains(c) } }

    func covers(_ a: Coord, _ b: Coord) -> Bool { covers(a) && covers(b) }

    /// Checks, unpacks and records one downloaded state pack (.tar.xz). Slow: call off the main actor.
    func install(packFile: URL, state: OfflineState, verify: Bool = true, progress: (String, Double) -> Void = { _, _ in }) throws {
        if verify && !state.sha256.isEmpty {
            progress("Checking", 0)
            guard try Self.sha256(packFile) == state.sha256.lowercased() else { throw OfflineError(message: "The download for \(state.name) was damaged. Try again.") }
        }
        let tmp = root.appendingPathComponent("\(state.id).tar.part")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try XZ.decompress(packFile, to: tmp) { progress("Unpacking", $0 * 0.5) }
        // Writing tiles while the engine reads them is not safe; drop it first.
        router.reset()
        search.reset()
        let files = try Tar.extract(tmp, to: root) { progress("Unpacking", 0.5 + $0 * 0.5) }
        lock.lock()
        _installed[state.id] = InstalledState(state: state, files: files, installed: Date())
        let snapshot = _installed
        lock.unlock()
        try save(snapshot)
        router.reset()
        search.reset()
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Deletes a state's files, keeping routing tiles a still-downloaded neighbour needs.
    func remove(_ id: String) throws {
        lock.lock()
        guard let gone = _installed.removeValue(forKey: id) else { lock.unlock(); return }
        let keep = Set(_installed.values.flatMap(\.files))
        let snapshot = _installed
        lock.unlock()
        router.reset()
        search.reset()
        for f in gone.files where !keep.contains(f) {
            try? FileManager.default.removeItem(at: root.appendingPathComponent(f))
        }
        try save(snapshot)
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    /// Bytes used on the phone by downloaded routing and search data.
    func bytesUsed() -> Int64 {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    private func save(_ list: [String: InstalledState]) throws {
        try JSONEncoder().encode(list).write(to: indexURL, options: .atomic)
    }

    static func sha256(_ url: URL) throws -> String {
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }
        var hasher = SHA256()
        while let chunk = try fh.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
