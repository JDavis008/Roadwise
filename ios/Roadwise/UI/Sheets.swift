import SwiftUI

struct ReportSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Report").font(.title2.bold())
            Text(app.here != nil ? "Tap what you see. It's placed where you are now." : "No location yet, so it's placed at the center of the map.")
                .font(.subheadline).foregroundStyle(.secondary)
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(ReportType.all) { t in
                    Button {
                        app.report(t)
                        dismiss()
                    } label: {
                        VStack(spacing: 4) {
                            Text(t.emoji).font(.system(size: 30))
                            Text(t.label).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
                    }
                    .buttonStyle(.plain)
                }
            }
            Text(app.settings.serverURL != nil ? "Reports are shared with everyone using your Roadwise server."
                 : "No report server set, so reports stay on this phone. Add one in Settings to share them.")
                .font(.footnote).foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}

struct ShareSheetView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: AppSettings
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if let here = app.here {
                        ShareLink(item: URL(string: mapLink(here))!, message: Text("📍 Here's my location")) {
                            Label("Send my current location", systemImage: "mappin.and.ellipse")
                        }
                    } else {
                        Label("Waiting for your location…", systemImage: "location.slash").foregroundStyle(.secondary)
                    }
                    if let n = app.nav {
                        ShareLink(item: etaText(n)) { Label("Send my ETA", systemImage: "car.fill") }
                    }
                }
                Section {
                    if app.live.active {
                        Label(app.live.untilArrival ? "Sharing until you arrive" : "Sharing until \(Units.clock(app.live.expires ?? Date()))", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.red)
                        if let url = URL(string: app.live.url) {
                            ShareLink(item: url, message: Text("Follow my location live")) { Label("Send the link again", systemImage: "square.and.arrow.up") }
                        }
                        if let e = app.live.error { Text(e).font(.footnote).foregroundStyle(.secondary) }
                        Button("Stop sharing", role: .destructive) { Task { await app.live.stop() } }
                    } else if settings.serverURL == nil {
                        Text("Live location lets friends watch you move on a web map, with no app needed. It needs a Roadwise server: add its address in Settings.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        if app.nav != nil { liveButton("Until I arrive", minutes: 0) }
                        liveButton("For 15 minutes", minutes: 15)
                        liveButton("For 1 hour", minutes: 60)
                        liveButton("For 8 hours", minutes: 480)
                        if let e = error { Text(e).font(.footnote).foregroundStyle(.red) }
                    }
                } header: {
                    Text("Live location")
                } footer: {
                    Text("Roadwise keeps sending your location in the background while navigating.")
                }
            }
            .navigationTitle("Share location")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func liveButton(_ title: String, minutes: Int) -> some View {
        Button {
            busy = true
            error = nil
            Task {
                do { _ = try await app.live.start(minutes: minutes, untilArrival: minutes == 0) } catch { self.error = error.localizedDescription }
                busy = false
            }
        } label: {
            Label(title, systemImage: "location.fill.viewfinder")
        }
        .disabled(busy)
    }

    private func etaText(_ n: NavEngine) -> String {
        let s = n.state
        var text = "🚗 On my way to \(n.destination.name) — arriving around \(Units.clock(s.eta)) (\(Units.duration(s.remainingTime)), \(Units.distance(s.remaining, imperial: settings.imperial)) away)."
        if app.live.active { text += "\nFollow along live: \(app.live.url)" }
        else if let here = app.here { text += "\nI'm here now: \(mapLink(here))" }
        return text
    }
}

struct SettingsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @State private var serverText = ""
    @State private var testResult: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Map") {
                    Toggle("Satellite view", isOn: $settings.satellite)
                    Picker("Units", selection: $settings.imperial) {
                        Text("Miles").tag(true)
                        Text("Kilometers").tag(false)
                    }
                }
                Section("Navigation") {
                    Toggle("Voice guidance", isOn: $settings.voice)
                    Toggle("Speeding chime", isOn: $settings.speedAlert)
                    Stepper("Chime when \(settings.tolerance) \(Units.speedUnit(settings.imperial)) over", value: $settings.tolerance, in: 0...20)
                    Toggle("Report alerts", isOn: $settings.reportAlerts)
                    Toggle("Speed camera alerts", isOn: $settings.cameraAlerts)
                    Toggle("Avoid tolls", isOn: $settings.avoidTolls)
                    Toggle("Avoid highways", isOn: $settings.avoidHighways)
                    Toggle("Avoid ferries", isOn: $settings.avoidFerries)
                }
                Section {
                    TextField("Your name", text: $settings.nickname)
                    TextField("https://your-server.example", text: $serverText)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Save & test") {
                        settings.server = serverText
                        guard !serverText.trimmingCharacters(in: .whitespaces).isEmpty else { testResult = "Server removed. Reports stay on this phone."; return }
                        testResult = "Testing…"
                        Task {
                            testResult = await ReportService.testServer(serverText)
                            if let c = app.here ?? app.mapCenter { await app.reports.sync(around: c, force: true) }
                        }
                    }
                    if let r = testResult { Text(r).font(.footnote).foregroundStyle(.secondary) }
                } header: {
                    Text("Reports and live sharing")
                } footer: {
                    Text("The same Roadwise server the Android app uses. Leave it blank to keep reports on this phone.")
                }
                Section("About") {
                    Text("Roadwise for iPhone. Free and open source, using OpenStreetMap data with Valhalla routing and Photon search. Maps by Apple.")
                        .font(.footnote)
                    Link("Source code on GitHub", destination: URL(string: "https://github.com/JDavis008/Roadwise")!)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onAppear { serverText = settings.server }
        }
    }
}
