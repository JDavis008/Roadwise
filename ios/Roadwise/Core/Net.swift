import Foundation

typealias JSON = [String: Any]

struct NetError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Tiny JSON-over-HTTP helpers used by every service.
enum Net {
    static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 20
        c.httpAdditionalHeaders = ["User-Agent": "Roadwise-iOS/1.0"]
        return URLSession(configuration: c)
    }()

    static func get(_ url: URL, timeout: TimeInterval = 12) async throws -> JSON {
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        return try await send(req)
    }

    static func post(_ url: URL, body: JSON, timeout: TimeInterval = 15) async throws -> JSON {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(req)
    }

    private static func send(_ req: URLRequest) async throws -> JSON {
        let (data, response) = try await session.data(for: req)
        let obj = (try? JSONSerialization.jsonObject(with: data)) as? JSON
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let msg = (obj?["error"] as? String) ?? (obj?["message"] as? String) ?? "HTTP \(http.statusCode)"
            throw NetError(message: msg)
        }
        guard let json = obj else { throw NetError(message: "Bad response") }
        return json
    }

    static func url(_ base: String, _ query: [String: String] = [:]) -> URL? {
        guard var c = URLComponents(string: base) else { return nil }
        if !query.isEmpty { c.queryItems = (c.queryItems ?? []) + query.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return c.url
    }
}

extension Dictionary where Key == String, Value == Any {
    func str(_ k: String) -> String { self[k] as? String ?? "" }
    func num(_ k: String) -> Double { (self[k] as? NSNumber)?.doubleValue ?? 0 }
    func int(_ k: String) -> Int { (self[k] as? NSNumber)?.intValue ?? 0 }
    func bool(_ k: String) -> Bool { (self[k] as? NSNumber)?.boolValue ?? false }
    func obj(_ k: String) -> JSON? { self[k] as? JSON }
    func arr(_ k: String) -> [JSON] { self[k] as? [JSON] ?? [] }
}
