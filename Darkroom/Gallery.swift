import SwiftUI

/// Every print on knotwork.ca with a photo, newest first, under Start on the
/// home screen. Read straight from the server, so it needs a connection; the
/// photos themselves are cached. Long press a print to add a layer, edit,
/// hide or delete it.
struct PrintsGrid: View {
    /// Reloads when this changes (the home screen's lists refresh).
    var reload: Date?
    @Environment(AppStore.self) private var store
    @Environment(Walks.self) private var walks
    @State private var prints: [JSON] = []
    @State private var loading = true
    @State private var error: String?
    @State private var withoutPhotos = false
    @State private var showHidden = false
    @State private var editing: JSON?
    @State private var deleting: JSON?
    @State private var round = 0        // a refresh tries photos that failed again
    /// Prints hidden on this phone, by id ("12,15").
    @AppStorage("hiddenPrints") private var hiddenList = ""

    private var hidden: Set<Int> { Set(hiddenList.split(separator: ",").compactMap { Int($0) }) }
    private var shown: [JSON] {
        prints.filter { p in
            (withoutPhotos || p["image_path"].string != nil) && (showHidden || !hidden.contains(p["id"].int ?? 0))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PRINTS").font(Theme.label).tracking(2).foregroundStyle(Theme.dim)
                Spacer()
                Menu {
                    Toggle("Prints without a photo too", isOn: $withoutPhotos)
                    Toggle("Hidden prints too", isOn: $showHidden)
                } label: { Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(Theme.red) }
            }
            if loading && prints.isEmpty { ProgressView().tint(Theme.red).frame(maxWidth: .infinity).padding(30) }
            if let error { Text(error).font(Theme.small).foregroundStyle(Theme.dim) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                ForEach(shown, id: \.self["id"].int) { p in
                    let id = p["id"].int ?? 0
                    NavigationLink(value: id) { Tile(print: p, base: store.server.base) }
                        .buttonStyle(.plain)
                        .opacity(hidden.contains(id) ? 0.4 : 1)
                        .contextMenu {
                            if canAddLayer(p) { Button("Add a layer", systemImage: "square.3.layers.3d") { walks.addLayer(to: p) } }
                            Button("Edit", systemImage: "pencil") { editing = p }
                            if hidden.contains(id) {
                                Button("Show", systemImage: "eye") { setHidden(id, false) }
                            } else {
                                Button("Hide", systemImage: "eye.slash") { setHidden(id, true) }
                            }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = p }
                        }
                }
            }
            .id(round)
            if !loading && shown.isEmpty && error == nil {
                Text("No photos yet").font(Theme.small).foregroundStyle(Theme.dim).padding(.vertical, 20)
            }
        }
        .navigationDestination(for: Int.self) { id in
            PrintPager(prints: shown, startId: id, base: store.server.base) { await load() }
        }
        .task(id: reload) { await load() }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let editing { PrintEditor(print: editing) { await load() } }
        }
        .confirmationDialog("Delete this print?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible, presenting: deleting) { p in
            Button("Delete", role: .destructive) { Task { await delete(p) } }
            Button("Keep it", role: .cancel) {}
        } message: { p in
            Text("\(printName(p)) — its photo, steps and notes are deleted from knotwork.ca. This can't be undone.")
        }
    }

    private func setHidden(_ id: Int, _ on: Bool) {
        var h = hidden
        if on { h.insert(id) } else { h.remove(id) }
        hiddenList = h.sorted().map(String.init).joined(separator: ",")
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { prints = try await store.server.request("darkroom-api.php?res=photo").array; error = nil; round += 1 }
        catch where Task.isCancelled { }      // a newer reload took over
        catch let e as ServerError { error = e.retry ? "Can't reach knotwork.ca — photos need a connection" : e.message }
        catch { self.error = error.localizedDescription }
    }

    private func delete(_ p: JSON) async {
        guard let id = p["id"].int else { return }
        do {
            _ = try await store.server.request("darkroom-api.php?res=photo&id=\(id)", method: "DELETE")
            prints.removeAll { $0["id"].int == id }
            setHidden(id, false)
            error = nil
        } catch let e as ServerError {
            error = e.retry ? "Can't reach knotwork.ca — nothing was deleted" : "Not deleted: \(e.message)"
        } catch { self.error = error.localizedDescription }
    }
}

private func imageURL(_ path: String?, _ base: URL) -> URL? { path.flatMap { URL(string: $0, relativeTo: base) } }

/// A finished print can be walked again for another layer; one still in
/// progress carries on from the home screen instead.
func canAddLayer(_ p: JSON) -> Bool { p["status"].string != "in_progress" }

/// A print's name: its title and edition, "Print 2/10".
func printName(_ p: JSON, none: String = "Print") -> String {
    [p["title"].string ?? none, p["edition"].string].compactMap { $0 }.joined(separator: " ")
}

private struct Tile: View {
    let print: JSON
    let base: URL
    var body: some View {
        let url = imageURL(print["thumb_path"].string ?? print["image_path"].string, base)
        Color.clear.aspectRatio(1, contentMode: .fit)
            .overlay {
                if let url {
                    AsyncImage(url: url) { img in img.resizable().scaledToFill() } placeholder: { Theme.box }
                } else {
                    Text(printName(print, none: "#\(print["id"].int ?? 0)")).font(Theme.small)
                        .foregroundStyle(.black).padding(6).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.box)
                }
            }
            .clipShape(.rect(cornerRadius: 6))
            .overlay(alignment: .bottomLeading) {
                if url != nil, let d = print["date_exposed"].string {
                    Text(d).font(.system(size: 10, design: .monospaced)).foregroundStyle(.white)
                        .padding(.horizontal, 4).background(.black.opacity(0.55), in: .rect(cornerRadius: 3)).padding(4)
                }
            }
    }
}

/// The prints in gallery order, one at a time: swipe left for the next,
/// right for the one before. Paging, so it wins over the swipe back to the grid
/// (which still works from the first print).
private struct PrintPager: View {
    let prints: [JSON]
    let base: URL
    let reload: () async -> Void
    @State private var id: Int?
    @State private var editing = false

    init(prints: [JSON], startId: Int, base: URL, reload: @escaping () async -> Void) {
        self.prints = prints; self.base = base; self.reload = reload
        _id = State(initialValue: startId)
    }

    private var ids: [Int] { prints.compactMap { $0["id"].int } }
    private var current: JSON? { prints.first { $0["id"].int == id } }

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 0) {
                ForEach(ids, id: \.self) { pid in
                    if let p = prints.first(where: { $0["id"].int == pid }) {
                        PrintDetail(print: p, base: base).containerRelativeFrame(.horizontal)
                    }
                }
            }
            .scrollTargetLayout()
        }
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $id)
        .scrollIndicators(.hidden)
        .background(Theme.bg)
        .navigationTitle(current.map { printName($0) } ?? "Print")
        .navigationBarTitleDisplayMode(.inline)
        // Editing is a sheet over the pager, so no swiping while it's open.
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true }.disabled(current == nil) } }
        .sheet(isPresented: $editing) {
            if let current { PrintEditor(print: current) { await reload() } }
        }
    }
}

/// One print: the photo, then what was recorded for it, layer by layer.
struct PrintDetail: View {
    let print: JSON
    let base: URL
    @Environment(Walks.self) private var walks
    @State private var zoom = false

    /// The print's layers, each with its own steps; one heading per layer
    /// once there is more than one.
    private var layers: [(head: String?, notes: String?, steps: [JSON])] {
        let ls = print["layers"].array, steps = print["steps"].array
        guard ls.count > 1 else { return [(nil, nil, steps)] }
        return ls.map { l in
            let n = l["layer_no"].int ?? 1
            let head = ["LAYER \(n)", l["preset_name"].string, l["date_done"].string, l["status"].string == "in_progress" ? "in progress" : nil]
                .compactMap { $0 }.joined(separator: " · ")
            return (head, l["notes"].string, steps.filter { ($0["layer_no"].int ?? 1) == n })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let url = imageURL(print["image_path"].string, base) {
                    AsyncImage(url: url) { img in img.resizable().scaledToFit() } placeholder: {
                        Theme.box.aspectRatio(4 / 3, contentMode: .fit)
                    }
                    .clipShape(.rect(cornerRadius: 8))
                    .onTapGesture { zoom = true }
                }
                Text(printName(print).uppercased()).font(Theme.display(36)).foregroundStyle(Theme.red)
                Text([print["type_name"].string, print["preset_name"].string, print["date_exposed"].string, "#\(print["id"].int ?? 0)"]
                    .compactMap { $0 }.joined(separator: " · ")).font(Theme.small).foregroundStyle(Theme.dim)
                if let n = print["notes"].string { Text(n).font(Theme.body) }
                if canAddLayer(print) {
                    Button("Add a layer", systemImage: "square.3.layers.3d") { walks.addLayer(to: print) }
                        .font(Theme.body.weight(.semibold)).foregroundStyle(Theme.red)
                }
                ForEach(Array(layers.enumerated()), id: \.offset) { _, l in
                    if let h = l.head { Text(h).font(Theme.label).tracking(1.5).foregroundStyle(Theme.bright).padding(.top, 6) }
                    if let n = l.notes { Text(n).font(Theme.body) }
                    VStack(spacing: 0) {
                        ForEach(Array(l.steps.enumerated()), id: \.offset) { _, s in
                            HStack(alignment: .firstTextBaseline) {
                                Text(s["name"].string ?? "Step").font(Theme.body.weight(.semibold))
                                Spacer()
                                Text(stepSummary(s)).font(Theme.small).foregroundStyle(Theme.dim)
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
            .padding(16)
        }
        .fullScreenCover(isPresented: $zoom) {
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImage(url: imageURL(print["image_path"].string, base)) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
            }
            .onTapGesture { zoom = false }
        }
    }

    private func stepSummary(_ s: JSON) -> String {
        if s["skipped"].flag { return "skipped" }
        return [s["seconds"].int.map(Duration.format), s["temp"].double.map { "\($0.formatted()) °C" }].compactMap { $0 }.joined(separator: " · ")
    }
}
