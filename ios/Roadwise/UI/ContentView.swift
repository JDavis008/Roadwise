import SwiftUI
import MapKit

struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var showSettings = false
    @State private var showReport = false
    @State private var showShare = false
    @State private var selectedReport: Report?
    @State private var mapHeading: Double = 0

    var body: some View {
        ZStack {
            map
            VStack(spacing: 10) {
                top
                Spacer(minLength: 0)
                HStack(alignment: .bottom) {
                    if app.screen == .nav { SpeedView() }
                    Spacer()
                    fabs
                }
                .padding(.horizontal, 12)
                bottom
            }
            if let t = app.toast {
                VStack { Spacer(); Text(t).font(.callout).padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.black.opacity(0.8), in: Capsule()).foregroundStyle(.white).padding(.bottom, 120) }
                    .transition(.opacity).allowsHitTesting(false)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: app.screen)
        .sheet(isPresented: $showSettings) { SettingsView().environmentObject(app).environmentObject(settings) }
        .sheet(isPresented: $showReport) { ReportSheet().environmentObject(app).presentationDetents([.medium]) }
        .sheet(isPresented: $showShare) { ShareSheetView().environmentObject(app).environmentObject(settings).presentationDetents([.medium, .large]) }
        .confirmationDialog(selectedReport.map { "\($0.kind.emoji) \($0.kind.label)" } ?? "", isPresented: Binding(get: { selectedReport != nil }, set: { if !$0 { selectedReport = nil } }), titleVisibility: .visible) {
            if let r = selectedReport {
                Button("Still there") { app.reports.vote(r, stillThere: true); app.show("Thanks for confirming") }
                Button("Not there", role: .destructive) { app.reports.vote(r, stillThere: false); app.show("Thanks — marked as gone") }
            }
        } message: {
            if let r = selectedReport { Text(reportAge(r)) }
        }
        .onAppear { app.location.start() }
    }

    // MARK: map

    private var map: some View {
        MapReader { proxy in
            Map(position: $app.camera) {
                ForEach(Array(app.routes.enumerated()), id: \.element.id) { i, r in
                    MapPolyline(coordinates: r.points)
                        .stroke(i == app.selected ? Color.blue : Color.gray.opacity(0.75),
                                style: StrokeStyle(lineWidth: i == app.selected ? 8 : 6, lineCap: .round, lineJoin: .round))
                }
                if let p = app.place {
                    Marker(p.name, coordinate: p.coordinate).tint(.red)
                }
                ForEach(app.reports.reports) { r in
                    Annotation(r.kind.label, coordinate: r.coordinate) {
                        Text(r.kind.emoji)
                            .font(.system(size: 16))
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(r.kind.color))
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                            .shadow(radius: 2)
                            .onTapGesture { selectedReport = r }
                    }
                    .annotationTitles(.hidden)
                }
                if let f = app.location.fix {
                    Annotation("", coordinate: app.nav?.state.snapped ?? f.coordinate, anchor: .center) {
                        Puck().rotationEffect(.degrees(f.heading - mapHeading))
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(settings.satellite ? .hybrid(elevation: .realistic) : .standard(elevation: .realistic))
            .mapControls { MapCompass(); MapScaleView() }
            .onMapCameraChange(frequency: .onEnd) { ctx in
                mapHeading = ctx.camera.heading
                app.mapCenter = ctx.region.center
                Task { await app.reports.sync(around: ctx.region.center) }
            }
            .onMapCameraChange(frequency: .continuous) { ctx in mapHeading = ctx.camera.heading }
            .simultaneousGesture(DragGesture(minimumDistance: 12).onChanged { _ in if app.following { app.following = false } })
            .simultaneousGesture(
                LongPressGesture(minimumDuration: 0.5)
                    .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .local))
                    .onEnded { value in
                        if case .second(true, let drag?) = value, let c = proxy.convert(drag.location, from: .local) { app.dropPin(c) }
                    }
            )
            .ignoresSafeArea()
        }
    }

    // MARK: overlays

    @ViewBuilder private var top: some View {
        switch app.screen {
        case .browse, .place:
            SearchHeader(showSettings: $showSettings).padding(.horizontal, 12).padding(.top, 4)
        case .nav:
            VStack(spacing: 8) {
                NavBanner()
                if let a = app.nav?.state.alert { AlertCard(alert: a) }
            }
            .padding(.horizontal, 8)
        case .routes:
            EmptyView()
        }
    }

    private var fabs: some View {
        VStack(spacing: 12) {
            if app.screen != .nav {
                Fab(symbol: settings.satellite ? "map.fill" : "globe.americas.fill") { settings.satellite.toggle() }
            }
            Fab(symbol: "location.circle.fill") { showShare = true }
            Fab(symbol: "exclamationmark.triangle.fill", tint: .white, background: .orange) { showReport = true }
            if app.screen == .nav && !app.following {
                Fab(symbol: "location.north.line.fill", tint: .white, background: .blue) { app.following = true; app.moveCamera() }
            } else if app.screen != .nav {
                Fab(symbol: app.following ? "location.fill" : "location", tint: app.following ? .white : .blue, background: app.following ? .blue : nil) { app.locateMe() }
            }
        }
    }

    @ViewBuilder private var bottom: some View {
        switch app.screen {
        case .browse: EmptyView()
        case .place: if let p = app.place { Card { PlaceCard(place: p) } }
        case .routes: Card { RoutesCard() }
        case .nav: Card { NavBottomBar(showShare: $showShare, showReport: $showReport) }
        }
    }

    private func reportAge(_ r: Report) -> String {
        let mins = max(1, Int(Date().timeIntervalSince(r.created) / 60))
        let age = mins < 60 ? "\(mins) min ago" : "\(mins / 60) hr ago"
        return age + (r.by.isEmpty ? "" : " · by \(r.by)") + (r.up > 0 ? " · \(r.up) confirmed" : "")
    }
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .shadow(color: .black.opacity(0.18), radius: 8, y: 2)
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
    }
}

struct Fab: View {
    let symbol: String
    var tint: Color = .primary
    var background: Color? = nil
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 50, height: 50)
                .background { if let b = background { Circle().fill(b) } else { Circle().fill(.regularMaterial) } }
                .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
        }
    }
}

struct Puck: View {
    var body: some View {
        ZStack {
            Circle().fill(.white).frame(width: 26, height: 26)
            Circle().fill(Color.blue).frame(width: 20, height: 20)
            Image(systemName: "location.north.fill").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
        }
        .shadow(radius: 2)
    }
}
