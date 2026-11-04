import SwiftUI

/// Every print on knotwork.ca with a photo, newest first. Read straight from
/// the server, so it needs a connection; the photos themselves are cached.
struct GalleryView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var prints: [JSON] = []
    @State private var loading = true
    @State private var error: String?
    @State private var withoutPhotos = false
    @State private var round = 0        // a refresh tries photos that failed again

    private var shown: [JSON] { withoutPhotos ? prints : prints.filter { $0["image_path"].string != nil } }

    var body: some View {
        NavigationStack {
            ScrollView {
                if loading && prints.isEmpty { ProgressView().tint(Theme.red).padding(40) }
                if let error { Text(error).font(Theme.small).foregroundStyle(Theme.dim).padding() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                    ForEach(shown, id: \.self["id"].int) { p in
                        NavigationLink(value: p["id"].int ?? 0) { Tile(print: p, base: store.server.base) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(8)
                .id(round)
                if !loading && shown.isEmpty && error == nil {
                    Text("No photos yet").font(Theme.small).foregroundStyle(Theme.dim).padding(40)
                }
            }
            .background(Theme.bg)
            .refreshable { await load() }
            .navigationTitle("Prints")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Toggle("Prints without a photo too", isOn: $withoutPhotos)
                    } label: { Image(systemName: "line.3.horizontal.decrease.circle") }
                }
            }
            .navigationDestination(for: Int.self) { id in
                PrintPager(prints: shown, startId: id, base: store.server.base) { await load() }
            }
            .task { await load() }
        }
        .tint(Theme.red)
    }

    private func load() async {
        loading = true; defer { loading = false }
        do { prints = try await store.server.request("darkroom-api.php?res=photo").array; error = nil; round += 1 }
        catch let e as ServerError { error = e.retry ? "Can't reach knotwork.ca — photos need a connection" : e.message }
        catch { self.error = error.localizedDescription }
    }
}

private func imageURL(_ path: String?, _ base: URL) -> URL? { path.flatMap { URL(string: $0, relativeTo: base) } }

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

/// One print: the photo, then what was recorded for it.
struct PrintDetail: View {
    let print: JSON
    let base: URL
    @State private var zoom = false

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
                let steps = print["steps"].array
                if !steps.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.offset) { _, s in
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
        return [s["seconds"].int.map(Duration.format), s["temp"].double.map { "\($0.formatted()) °C" },
                s["layer_no"].int.flatMap { $0 > 1 ? "L\($0)" : nil }].compactMap { $0 }.joined(separator: " · ")
    }
}
