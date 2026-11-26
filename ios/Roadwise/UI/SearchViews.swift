import SwiftUI

struct SearchHeader: View {
    @EnvironmentObject var app: AppModel
    @Binding var showSettings: Bool
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var status: String?
    @State private var task: Task<Void, Never>?
    @State private var activeCategory: String?
    @FocusState private var focused: Bool

    private var listVisible: Bool { focused || !results.isEmpty || status != nil }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Button { showSettings = true } label: { Image(systemName: "line.3.horizontal").font(.title3) }
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Settings")
                TextField("Search Roadwise", text: $query)
                    .focused($focused)
                    .submitLabel(.search)
                    .autocorrectionDisabled()
                    .onSubmit { run(query) }
                if !query.isEmpty || listVisible {
                    Button { clear() } label: { Image(systemName: "xmark.circle.fill") }
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 16)
            .frame(height: 50)
            .background(.regularMaterial, in: Capsule())
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .onChange(of: query) { _, q in schedule(q) }

            if !listVisible && app.screen == .browse { chips }
            if listVisible { list }
        }
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Category.all) { c in
                    Button { nearby(c) } label: {
                        Text("\(c.emoji) \(c.label)").font(.subheadline)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(activeCategory == c.label ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.regularMaterial), in: Capsule())
                            .foregroundStyle(activeCategory == c.label ? Color.white : Color.primary)
                    }
                }
            }
            .padding(.horizontal, 2)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if query.isEmpty && results.isEmpty && status == nil {
                    savedRows
                } else {
                    if let s = status { Text(s).foregroundStyle(.secondary).padding(16) }
                    ForEach(results) { p in row(p, emoji: p.emoji ?? "📍") }
                }
            }
        }
        .frame(maxHeight: 420)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    @ViewBuilder private var savedRows: some View {
        header("Saved")
        if let h = app.saved.home { row(h, emoji: "🏠", title: "Home") } else { hint("🏠", "Home", "Search a place, then tap Save › Set as Home") }
        if let w = app.saved.work { row(w, emoji: "💼", title: "Work") } else { hint("💼", "Work", "Search a place, then tap Save › Set as Work") }
        ForEach(app.saved.favorites) { row($0, emoji: "⭐") }
        if !app.saved.recents.isEmpty {
            header("Recent")
            ForEach(app.saved.recents) { row($0, emoji: "🕘") }
        }
    }

    private func header(_ t: String) -> some View {
        Text(t.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
    }

    private func hint(_ emoji: String, _ title: String, _ sub: String) -> some View {
        HStack(spacing: 12) {
            Text(emoji).frame(width: 34, height: 34).background(Circle().fill(Color.secondary.opacity(0.15)))
            VStack(alignment: .leading) { Text(title).fontWeight(.semibold); Text(sub).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 16).padding(.vertical, 9)
    }

    private func row(_ p: Place, emoji: String, title: String? = nil) -> some View {
        Button { pick(p) } label: {
            HStack(spacing: 12) {
                Text(emoji).frame(width: 34, height: 34).background(Circle().fill(Color.secondary.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? p.name).fontWeight(.semibold).lineLimit(1)
                    Text(p.address.isEmpty ? p.category : (title != nil ? p.name + ", " + p.address : p.address))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let here = app.here {
                    Text(Units.distance(Geo.dist(here, p.coordinate), imperial: app.settings.imperial)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func pick(_ p: Place) {
        focused = false
        results = []
        status = nil
        activeCategory = nil
        app.pick(p)
    }

    private func clear() {
        query = ""
        results = []
        status = nil
        activeCategory = nil
        focused = false
        task?.cancel()
    }

    private func schedule(_ q: String) {
        task?.cancel()
        activeCategory = nil
        guard q.trimmingCharacters(in: .whitespaces).count >= 2 else { results = []; status = nil; return }
        task = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if !Task.isCancelled { run(q) }
        }
    }

    private func run(_ q: String) {
        let text = q.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { return }
        status = "Searching…"
        let near = app.here ?? app.mapCenter
        Task {
            do {
                let found = try await SearchService.search(text, near: near)
                guard text == query.trimmingCharacters(in: .whitespaces) else { return }
                let local = ([app.saved.home, app.saved.work].compactMap { $0 } + app.saved.favorites + app.saved.recents)
                    .filter { ($0.name + " " + $0.address).localizedCaseInsensitiveContains(text) }
                results = Array(local.prefix(3)) + found
                status = results.isEmpty ? "No results. Try adding a city or state." : nil
            } catch {
                status = "Search is unavailable right now (\(error.localizedDescription))."
            }
        }
    }

    private func nearby(_ c: Category) {
        if activeCategory == c.label { clear(); return }
        activeCategory = c.label
        guard let near = app.here ?? app.mapCenter else { status = "Waiting for your location…"; return }
        status = "Finding \(c.label.lowercased()) nearby…"
        Task {
            do {
                let found = try await SearchService.nearby(c, near: near)
                guard activeCategory == c.label else { return }
                results = found
                status = found.isEmpty ? "Nothing found nearby." : nil
            } catch {
                status = "Couldn't load nearby places (\(error.localizedDescription))."
            }
        }
    }
}

/// Picks a stop on the way: a category nearby (gas, food, coffee…), a search, or a saved place.
/// Used from the routes card and while driving.
struct StopPicker: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [Place] = []
    @State private var status: String?
    @State private var category: String?
    @State private var task: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Category.all) { c in
                                Button { nearby(c) } label: {
                                    Text("\(c.emoji) \(c.label)").font(.subheadline)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(category == c.label ? AnyShapeStyle(Color.orange) : AnyShapeStyle(Color.secondary.opacity(0.15)), in: Capsule())
                                        .foregroundStyle(category == c.label ? Color.white : Color.primary)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
                }
                if let s = status { Text(s).foregroundStyle(.secondary) }
                if !results.isEmpty {
                    Section { ForEach(results) { row($0, emoji: $0.emoji ?? "📍") } }
                } else if query.isEmpty && category == nil {
                    Section("Saved") {
                        if let h = app.saved.home { row(h, emoji: "🏠", title: "Home") }
                        if let w = app.saved.work { row(w, emoji: "💼", title: "Work") }
                        ForEach(app.saved.favorites) { row($0, emoji: "⭐") }
                        ForEach(app.saved.recents.prefix(6)) { row($0, emoji: "🕘") }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Add a stop")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search for a stop")
            .onChange(of: query) { _, q in schedule(q) }
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
    }

    private func row(_ p: Place, emoji: String, title: String? = nil) -> some View {
        Button { app.addStop(p) } label: {
            HStack(spacing: 12) {
                Text(emoji).frame(width: 32, height: 32).background(Circle().fill(Color.secondary.opacity(0.15)))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title ?? p.name).fontWeight(.semibold).lineLimit(1)
                    Text(p.address.isEmpty ? p.category : p.address).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let here = app.here {
                    Text(Units.distance(Geo.dist(here, p.coordinate), imperial: app.settings.imperial)).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func schedule(_ q: String) {
        task?.cancel()
        category = nil
        let text = q.trimmingCharacters(in: .whitespaces)
        guard text.count >= 2 else { results = []; status = nil; return }
        task = Task {
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            status = "Searching…"
            do {
                let found = try await SearchService.search(text, near: app.here ?? app.mapCenter)
                guard text == query.trimmingCharacters(in: .whitespaces) else { return }
                results = found
                status = found.isEmpty ? "No results" : nil
            } catch {
                status = "Search is unavailable right now (\(error.localizedDescription))."
            }
        }
    }

    private func nearby(_ c: Category) {
        task?.cancel()
        if category == c.label { category = nil; results = []; status = nil; return }
        category = c.label
        guard let near = app.here ?? app.origin ?? app.mapCenter else { status = "Waiting for your location…"; return }
        status = "Finding \(c.label.lowercased()) nearby…"
        results = []
        task = Task {
            do {
                let found = try await SearchService.nearby(c, near: near)
                guard category == c.label else { return }
                results = found
                status = found.isEmpty ? "Nothing found nearby." : nil
            } catch {
                status = "Couldn't load nearby places (\(error.localizedDescription))."
            }
        }
    }
}
