import Foundation
import Network

/// Whether the phone has a usable connection right now. Thread-safe; posts
/// `Connectivity.changed` when it flips.
final class Connectivity: @unchecked Sendable {
    static let shared = Connectivity()
    static let changed = Notification.Name("RoadwiseConnectivityChanged")

    private let monitor = NWPathMonitor()
    private let lock = NSLock()
    private var _online = true

    var online: Bool { lock.lock(); defer { lock.unlock() }; return _online }

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let ok = path.status == .satisfied
            self.lock.lock()
            let flipped = ok != self._online
            self._online = ok
            self.lock.unlock()
            if flipped { NotificationCenter.default.post(name: Self.changed, object: nil) }
        }
        monitor.start(queue: DispatchQueue(label: "roadwise.connectivity"))
    }
}
