import PhotosUI
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
                        PrintDetail(print: p, base: base, reload: reload).containerRelativeFrame(.horizontal)
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

/// One print: its photos, then what was recorded for it, layer by layer.
/// Tap a small photo to see it; long press it to make it the main photo,
/// caption or remove it; + adds a detail photo. Those go straight to the server.
struct PrintDetail: View {
    let print: JSON
    let base: URL
    let reload: () async -> Void
    @Environment(AppStore.self) private var store
    @Environment(Walks.self) private var walks
    @State private var zoom = false
    @State private var shownId: Int?
    @State private var camera = false
    @State private var showLibrary = false
    @State private var library: PhotosPickerItem?
    @State private var busy = false
    @State private var note: String?
    @State private var captioning: JSON?
    @State private var caption = ""
    @State private var removing: JSON?

    /// The main photo first, then the details. A print saved before detail
    /// photos has only its main one.
    private var images: [JSON] {
        let i = print["images"].array
        if !i.isEmpty { return i }
        return print["image_path"].string.map { [.object(["image_path": .string($0), "thumb_path": print["thumb_path"], "is_main": 1])] } ?? []
    }
    private var shown: JSON? { images.first { $0["id"].int != nil && $0["id"].int == shownId } ?? images.first }

    /// The print's layers, each with its own steps; one heading per layer
    /// once there is more than one, or one has a name or extra items.
    private var layers: [(head: String?, notes: String?, items: String?, steps: [JSON])] {
        let ls = print["layers"].array, steps = print["steps"].array
        let named = ls.contains { $0["label"].string != nil || !$0["items"].array.isEmpty }
        guard ls.count > 1 || named else { return [(nil, nil, nil, steps)] }
        return ls.map { l in
            let n = l["layer_no"].int ?? 1
            let head = ["LAYER \(n)", l["label"].string, l["preset_name"].string, l["date_done"].string,
                        l["status"].string == "in_progress" ? "in progress" : nil]
                .compactMap { $0 }.joined(separator: " · ")
            return (head, l["notes"].string, LinkRow.summary(l["items"].array, item: true),
                    steps.filter { ($0["layer_no"].int ?? 1) == n })
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                photos
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
                    if let it = l.items { Text("Also used: " + it).font(Theme.small).foregroundStyle(Theme.dim) }
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
                AsyncImage(url: imageURL(shown?["image_path"].string, base)) { img in img.resizable().scaledToFit() } placeholder: { ProgressView() }
            }
            .onTapGesture { zoom = false }
        }
        .photosPicker(isPresented: $showLibrary, selection: $library, matching: .images)
        .onChange(of: library) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { await addDetail(img) }
                library = nil
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraView(note: { note = $0 }) { img in camera = false; if let img { Task { await addDetail(img) } } }.ignoresSafeArea()
        }
        .alert("Caption", isPresented: Binding(get: { captioning != nil }, set: { if !$0 { captioning = nil } })) {
            TextField("Corner, edge, highlight detail…", text: $caption)
            Button("Save") { if let c = captioning { Task { await change(c, ["caption": .from(caption.isEmpty ? nil : caption)]) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove this photo?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { i in
            Button("Remove", role: .destructive) { Task { await remove(i) } }
            Button("Keep it", role: .cancel) {}
        } message: { i in
            Text(i["is_main"].flag ? "It's the main photo. The print has no main photo until you make a detail one main."
                                   : "It's deleted from knotwork.ca.")
        }
    }

    @ViewBuilder private var photos: some View {
        if let s = shown, let url = imageURL(s["image_path"].string, base) {
            AsyncImage(url: url) { img in img.resizable().scaledToFit() } placeholder: {
                Theme.box.aspectRatio(4 / 3, contentMode: .fit)
            }
            .clipShape(.rect(cornerRadius: 8))
            .onTapGesture { zoom = true }
            if let c = s["caption"].string { Text(c).font(Theme.small).foregroundStyle(Theme.dim) }
        }
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 58), spacing: 6)], spacing: 6) {
            ForEach(Array(images.enumerated()), id: \.offset) { _, i in
                let on = i["id"].int == shown?["id"].int
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay {
                        AsyncImage(url: imageURL(i["thumb_path"].string ?? i["image_path"].string, base)) { $0.resizable().scaledToFill() }
                            placeholder: { Theme.box }
                    }
                    .clipShape(.rect(cornerRadius: 5))
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(on ? Theme.red : .clear, lineWidth: 2))
                    .overlay(alignment: .topLeading) {
                        if i["is_main"].flag && images.count > 1 {
                            Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(.white)
                                .padding(3).background(.black.opacity(0.55), in: .circle).padding(3)
                        }
                    }
                    .onTapGesture { shownId = i["id"].int }
                    .contextMenu {
                        if i["id"].int != nil {
                            if !i["is_main"].flag {
                                Button("Make main photo", systemImage: "star") { Task { await change(i, ["is_main": 1]) } }
                            }
                            Button("Caption", systemImage: "text.bubble") { caption = i["caption"].string ?? ""; captioning = i }
                            Button("Remove", systemImage: "trash", role: .destructive) { removing = i }
                        }
                    }
                    .accessibilityLabel(i["is_main"].flag ? "Main photo" : (i["caption"].string ?? "Detail photo"))
            }
            Menu {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo", systemImage: "camera") { camera = true }
                }
                Button("Photo Library", systemImage: "photo") { showLibrary = true }
            } label: {
                Color.clear.aspectRatio(1, contentMode: .fit)
                    .overlay { if busy { ProgressView().tint(Theme.red) } else { Image(systemName: "plus").font(.title3) } }
                    .foregroundStyle(Theme.red)
                    .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: [4])))
            }
            .disabled(busy)
            .accessibilityLabel(images.isEmpty ? "Add a photo" : "Add a detail photo")
        }
        if let note { Text(note).font(Theme.small).foregroundStyle(Theme.red) }
    }

    private func call(_ what: String, _ run: () async throws -> Void) async {
        busy = true; defer { busy = false }
        do { try await run(); note = nil; await reload() }
        catch let e as ServerError { note = e.retry ? "Can't reach knotwork.ca — \(what) didn't happen" : e.message }
        catch { note = error.localizedDescription }
    }

    /// The first photo of a print without one becomes its main photo.
    private func addDetail(_ img: UIImage) async {
        guard let id = print["id"].int, let jpeg = img.shrunk(to: 1800).jpegData(compressionQuality: 0.9) else { return }
        await call("the photo upload") {
            let r = try await store.server.upload(jpeg: jpeg, photoId: id, detail: !images.isEmpty)
            shownId = r["id"].int
        }
    }
    private func change(_ i: JSON, _ body: [String: JSON]) async {
        guard let id = print["id"].int, let iid = i["id"].int else { return }
        await call("the change") {
            _ = try await store.server.request("darkroom-api.php?res=photo_image&id=\(id)&image=\(iid)", method: "PATCH", body: .object(body))
        }
    }
    private func remove(_ i: JSON) async {
        guard let id = print["id"].int, let iid = i["id"].int else { return }
        await call("the removal") {
            _ = try await store.server.request("darkroom-api.php?res=photo_image&id=\(id)&image=\(iid)", method: "DELETE")
            if shownId == iid { shownId = nil }
        }
    }

    private func stepSummary(_ s: JSON) -> String {
        if s["skipped"].flag { return "skipped" }
        return [s["seconds"].int.map(Duration.format), s["temp"].double.map { "\($0.formatted()) °C" }].compactMap { $0 }.joined(separator: " · ")
    }
}
