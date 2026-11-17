import Foundation

/// User preferences, saved in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    private let d = UserDefaults.standard

    @Published var imperial: Bool { didSet { d.set(imperial, forKey: "imperial") } }
    @Published var voice: Bool { didSet { d.set(voice, forKey: "voice") } }
    @Published var speedAlert: Bool { didSet { d.set(speedAlert, forKey: "speedAlert") } }
    @Published var tolerance: Int { didSet { d.set(tolerance, forKey: "tolerance") } }
    @Published var reportAlerts: Bool { didSet { d.set(reportAlerts, forKey: "reportAlerts") } }
    @Published var cameraAlerts: Bool { didSet { d.set(cameraAlerts, forKey: "cameraAlerts") } }
    @Published var avoidTolls: Bool { didSet { d.set(avoidTolls, forKey: "avoidTolls") } }
    @Published var avoidHighways: Bool { didSet { d.set(avoidHighways, forKey: "avoidHighways") } }
    @Published var avoidFerries: Bool { didSet { d.set(avoidFerries, forKey: "avoidFerries") } }
    @Published var satellite: Bool { didSet { d.set(satellite, forKey: "satellite") } }
    @Published var nickname: String { didSet { d.set(nickname, forKey: "nickname") } }
    @Published var server: String { didSet { d.set(server, forKey: "server") } }
    @Published var travelMode: TravelMode { didSet { d.set(travelMode.rawValue, forKey: "travelMode") } }

    let clientId: String

    init() {
        imperial = d.object(forKey: "imperial") as? Bool ?? (Locale.current.measurementSystem == .us)
        voice = d.object(forKey: "voice") as? Bool ?? true
        speedAlert = d.object(forKey: "speedAlert") as? Bool ?? true
        tolerance = d.object(forKey: "tolerance") as? Int ?? 5
        reportAlerts = d.object(forKey: "reportAlerts") as? Bool ?? true
        cameraAlerts = d.object(forKey: "cameraAlerts") as? Bool ?? true
        avoidTolls = d.bool(forKey: "avoidTolls")
        avoidHighways = d.bool(forKey: "avoidHighways")
        avoidFerries = d.bool(forKey: "avoidFerries")
        satellite = d.bool(forKey: "satellite")
        nickname = d.string(forKey: "nickname") ?? ""
        server = d.string(forKey: "server") ?? ""
        travelMode = TravelMode(rawValue: d.string(forKey: "travelMode") ?? "") ?? .drive
        if let id = d.string(forKey: "clientId") {
            clientId = id
        } else {
            clientId = UUID().uuidString
            d.set(clientId, forKey: "clientId")
        }
    }

    /// Server base URL without a trailing slash, or nil when none is set.
    var serverURL: String? {
        let s = server.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/+$", with: "", options: .regularExpression)
        return s.isEmpty ? nil : s
    }

    var routeOptions: RouteOptions { RouteOptions(avoidTolls: avoidTolls, avoidHighways: avoidHighways, avoidFerries: avoidFerries) }
}

struct RouteOptions {
    var avoidTolls = false
    var avoidHighways = false
    var avoidFerries = false
}
