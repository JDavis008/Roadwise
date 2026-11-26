import CarPlay
import MapKit
import UIKit

/// Builders for the CarPlay objects (trips, maneuvers, estimates, list rows). Kept free of
/// CarPlay session state so the unit tests can check them on a simulator.
enum CarTemplates {

    /// A distance CarPlay can format for the driver's units (it localizes the number itself).
    static func measurement(_ meters: Double, imperial: Bool) -> Measurement<UnitLength> {
        let m = max(0, meters)
        if imperial {
            let ft = m * 3.28084
            if ft < 1000 { return Measurement(value: (ft / 10).rounded() * 10, unit: .feet) }
            return Measurement(value: (m / 1609.344 * 10).rounded() / 10, unit: .miles)
        }
        if m < 1000 { return Measurement(value: (m / 10).rounded() * 10, unit: .meters) }
        return Measurement(value: (m / 100).rounded() / 10, unit: .kilometers)
    }

    static func estimates(distance: Double, time: Double, imperial: Bool) -> CPTravelEstimates {
        CPTravelEstimates(distanceRemaining: measurement(distance, imperial: imperial), timeRemaining: max(0, time))
    }

    /// One turn for the guidance card. `distance` is how far away it is right now.
    static func maneuver(_ m: Maneuver, distance: Double, imperial: Bool) -> CPManeuver {
        let cm = CPManeuver()
        var variants = [m.text]
        if let street = m.street?.components(separatedBy: " / ").first, !street.isEmpty, street != m.text { variants.append(street) }
        cm.instructionVariants = variants
        cm.symbolImage = symbol(m.turn.symbol)
        cm.initialTravelEstimates = estimates(distance: distance, time: 0, imperial: imperial)
        cm.userInfo = m.index
        return cm
    }

    static func arrived(at name: String) -> CPManeuver {
        let cm = CPManeuver()
        cm.instructionVariants = ["You've arrived at \(name)", "You've arrived"]
        cm.symbolImage = symbol("flag.checkered")
        return cm
    }

    /// The trip CarPlay previews and navigates: one route choice per route, tagged with its index.
    static func trip(from origin: Coord, to place: Place, routes: [Route], imperial: Bool) -> CPTrip {
        let from = MKMapItem(placemark: MKPlacemark(coordinate: origin))
        from.name = "Current location"
        let to = MKMapItem(placemark: MKPlacemark(coordinate: place.coordinate))
        to.name = place.name
        let choices: [CPRouteChoice] = routes.enumerated().map { i, r in
            let notes = [r.tolls ? "Tolls" : nil, r.ferry ? "Ferry" : nil].compactMap { $0 }
            let extra = ([Units.distance(r.distance, imperial: imperial)] + notes).joined(separator: " · ")
            let choice = CPRouteChoice(summaryVariants: [r.label], additionalInformationVariants: [extra],
                                       selectionSummaryVariants: [r.label])
            choice.userInfo = i
            return choice
        }
        let trip = CPTrip(origin: from, destination: to, routeChoices: choices)
        trip.userInfo = place
        return trip
    }

    /// A tappable place row; the place rides along in `userInfo` (search results need that).
    static func placeItem(_ p: Place, title: String? = nil, symbolName: String? = nil, near: Coord?, imperial: Bool) -> CPListItem {
        var detail = p.address
        if let near {
            let d = Units.distance(Geo.dist(near, p.coordinate), imperial: imperial)
            detail = detail.isEmpty ? d : "\(d) · \(detail)"
        }
        let image = symbolName.flatMap { symbol($0, tint: .systemBlue) } ?? p.emoji.map { emoji($0) }
        let item = CPListItem(text: title ?? p.name, detailText: title == nil ? detail : p.name, image: image)
        item.userInfo = p
        return item
    }

    static func symbol(_ name: String, tint: UIColor = .white) -> UIImage? {
        UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(pointSize: 44, weight: .bold))?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
    }

    /// Emoji as an image (category and report icons).
    static func emoji(_ s: String, size: CGFloat = 64) -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: size, height: size)).image { _ in
            let text = s as NSString
            let font = UIFont.systemFont(ofSize: size * 0.78)
            let box = text.size(withAttributes: [.font: font])
            text.draw(at: CGPoint(x: (size - box.width) / 2, y: (size - box.height) / 2), withAttributes: [.font: font])
        }
    }

    /// Saved and recent places whose name or address matches: what search can offer with no signal.
    static func localMatches(_ query: String, saved: SavedPlaces) -> [Place] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        let all = [saved.home, saved.work].compactMap { $0 } + saved.favorites + saved.recents
        var seen = Set<Place>()
        return all.filter { p in
            (q.isEmpty || p.name.lowercased().contains(q) || p.address.lowercased().contains(q)) && seen.insert(p).inserted
        }
    }
}
