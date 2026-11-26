import CarPlay
import Combine
import MapKit
import Network
import UIKit

/// Everything on the CarPlay screen: the live map, search and saved places, route choices,
/// turn-by-turn guidance and one-tap reports. The iPhone twin of the Android Auto screens in
/// app/src/main/java/com/roadwise/app/car/. It drives the same AppModel as the phone, so a trip
/// started on either screen shows on both.
@MainActor
final class CarPlayController: NSObject, CPMapTemplateDelegate, CPSearchTemplateDelegate {
    private let ic: CPInterfaceController
    private let window: CPWindow
    private let app: AppModel
    private let mapVC = CarMapViewController()
    private let mapTemplate = CPMapTemplate()
    private var session: CPNavigationSession?
    private var trip: CPTrip?
    private var subs: [AnyCancellable] = []
    private var navSubs: [AnyCancellable] = []
    private var maneuverKey = ""
    private var lastEstimates = Date.distantPast
    private var shownAlert: String?
    private var paused = false
    private var searchTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private var online = true

    private var imperial: Bool { app.settings.imperial }

    init(interface: CPInterfaceController, window: CPWindow, app: AppModel) {
        ic = interface
        self.window = window
        self.app = app
        super.init()

        window.rootViewController = mapVC
        mapVC.loadViewIfNeeded()
        mapVC.setSatellite(app.settings.satellite)
        if let f = app.location.fix { mapVC.center(on: f.coordinate) }
        else if let c = app.mapCenter ?? AppModel.testOrigin { mapVC.center(on: c, distance: 6000) }

        mapTemplate.mapDelegate = self
        mapTemplate.automaticallyHidesNavigationBar = false
        mapTemplate.mapButtons = [
            mapButton("location.fill") { [weak self] in self?.recenter() },
            mapButton("plus") { [weak self] in self?.mapVC.zoom(by: 0.5) },
            mapButton("minus") { [weak self] in self?.mapVC.zoom(by: 2) },
            mapButton("arrow.up.and.down.and.arrow.left.and.right") { [weak self] in self?.mapTemplate.showPanningInterface(animated: true) },
        ]
        setBrowseButtons()
        ic.setRootTemplate(mapTemplate, animated: false, completion: nil)

        app.location.start()
        if app.location.authorization == .denied || app.location.authorization == .restricted {
            message("Location is off", "Allow location for Roadwise on your iPhone: Settings > Privacy & Security > Location Services.")
        }
        subs.append(app.location.$fix.compactMap { $0 }.sink { [weak self] f in
            guard let self else { return }
            self.mapVC.update(fix: f, nav: self.app.nav)
        })
        subs.append(app.$nav.sink { [weak self] n in self?.navChanged(n) })
        subs.append(app.settings.$satellite.sink { [weak self] on in self?.mapVC.setSatellite(on) })

        monitor.pathUpdateHandler = { [weak self] path in
            let ok = path.status == .satisfied
            Task { @MainActor in self?.setOnline(ok) }
        }
        monitor.start(queue: .main)
    }

    func disconnect() {
        monitor.cancel()
        searchTask?.cancel(); previewTask?.cancel()
        subs.removeAll(); navSubs.removeAll()
        session = nil
    }

    // MARK: Buttons

    private func mapButton(_ symbol: String, _ action: @escaping () -> Void) -> CPMapButton {
        let b = CPMapButton { _ in action() }
        b.image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        return b
    }

    private func barButton(_ title: String, _ action: @escaping () -> Void) -> CPBarButton {
        CPBarButton(title: title) { _ in action() }
    }

    private func setBrowseButtons() {
        mapTemplate.leadingNavigationBarButtons = [
            barButton("Search") { [weak self] in self?.showSearch() },
            barButton("Places") { [weak self] in self?.showPlaces() },
        ]
        mapTemplate.trailingNavigationBarButtons = [barButton("Report") { [weak self] in self?.showReports() }]
    }

    private func setPreviewButtons() {
        mapTemplate.leadingNavigationBarButtons = []
        mapTemplate.trailingNavigationBarButtons = [barButton("Cancel") { [weak self] in self?.cancelPreview() }]
    }

    private func setNavButtons() {
        mapTemplate.leadingNavigationBarButtons = [barButton("Report") { [weak self] in self?.showReports() }]
        mapTemplate.trailingNavigationBarButtons = [barButton("End") { [weak self] in self?.app.endNav() }]
    }

    /// `nav` is passed in because @Published sends changes before the property updates.
    private func recenter(nav: NavEngine? = nil, useCurrent: Bool = true) {
        mapVC.following = true
        if let f = app.location.fix { mapVC.update(fix: f, nav: useCurrent ? app.nav : nav) } else { app.location.start() }
    }

    // MARK: Places, search and reports

    private func showPlaces() {
        let here = app.here
        var saved: [CPListItem] = []
        if let h = app.saved.home { saved.append(pickable(CarTemplates.placeItem(h, title: "Home", symbolName: "house.fill", near: here, imperial: imperial))) }
        if let w = app.saved.work { saved.append(pickable(CarTemplates.placeItem(w, title: "Work", symbolName: "briefcase.fill", near: here, imperial: imperial))) }
        saved += app.saved.favorites.prefix(6).map { pickable(CarTemplates.placeItem($0, symbolName: "star.fill", near: here, imperial: imperial)) }
        let recents = app.saved.recents.prefix(6).map { pickable(CarTemplates.placeItem($0, symbolName: "clock.arrow.circlepath", near: here, imperial: imperial)) }
        let nearby: [CPListItem] = Category.all.map { cat in
            let item = CPListItem(text: cat.label, detailText: nil, image: CarTemplates.emoji(cat.emoji))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, done in self?.showNearby(cat, done: done) }
            return item
        }
        var sections: [CPListSection] = []
        if !saved.isEmpty { sections.append(CPListSection(items: saved, header: "Saved", sectionIndexTitle: nil)) }
        if !recents.isEmpty { sections.append(CPListSection(items: Array(recents), header: "Recent", sectionIndexTitle: nil)) }
        sections.append(CPListSection(items: nearby, header: "Nearby", sectionIndexTitle: nil))
        let t = CPListTemplate(title: "Where to?", sections: sections)
        ic.pushTemplate(t, animated: true, completion: nil)
    }

    private func pickable(_ item: CPListItem) -> CPListItem {
        item.handler = { [weak self] item, done in
            done()
            if let p = (item as? CPListItem)?.userInfo as? Place { self?.preview(p) }
        }
        return item
    }

    private func showNearby(_ cat: Category, done: @escaping () -> Void) {
        guard let here = app.here ?? app.mapCenter ?? AppModel.testOrigin else {
            done(); message(cat.label, "Waiting for your location."); return
        }
        Task {
            let found = (try? await SearchService.nearby(cat, near: here)) ?? []
            done()
            if found.isEmpty {
                message(cat.label, online || OfflineData.shared.hasData ? "Nothing found nearby." : "You're offline and this area isn't downloaded.")
                return
            }
            let items = found.prefix(12).map { pickable(CarTemplates.placeItem($0, near: here, imperial: imperial)) }
            ic.pushTemplate(CPListTemplate(title: cat.label, sections: [CPListSection(items: Array(items))]), animated: true, completion: nil)
        }
    }

    private func showSearch() {
        let t = CPSearchTemplate()
        t.delegate = self
        ic.pushTemplate(t, animated: true, completion: nil)
    }

    nonisolated func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                                    completionHandler: @escaping ([CPListItem]) -> Void) {
        MainActor.assumeIsolated {
            searchTask?.cancel()
            let here = app.here ?? app.mapCenter
            let local = CarTemplates.localMatches(searchText, saved: app.saved).prefix(4)
                .map { CarTemplates.placeItem($0, symbolName: "star.fill", near: here, imperial: imperial) }
            guard searchText.trimmingCharacters(in: .whitespaces).count >= 2 else { completionHandler(Array(local)); return }
            searchTask = Task {
                try? await Task.sleep(nanoseconds: 350_000_000)
                guard !Task.isCancelled else { return }
                let found = (try? await SearchService.search(searchText, near: here)) ?? []
                guard !Task.isCancelled else { return }
                let rows = found.prefix(10).map { CarTemplates.placeItem($0, near: here, imperial: imperial) }
                completionHandler(Array(local) + rows)
            }
        }
    }

    nonisolated func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                                    completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            completionHandler()
            if let p = item.userInfo as? Place { preview(p) }
        }
    }

    private func showReports() {
        let buttons = ReportType.all.prefix(8).map { type in
            CPGridButton(titleVariants: [type.label], image: CarTemplates.emoji(type.emoji)) { [weak self] _ in
                guard let self else { return }
                self.app.report(type)
                self.ic.popTemplate(animated: true, completion: nil)
                self.notice("\(type.emoji) \(type.label) reported", "Thanks!")
            }
        }
        ic.pushTemplate(CPGridTemplate(title: "Report", gridButtons: Array(buttons)), animated: true, completion: nil)
    }

    // MARK: Route preview

    private func preview(_ p: Place) {
        ic.popToRootTemplate(animated: true, completion: nil)
        guard app.nav == nil else { message(p.name, "End the current trip first."); return }
        previewTask?.cancel()
        app.pick(p)
        mapVC.showRoutes([], selected: 0, destination: p.coordinate)
        mapVC.following = false
        previewTask = Task {
            await app.planRoutes()
            guard !Task.isCancelled, app.place == p else { return }
            guard !app.routes.isEmpty, let from = app.origin ?? app.mapCenter else {
                let why = app.routeError ?? "No route found."
                message(p.name, why)
                return
            }
            let t = CarTemplates.trip(from: from, to: p, routes: app.routes, imperial: imperial)
            trip = t
            setPreviewButtons()
            mapTemplate.showTripPreviews([t], textConfiguration: CPTripPreviewTextConfiguration(
                startButtonTitle: "Go", additionalRoutesButtonTitle: "Routes", overviewButtonTitle: "Overview"))
            showChoice(0, for: t)
            mapVC.fit(app.routes)
        }
    }

    private func showChoice(_ i: Int, for t: CPTrip) {
        guard app.routes.indices.contains(i) else { return }
        app.selected = i
        let r = app.routes[i]
        mapVC.showRoutes(app.routes, selected: i, destination: r.destination)
        mapTemplate.updateEstimates(CarTemplates.estimates(distance: r.distance, time: r.duration, imperial: imperial), for: t)
    }

    private func cancelPreview() {
        previewTask?.cancel()
        mapTemplate.hideTripPreviews()
        trip = nil
        app.closePlace()
        mapVC.clearRoutes()
        setBrowseButtons()
        recenter()
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {
        MainActor.assumeIsolated {
            if let i = routeChoice.userInfo as? Int { showChoice(i, for: trip) }
        }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        MainActor.assumeIsolated {
            if let i = routeChoice.userInfo as? Int, app.routes.indices.contains(i) { app.selected = i }
            mapTemplate.hideTripPreviews()
            self.trip = trip
            app.startNav(preview: false)   // navChanged starts the CarPlay navigation session
        }
    }

    nonisolated func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        MainActor.assumeIsolated { app.endNav() }
    }

    nonisolated func mapTemplate(_ mapTemplate: CPMapTemplate, panWith direction: CPMapTemplate.PanDirection) {
        MainActor.assumeIsolated {
            var dx: CGFloat = 0, dy: CGFloat = 0
            if direction.contains(.left) { dx -= 1 }
            if direction.contains(.right) { dx += 1 }
            if direction.contains(.up) { dy -= 1 }
            if direction.contains(.down) { dy += 1 }
            mapVC.pan(dx: dx, dy: dy)
        }
    }

    // MARK: Guidance

    private func navChanged(_ nav: NavEngine?) {
        navSubs.removeAll()
        guard let nav else {
            session?.finishTrip()
            session = nil
            trip = nil
            maneuverKey = ""
            shownAlert = nil
            mapVC.clearRoutes()
            setBrowseButtons()
            recenter(nav: nil, useCurrent: false)
            return
        }
        mapTemplate.hideTripPreviews()
        if session == nil {
            let t = trip ?? CarTemplates.trip(from: app.here ?? nav.route.points.first ?? nav.destination.coordinate,
                                              to: nav.destination, routes: [nav.route], imperial: imperial)
            trip = t
            session = mapTemplate.startNavigationSession(for: t)
        }
        setNavButtons()
        mapVC.following = true
        mapVC.showRoutes([nav.route], selected: 0, destination: nav.destination.coordinate)
        if let f = app.location.fix { mapVC.update(fix: f, nav: nav) }
        navSubs.append(nav.$route.dropFirst().sink { [weak self] r in
            guard let self else { return }
            self.maneuverKey = ""
            self.mapVC.showRoutes([r], selected: 0, destination: nav.destination.coordinate)
        })
        navSubs.append(nav.$state.sink { [weak self] s in self?.guidance(s, nav) })
    }

    private func guidance(_ s: NavState, _ nav: NavEngine) {
        guard let session else { return }
        if s.rerouting {
            if !paused { session.pauseTrip(for: .rerouting, description: "Rerouting…"); paused = true }
            return
        }
        if s.arrived {
            if maneuverKey != "arrived" {
                maneuverKey = "arrived"
                session.upcomingManeuvers = [CarTemplates.arrived(at: nav.destination.name)]
            }
            return
        }
        guard let next = s.next else { return }
        let route = nav.route
        let key = "\(ObjectIdentifier(route).hashValue)-\(next.index)"
        if key != maneuverKey || paused {
            maneuverKey = key
            paused = false
            var list = [CarTemplates.maneuver(next, distance: s.distToNext, imperial: imperial)]
            if let then = s.then, route.cumDist.indices.contains(then.index), route.cumDist.indices.contains(next.index) {
                list.append(CarTemplates.maneuver(then, distance: route.cumDist[then.index] - route.cumDist[next.index], imperial: imperial))
            }
            session.upcomingManeuvers = list
            lastEstimates = .distantPast
        }
        if Date().timeIntervalSince(lastEstimates) > 1, let current = session.upcomingManeuvers.first {
            lastEstimates = Date()
            let toNext = s.remaining > 0 ? s.remainingTime * s.distToNext / s.remaining : 0
            session.updateEstimates(CarTemplates.estimates(distance: s.distToNext, time: toNext, imperial: imperial), for: current)
            if let trip { mapTemplate.updateEstimates(CarTemplates.estimates(distance: s.remaining, time: s.remainingTime, imperial: imperial), for: trip) }
        }
        if let a = s.alert, a.id != shownAlert {
            shownAlert = a.id
            notice("\(a.emoji) \(a.title)", a.detail)
        }
    }

    // MARK: Offline and messages

    private func setOnline(_ ok: Bool) {
        guard ok != online else { return }
        online = ok
        if ok { notice("Back online", "Live search and traffic reports are back."); return }
        let here = app.here ?? app.mapCenter
        if let here, OfflineData.shared.covers(here) {
            notice("You're offline", "Using your downloaded maps, search and route planning.")
        } else if app.nav != nil {
            notice("You're offline", "Guidance keeps going on this route. This area isn't downloaded, so rerouting needs a connection.")
        } else {
            notice("You're offline", "This area isn't downloaded. Download your state in Roadwise on your iPhone: Settings > Offline maps.")
        }
    }

    /// Short banner over the map that goes away on its own.
    private func notice(_ title: String, _ subtitle: String) {
        let alert = CPNavigationAlert(titleVariants: [title], subtitleVariants: [subtitle], image: nil,
                                      primaryAction: CPAlertAction(title: "OK", style: .cancel) { _ in },
                                      secondaryAction: nil, duration: 6)
        if mapTemplate.currentNavigationAlert != nil { mapTemplate.dismissNavigationAlert(animated: false) { _ in } }
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    private func message(_ title: String, _ text: String) {
        let alert = CPAlertTemplate(titleVariants: ["\(title): \(text)", text],
                                    actions: [CPAlertAction(title: "OK", style: .cancel) { [weak self] _ in
                                        self?.ic.dismissTemplate(animated: true, completion: nil)
                                    }])
        ic.presentTemplate(alert, animated: true, completion: nil)
    }
}
