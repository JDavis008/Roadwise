import SwiftUI

/// Settings > Offline maps: download whole states so maps, search and route planning work
/// with no signal (on the phone and in CarPlay).
struct OfflineMapsView: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject private var store = OfflineStore.shared
    @State private var filter = ""
    @State private var confirm: OfflineState?
    @State private var used: Int64 = 0

    var body: some View {
        List {
            if let here = app.here ?? app.mapCenter, let s = store.state(containing: here), store.installed[s.id] == nil, store.jobs[s.id] == nil {
                Section {
                    Button { confirm = s } label: {
                        Label("Download \(s.name)", systemImage: "arrow.down.circle.fill").font(.headline)
                    }
                } footer: {
                    Text("The state you're in. About \(size(s.bytes + store.mapEstimateBytes(s))).")
                }
            }
            if !store.installed.isEmpty || !store.jobs.isEmpty {
                Section {
                    ForEach(rows(downloadedOrActive: true)) { s in row(s) }
                        .onDelete { idx in
                            let list = rows(downloadedOrActive: true)
                            idx.forEach { store.delete(list[$0].id) }
                            used = store.bytesUsed()
                        }
                } header: { Text("On this phone") } footer: {
                    Text("Using \(size(used)). Swipe left on a state to delete it.")
                }
            }
            Section {
                if store.loading && store.states.isEmpty { HStack { ProgressView(); Text("Loading states…") } }
                if let e = store.manifestError { Text(e).font(.footnote).foregroundStyle(.secondary) }
                ForEach(rows(downloadedOrActive: false)) { s in row(s) }
            } header: { Text("All states") } footer: {
                Text("Each state includes street maps (light and dark), offline search, and on-phone route planning. Keep Roadwise open while a state downloads. Satellite imagery and live traffic reports still need a connection.")
            }
        }
        .searchable(text: $filter, prompt: "Find a state")
        .navigationTitle("Offline maps")
        .navigationBarTitleDisplayMode(.inline)
        .task { used = store.bytesUsed(); await store.refresh(); store.resumePacks() }
        .alert(confirm.map { "Download \($0.name)?" } ?? "", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            Button("Download") { if let s = confirm { store.download(s) }; confirm = nil }
            Button("Cancel", role: .cancel) { confirm = nil }
        } message: {
            if let s = confirm {
                Text("About \(size(s.bytes + store.mapEstimateBytes(s))) over the internet. Wi-Fi is best.")
            }
        }
    }

    private func rows(downloadedOrActive: Bool) -> [OfflineState] {
        var list = store.states
        for i in store.installed.values where !list.contains(where: { $0.id == i.state.id }) { list.append(i.state) }
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        return list.filter { s in
            let mine = store.installed[s.id] != nil || store.jobs[s.id] != nil
            return mine == downloadedOrActive && (q.isEmpty || s.name.lowercased().contains(q) || s.abbr.lowercased() == q)
        }.sorted { $0.name < $1.name }
    }

    @ViewBuilder private func row(_ s: OfflineState) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(s.name).font(.body)
                if let job = store.jobs[s.id] {
                    if let e = job.error {
                        Text(e).font(.caption).foregroundStyle(.red)
                    } else {
                        ProgressView(value: job.progress) { Text("\(job.step)… \(Int(job.progress * 100))%").font(.caption) }
                    }
                } else if store.installed[s.id] != nil {
                    let map = store.mapProgress[s.id] ?? 0
                    if map < 0.999 {
                        ProgressView(value: map) { Text("Routing and search ready · maps \(Int(map * 100))%").font(.caption).foregroundStyle(.secondary) }
                    } else {
                        Label("Ready offline", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
                    }
                } else {
                    Text(size(s.bytes + store.mapEstimateBytes(s))).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let job = store.jobs[s.id] {
                if job.error != nil {
                    Button("Retry") { store.cancel(s.id); store.download(s) }.buttonStyle(.bordered)
                } else {
                    Button { store.cancel(s.id) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Cancel")
                }
            } else if store.installed[s.id] == nil {
                Button { confirm = s } label: { Image(systemName: "arrow.down.circle").font(.title2) }
                    .buttonStyle(.plain).accessibilityLabel("Download \(s.name)")
            }
        }
        .padding(.vertical, 2)
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
