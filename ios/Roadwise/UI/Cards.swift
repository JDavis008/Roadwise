import SwiftUI

// MARK: place

struct PlaceCard: View {
    @EnvironmentObject var app: AppModel
    let place: Place
    @State private var showSave = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(place.name).font(.title2.bold()).lineLimit(2)
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button { app.closePlace() } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Close")
            }
            HStack(spacing: 10) {
                Button { Task { await app.planRoutes() } } label: {
                    Label("Directions", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                }
                .buttonStyle(.borderedProminent)
                Button { showSave = true } label: { Label("Save", systemImage: "star") }
                    .buttonStyle(.bordered)
                ShareLink(item: URL(string: mapLink(place.coordinate))!, subject: Text(place.name), message: Text("📍 \(place.name)")) {
                    Label("Share", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(.bordered)
            }
            .padding(.top, 4)
        }
        .confirmationDialog("Save \(place.name)", isPresented: $showSave, titleVisibility: .visible) {
            Button("Set as Home") { app.saved.home = place; app.saved.save(); app.show("Saved as Home") }
            Button("Set as Work") { app.saved.work = place; app.saved.save(); app.show("Saved as Work") }
            if app.saved.favorites.contains(place) {
                Button("Remove from Favorites", role: .destructive) { app.saved.favorites.removeAll { $0 == place }; app.saved.save() }
            } else {
                Button("Add to Favorites") { app.saved.favorites.insert(place, at: 0); app.saved.save(); app.show("Added to Favorites") }
            }
        }
    }

    private var subtitle: String {
        var s = place.address.isEmpty ? place.category : place.address
        if let here = app.here { s += " · \(Units.distance(Geo.dist(here, place.coordinate), imperial: app.settings.imperial)) away" }
        return s
    }
}

// MARK: routes

struct RoutesCard: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("To ").foregroundColor(.secondary) + Text(app.place?.name ?? "").bold()
                Spacer()
                Button { app.routes = []; app.screen = .place } label: { Image(systemName: "xmark.circle.fill").font(.title2) }
                    .foregroundStyle(.secondary)
            }
            Picker("Travel mode", selection: $settings.travelMode) {
                ForEach(TravelMode.allCases) { m in Label(m.label, systemImage: m.symbol).tag(m) }
            }
            .pickerStyle(.segmented)
            .onChange(of: settings.travelMode) { _, _ in Task { await app.planRoutes() } }

            // Stops on the way, numbered like their map pins.
            ForEach(Array(app.stops.enumerated()), id: \.offset) { i, p in
                HStack(spacing: 10) {
                    StopBadge(number: i + 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).lineLimit(1)
                        if !p.address.isEmpty { Text(p.address).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    Button { app.removeStop(at: i) } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Remove stop \(p.name)")
                }
            }
            if app.stops.count < AppModel.maxStops {
                Button { app.beginAddStop() } label: {
                    Label(app.stops.isEmpty ? "Add stop" : "Add another stop", systemImage: "mappin.and.ellipse")
                }
                .font(.subheadline)
            }

            if app.loadingRoutes {
                HStack { ProgressView(); Text("Finding the best routes…").foregroundStyle(.secondary) }
            } else if let err = app.routeError {
                Text(err).foregroundStyle(.red).font(.callout)
                Button("Try again") { Task { await app.planRoutes() } }.buttonStyle(.bordered)
            } else {
                let fastest = app.routes.map(\.duration).min() ?? 0
                ForEach(Array(app.routes.enumerated()), id: \.element.id) { i, r in
                    Button { app.selected = i } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(Units.duration(r.duration)).font(.title3.bold()).foregroundStyle(r.duration == fastest ? Color.green : Color.primary)
                                Text(r.label + (r.tolls ? " · Tolls" : "") + (r.ferry ? " · Ferry" : "")).font(.footnote).foregroundStyle(.secondary)
                            }
                            Spacer()
                            VStack(alignment: .trailing, spacing: 2) {
                                Text(Units.distance(r.distance, imperial: settings.imperial)).font(.subheadline)
                                Text("Arrive \(Units.clock(Date().addingTimeInterval(r.duration)))").font(.footnote).foregroundStyle(.secondary)
                            }
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 14).stroke(i == app.selected ? Color.blue : Color.secondary.opacity(0.3), lineWidth: i == app.selected ? 2 : 1))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if settings.travelMode == .drive {
                    HStack {
                        avoid("No tolls", $settings.avoidTolls)
                        avoid("No highways", $settings.avoidHighways)
                        avoid("No ferries", $settings.avoidFerries)
                    }
                }
                HStack(spacing: 10) {
                    Button { app.startNav(preview: false) } label: { Label("Start", systemImage: "play.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).tint(.green).disabled(app.routes.isEmpty || app.here == nil)
                    Button { app.startNav(preview: true) } label: { Label("Preview", systemImage: "eye").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).disabled(app.routes.isEmpty)
                }
                .controlSize(.large)
            }
        }
    }

    private func avoid(_ title: String, _ value: Binding<Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { value.wrappedValue }, set: { value.wrappedValue = $0; Task { await app.planRoutes() } }))
            .toggleStyle(.button)
            .font(.footnote)
    }
}

// MARK: navigation

struct NavBanner: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        if let n = app.nav {
            let s = n.state
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    Image(systemName: s.rerouting ? "arrow.triangle.2.circlepath" : (s.arrived ? "flag.checkered" : (s.next?.turn.symbol ?? "arrow.up")))
                        .font(.system(size: 40, weight: .bold))
                        .frame(width: 54)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title(s)).font(.system(size: 28, weight: .bold))
                        Text(subtitle(s, n)).font(.title3.weight(.medium)).lineLimit(2)
                    }
                    Spacer(minLength: 0)
                }
                .padding(14)
                if let t = s.then, !s.arrived, !s.rerouting {
                    HStack(spacing: 6) {
                        Text("Then")
                        Image(systemName: t.turn.symbol)
                        Text(t.text).lineLimit(1)
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 14).padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.black.opacity(0.18))
                }
            }
            .foregroundStyle(.white)
            .background((s.offRoute || s.rerouting) ? Color.gray : Color(red: 0.07, green: 0.44, blue: 0.27), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(radius: 6)
        }
    }

    private func title(_ s: NavState) -> String {
        if s.rerouting { return "Rerouting…" }
        if s.arrived { return "Arrived" }
        if s.offRoute { return "Off route" }
        return Units.distance(s.distToNext, imperial: app.settings.imperial)
    }

    private func subtitle(_ s: NavState, _ n: NavEngine) -> String {
        if s.arrived { return n.destination.name }
        if s.rerouting { return "" }
        return s.next?.text ?? ""
    }
}

/// The orange numbered circle used for stops (list rows and map pins match).
struct StopBadge: View {
    let number: Int
    var body: some View {
        Text("\(number)").font(.footnote.bold()).foregroundStyle(.white)
            .frame(width: 22, height: 22)
            .background(Circle().fill(Color.orange))
    }
}

struct AlertCard: View {
    @EnvironmentObject var app: AppModel
    let alert: NavAlert
    var body: some View {
        HStack(spacing: 10) {
            Text(alert.emoji).font(.largeTitle)
            VStack(alignment: .leading) { Text(alert.title).bold(); Text(alert.detail).font(.footnote).foregroundStyle(.secondary) }
            Spacer()
            if let r = alert.report {
                Button { app.reports.vote(r, stillThere: true); app.nav?.dismissAlert() } label: { Image(systemName: "hand.thumbsup.fill") }.buttonStyle(.bordered)
                Button("Gone") { app.reports.vote(r, stillThere: false); app.nav?.dismissAlert() }.buttonStyle(.bordered)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .shadow(radius: 4)
    }
}

struct SpeedView: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        let imperial = app.settings.imperial
        let limit = app.nav?.state.speedLimit ?? 0
        let over = app.nav?.state.overSpeed ?? false
        HStack(alignment: .bottom, spacing: 8) {
            if limit > 0 {
                if imperial {
                    VStack(spacing: 0) {
                        Text("SPEED\nLIMIT").font(.system(size: 8, weight: .bold)).multilineTextAlignment(.center)
                        Text("\(Units.limit(limit, imperial: true))").font(.system(size: 24, weight: .bold))
                    }
                    .foregroundStyle(.black)
                    .frame(width: 54, height: 62)
                    .background(.white, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(.black, lineWidth: 3))
                } else {
                    Text("\(limit)").font(.system(size: 22, weight: .bold)).foregroundStyle(.black)
                        .frame(width: 58, height: 58)
                        .background(Circle().fill(.white))
                        .overlay(Circle().stroke(.red, lineWidth: 6))
                }
            }
            VStack(spacing: 0) {
                Text("\(Units.speed(app.location.fix?.speed ?? 0, imperial: imperial))").font(.system(size: 24, weight: .bold))
                Text(Units.speedUnit(imperial)).font(.caption2)
            }
            .foregroundStyle(over ? Color.white : Color.primary)
            .frame(width: 64, height: 64)
            .background { if over { Circle().fill(.red) } else { Circle().fill(.regularMaterial) } }
            .shadow(radius: 3)
        }
    }
}

struct NavBottomBar: View {
    @EnvironmentObject var app: AppModel
    @Binding var showShare: Bool
    @Binding var showReport: Bool

    var body: some View {
        if let n = app.nav {
            let s = n.state
            VStack(spacing: 10) {
                if let stop = s.stops.first, !s.arrived {
                    // Next stop: how far, when, and a way to skip it.
                    HStack(spacing: 10) {
                        StopBadge(number: 1)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(stop.name).font(.subheadline.weight(.semibold)).lineLimit(1)
                            Text("\(Units.distance(s.stopDist, imperial: app.settings.imperial)) · \(Units.duration(s.stopTime)) · \(Units.clock(s.stopEta))"
                                 + (s.stops.count > 1 ? " · \(s.stops.count - 1) more" : ""))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Button("Skip") { n.removeStop(0) }.buttonStyle(.bordered).controlSize(.small)
                    }
                    .padding(.bottom, 2)
                    Divider()
                }
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.arrived ? "Arrived" : Units.clock(s.eta)).font(.title2.bold()).foregroundStyle(.green)
                        Text(s.arrived ? n.destination.name : "\(Units.duration(s.remainingTime)) · \(Units.distance(s.remaining, imperial: app.settings.imperial))\(app.simulating ? " · preview" : "")")
                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    roundButton(app.settings.voice ? "speaker.wave.2.fill" : "speaker.slash.fill") {
                        app.settings.voice.toggle()
                        if !app.settings.voice { app.voice.stop() }
                    }
                    roundButton("exclamationmark.triangle.fill") { showReport = true }
                    roundButton(app.live.active ? "dot.radiowaves.left.and.right" : "square.and.arrow.up") { showShare = true }
                    Button(s.arrived ? "Done" : "End") { app.endNav() }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.large)
                }
            }
        }
    }

    private func roundButton(_ symbol: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 17, weight: .semibold)).frame(width: 44, height: 44)
                .background(Circle().stroke(Color.secondary.opacity(0.4)))
        }
        .buttonStyle(.plain)
    }
}
