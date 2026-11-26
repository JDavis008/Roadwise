import Foundation
import Valhalla

/// On-phone Valhalla (valhalla-mobile) over the downloaded routing tiles. It takes the same
/// JSON requests as the online server and answers in the same JSON, so RoutingService parses
/// both the same way. Not safe to share across threads without the lock, which it holds.
final class OfflineRouter: @unchecked Sendable {
    private let tileDir: URL
    private let configName: String
    private var engine: Valhalla?
    private let lock = NSLock()

    init(tileDir: URL, configName: String = "roadwise-valhalla.json") {
        self.tileDir = tileDir
        self.configName = configName
    }

    /// Drop the engine so the next request sees newly added or removed tiles.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        engine?.close()
        engine = nil
    }

    func route(_ request: JSON) throws -> JSON { try call(request) { try $0.route(rawRequest: $1) } }

    func traceAttributes(_ request: JSON) throws -> JSON { try call(request) { try $0.traceAttributes(rawRequest: $1) } }

    private func call(_ request: JSON, _ action: (Valhalla, String) throws -> String) throws -> JSON {
        lock.lock(); defer { lock.unlock() }
        let engine = try ready()
        let body = String(decoding: try JSONSerialization.data(withJSONObject: request), as: UTF8.self)
        let raw: String
        do { raw = try action(engine, body) } catch {
            throw OfflineError(message: "No offline route (\(Self.describe(error)))")
        }
        guard let json = try JSONSerialization.jsonObject(with: Data(raw.utf8)) as? JSON else {
            throw OfflineError(message: "Offline routing returned nothing")
        }
        return json
    }

    private func ready() throws -> Valhalla {
        if let engine { return engine }
        guard let templateURL = Bundle.main.url(forResource: "valhalla-template", withExtension: "json"),
              var template = try? String(contentsOf: templateURL, encoding: .utf8) else {
            throw OfflineError(message: "Offline routing isn't set up in this build")
        }
        template = template.replacingOccurrences(of: "TILE_DIR", with: tileDir.path)
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let configURL = support.appendingPathComponent(configName)
        try template.write(to: configURL, atomically: true, encoding: .utf8)
        let e = try Valhalla(configPath: configURL.path)
        engine = e
        return e
    }

    private static func describe(_ error: Error) -> String {
        let s = String(describing: error)
        return s.count > 160 ? String(s.prefix(160)) + "…" : s
    }
}
