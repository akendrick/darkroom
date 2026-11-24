import SwiftUI

// A process's Tests (sizing tests, pigment tests): the Tests category under a
// process, the tried mark, the gallery prints a test links to, and a print's
// own tests. All read and saved straight to knotwork.ca (needs a connection).

/// The two kinds of test and the list each opens.
enum TestKind: String {
    case size, pigment
    var spec: ListSpec { ListSpec.of(self == .size ? "size_test" : "pigment_test") }
    var resource: String { self == .size ? "size_test" : "pigment_test" }
    var noun: String { self == .size ? "Sizing test" : "Pigment test" }
}

extension AppStore {
    /// The kinds of test each process has (test_kind), fetched once per launch; [] when the server has none yet.
    func loadTestKinds() async {
        guard testKinds == nil else { return }
        testKinds = (try? await list("test_kind")) ?? []
    }
    func testKinds(for processId: Int) -> [JSON] { (testKinds ?? []).filter { $0["process_id"].int == processId } }
}

private func countLine(_ k: JSON) -> String {
    let n = k["tests"].int ?? 0, t = k["tried"].int ?? 0
    return "\(n) test\(n == 1 ? "" : "s"), \(t) tried"
}

/// Under a process on the start page: TESTS, then each kind of test it has.
struct ProcessTestsTree: View {
    @Environment(AppStore.self) private var store
    let processId: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TESTS").font(Theme.label.weight(.bold)).tracking(1.5).foregroundStyle(Theme.bright).padding(.top, 6)
            let kinds = store.testKinds(for: processId)
            if kinds.isEmpty {
                Text(store.testKinds == nil ? "Loading…" : "No tests for this process yet").font(Theme.small).foregroundStyle(Theme.dim)
            }
            ForEach(kinds, id: \.self["id"].int) { k in
                if let kind = TestKind(rawValue: k["kind"].string ?? "") {
                    NavigationLink(value: kind.spec) {
                        HStack {
                            Label(k["name"].string ?? kind.spec.title, systemImage: kind == .size ? "square.grid.3x3" : "drop.fill")
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(TreeRowStyle(fill: Theme.stageBar, text: Theme.stageText))
                }
            }
        }
        .task { await store.loadTestKinds() }
    }
}

/// On a process's overview: a Tests heading and a card for each kind of test.
struct ProcessTestsCards: View {
    @Environment(AppStore.self) private var store
    let processId: Int
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TESTS").font(Theme.label).tracking(2).foregroundStyle(Theme.dim).padding(.top, 8)
            let kinds = store.testKinds(for: processId)
            if kinds.isEmpty {
                Text(store.testKinds == nil ? "Loading…" : "No tests for this process yet.").font(Theme.small).foregroundStyle(Theme.dim)
            }
            ForEach(kinds, id: \.self["id"].int) { k in
                if let kind = TestKind(rawValue: k["kind"].string ?? "") {
                    NavigationLink(value: kind.spec) {
                        HStack(spacing: 12) {
                            Image(systemName: kind == .size ? "square.grid.3x3" : "drop.fill").font(.system(size: 24, weight: .semibold)).frame(width: 34, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(k["name"].string ?? kind.spec.title).font(Theme.body.weight(.bold))
                                Text(countLine(k)).font(Theme.small).foregroundStyle(Theme.dim)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.body.weight(.bold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(WalkButtonStyle())
                }
            }
        }
        .task { await store.loadTestKinds() }
    }
}

/// The tried mark on the left of a test's row: one tap marks it tried (dated today), another clears it.
struct TriedButton: View {
    let on: Bool
    let toggle: () -> Void
    var body: some View {
        Button(action: toggle) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(on ? Theme.inkOnBox : Theme.subOnBox.opacity(0.6))
                .frame(width: 40, height: 44).contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(on ? "Tried — tap to clear" : "Not tried — tap to mark tried")
    }
}

/// A print from the gallery opened by its id (a test's thumbnail, a test's print list).
struct PrintByID: View {
    let id: Int
    @Environment(AppStore.self) private var store
    @State private var print: JSON?
    @State private var error: String?

    private func fetch() async -> [JSON] {
        do { let p = try await store.server.request("darkroom-api.php?res=photo&id=\(id)"); error = nil; return [p] }
        catch let e as ServerError { error = e.retry ? "Can't reach knotwork.ca — the print needs a connection" : e.message }
        catch { self.error = error.localizedDescription }
        return []
    }

    var body: some View {
        Group {
            if let print {
                PrintPager(prints: [print], startId: id, base: store.server.base) { await fetch() }
            } else if let error {
                Text(error).font(Theme.small).foregroundStyle(Theme.dim).padding(30)
            } else {
                ProgressView().tint(Theme.red)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.bg)
        .task { print = await fetch().first }
    }
}

/// One pigment in a test, as edited: which pigment and how much.
struct PigmentAmount: Identifiable, Equatable {
    let id = UUID()
    var pigmentId: Int?
    var grams: Double?
    var ml: Double?
    init(pigmentId: Int? = nil, grams: Double? = nil, ml: Double? = nil) { self.pigmentId = pigmentId; self.grams = grams; self.ml = ml }
    init(_ j: JSON) { self.init(pigmentId: j["pigment_id"].int, grams: j["grams"].double, ml: j["ml"].double) }
    var asJSON: JSON? {
        guard let pigmentId else { return nil }
        return .object(["pigment_id": .from(pigmentId), "grams": .from(grams), "ml": .from(ml)])
    }
}

/// A pigment test's pigments: each one's grams and/or mL, as many as were mixed.
struct PigmentsEditor: View {
    @Binding var rows: [PigmentAmount]
    let options: [JSON]
    /// Fills the rows from the chosen glop batch's own pigments.
    let fromBatch: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach($rows) { $r in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Picker("Pigment", selection: $r.pigmentId) {
                            Text("— pigment —").tag(Int?.none)
                            ForEach(options, id: \.self["id"].int) { o in Text(o["name"].string ?? "#\(o["id"].int ?? 0)").tag(o["id"].int) }
                        }.pickerStyle(.menu).labelsHidden()
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button { rows.removeAll { $0.id == r.id } } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove this pigment")
                    }
                    HStack(spacing: 8) {
                        amount($r.grams, "g")
                        amount($r.ml, "mL")
                        Spacer(minLength: 0)
                    }
                }
                Divider()
            }
            HStack(spacing: 16) {
                Button("Add a pigment", systemImage: "plus") { rows.append(PigmentAmount()) }.buttonStyle(.borderless)
                if let fromBatch { Button("From the batch", systemImage: "arrow.down.doc") { fromBatch() }.buttonStyle(.borderless) }
            }
            .font(Theme.small.weight(.bold))
        }
    }

    /// One amount in a small box, with its unit after it.
    private func amount(_ v: Binding<Double?>, _ unit: String) -> some View {
        HStack(spacing: 4) {
            NumberField(value: v, whole: false)
                .multilineTextAlignment(.trailing)
                .padding(.horizontal, 8).padding(.vertical, 6)
                .frame(width: 80)
                .background(Theme.line.opacity(0.35), in: .rect(cornerRadius: 6))
            Text(unit).font(Theme.small)
        }
    }
}

/// A test's prints from the gallery: tap one to open it; press and hold to make it the main print or unlink it.
/// The + links another print. The main print is the test's thumbnail in its list.
struct TestPrints: View {
    let kind: TestKind
    let testId: Int
    @Environment(AppStore.self) private var store
    @State private var links: [JSON] = []
    @State private var gallery: [JSON] = []
    @State private var note: String?
    @State private var busy = false
    @State private var picking = false
    @State private var opening: Int?

    private func url(_ p: String?) -> URL? { p.flatMap { URL(string: $0, relativeTo: store.server.base) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                ForEach(links, id: \.self["id"].int) { l in
                    VStack(spacing: 2) {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay { AsyncImage(url: url(l["thumb_path"].string)) { $0.resizable().scaledToFill() } placeholder: { Theme.line.opacity(0.3) } }
                            .clipShape(.rect(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(l["is_main"].flag ? Theme.inkOnBox : .clear, lineWidth: 2))
                            .onTapGesture { opening = l["photo_id"].int }
                            .contextMenu {
                                if !l["is_main"].flag { Button("Make main print", systemImage: "star") { Task { await act(l, "PATCH", ["is_main": 1]) } } }
                                Button("Unlink from the test", systemImage: "link", role: .destructive) { Task { await act(l, "DELETE", nil) } }
                            }
                            .accessibilityLabel("Print \(l["title"].string ?? "")\(l["is_main"].flag ? ", main" : "")")
                        Text(l["title"].string ?? "#\(l["photo_id"].int ?? 0)").font(.caption2).foregroundStyle(Theme.subOnBox).lineLimit(1)
                    }
                }
                Button { picking = true } label: {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay { if busy { ProgressView().tint(Theme.inkOnBox) } else { Image(systemName: "plus").font(.title3) } }
                        .foregroundStyle(Theme.inkOnBox)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.inkOnBox.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
                .buttonStyle(.borderless).disabled(busy)
                .accessibilityLabel("Link a print from the gallery")
            }
            if links.isEmpty { Text("No prints linked yet. + picks one from the gallery.").font(Theme.small).foregroundStyle(Theme.subOnBox) }
            if let note { Text(note).font(Theme.small).foregroundStyle(Theme.inkOnBox) }
        }
        .task { await reload() }
        .sheet(isPresented: $picking) { GalleryPicker(exclude: Set(links.compactMap { $0["photo_id"].int })) { id in Task { await link(id) } } }
        .sheet(item: Binding(get: { opening.map(IntBox.init) }, set: { opening = $0?.id })) { b in
            NavigationStack { PrintByID(id: b.id).toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { opening = nil } } } }
        }
    }

    private func reload() async {
        do { links = try await store.list("test_print&kind=\(kind.rawValue)&test=\(testId)"); note = nil }
        catch let e as ServerError { note = e.retry ? "Can't reach knotwork.ca — prints need a connection" : e.message }
        catch { self.note = error.localizedDescription }
    }
    private func call(_ run: () async throws -> Void) async {
        busy = true; defer { busy = false }
        do { try await run(); note = nil; await reload() }
        catch let e as ServerError { note = e.retry ? "Can't reach knotwork.ca — try again with a connection" : e.message }
        catch { note = error.localizedDescription }
    }
    private func link(_ photo: Int) async {
        await call { _ = try await store.server.request("darkroom-api.php?res=test_print", method: "POST",
                                                        body: .object(["kind": .string(kind.rawValue), "test_id": .from(testId), "photo_id": .from(photo)])) }
    }
    private func act(_ l: JSON, _ method: String, _ body: [String: JSON]?) async {
        guard let id = l["id"].int else { return }
        await call { _ = try await store.server.request("darkroom-api.php?res=test_print&id=\(id)", method: method, body: body.map { .object($0) }) }
    }
}

struct IntBox: Identifiable { let id: Int }

/// Choose a finished print from the gallery (newest first), by its photo.
struct GalleryPicker: View {
    let exclude: Set<Int>
    let chosen: (Int) -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var prints: [JSON] = []
    @State private var search = ""
    @State private var error: String?

    private var shown: [JSON] {
        prints.filter { p in
            p["status"].string != "in_progress" && !exclude.contains(p["id"].int ?? 0)
                && (search.isEmpty || printName(p).localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let error { Text(error).font(Theme.small).foregroundStyle(Theme.dim).padding() }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 10) {
                    ForEach(shown, id: \.self["id"].int) { p in
                        Button { if let id = p["id"].int { chosen(id); dismiss() } } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Color.clear.aspectRatio(0.8, contentMode: .fit)
                                    .overlay {
                                        if let path = p["thumb_path"].string ?? p["image_path"].string, let u = URL(string: path, relativeTo: store.server.base) {
                                            AsyncImage(url: u) { $0.resizable().scaledToFill() } placeholder: { Theme.fill }
                                        } else { Theme.fill.overlay { Image(systemName: "photo").foregroundStyle(Theme.dim) } }
                                    }
                                    .clipShape(.rect(cornerRadius: 5))
                                Text(printName(p)).font(.caption.weight(.bold)).foregroundStyle(Theme.red).lineLimit(2)
                                Text(p["date_exposed"].string ?? "").font(.caption2).foregroundStyle(Theme.dim)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
            .searchable(text: $search, prompt: "Title")
            .background(Theme.bg)
            .navigationTitle("Pick a print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .task {
                do { prints = try await store.server.request("darkroom-api.php?res=photo").array; error = nil }
                catch let e as ServerError { error = e.retry ? "Can't reach knotwork.ca — the gallery needs a connection" : e.message }
                catch { self.error = error.localizedDescription }
            }
        }
        .tint(Theme.red)
    }
}

/// On a print: the tests it shows, Add to a test, and New pigment test (which starts from this print's tissue and batch).
struct PrintTests: View {
    let photoId: Int
    @Environment(AppStore.self) private var store
    @State private var tests: [JSON] = []
    @State private var pigment: [JSON] = []
    @State private var sizing: [JSON] = []
    @State private var note: String?
    @State private var unavailable = false
    @State private var editing: (TestKind, JSON)?

    var body: some View {
        if !unavailable {
            VStack(alignment: .leading, spacing: 8) {
                Text("TESTS").font(Theme.label).tracking(1.5).foregroundStyle(Theme.bright).padding(.top, 6)
                ForEach(tests, id: \.self["id"].int) { t in
                    Button { Task { await open(t) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: t["tried"].flag ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.red)
                            Text("\(TestKind(rawValue: t["kind"].string ?? "")?.noun ?? "Test") \(t["label"].string ?? "")")
                                .font(Theme.body.weight(.semibold)).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.right").font(.footnote.weight(.bold))
                        }
                        .foregroundStyle(Theme.red)
                    }
                    .buttonStyle(.plain)
                }
                if tests.isEmpty { Text("Not in any test yet").font(Theme.small).foregroundStyle(Theme.dim) }
                HStack(spacing: 18) {
                    Menu {
                        let have = Set(tests.map { "\($0["kind"].string ?? "")\($0["test_id"].int ?? 0)" })
                        Section("Pigment tests") {
                            ForEach(pigment.filter { !have.contains("pigment\($0["id"].int ?? 0)") }, id: \.self["id"].int) { t in
                                Button(ListSpec.pigmentTestLabel(t)) { Task { await link(.pigment, t) } }
                            }
                        }
                        Section("Sizing tests") {
                            ForEach(sizing.filter { !have.contains("size\($0["id"].int ?? 0)") }, id: \.self["id"].int) { t in
                                Button([t["code"].string, t["lane"].string].compactMap { $0 }.joined(separator: " ")) { Task { await link(.size, t) } }
                            }
                        }
                    } label: { Label("Add to a test", systemImage: "link") }
                    Button("New pigment test", systemImage: "plus") { Task { await newPigmentTest() } }
                }
                .font(Theme.body.weight(.semibold)).foregroundStyle(Theme.red)
                if let note { Text(note).font(Theme.small).foregroundStyle(Theme.dim) }
            }
            .task { await reload() }
            .sheet(item: Binding(get: { editing.map { EditBox(kind: $0.0, row: $0.1) } }, set: { editing = $0.map { ($0.kind, $0.row) } })) { e in
                RowForm(spec: e.kind.spec, row: e.row) { await reload() }
            }
        }
    }

    private struct EditBox: Identifiable { let kind: TestKind; let row: JSON; var id: Int { row["id"].int ?? 0 } }

    private func fail(_ e: Error) {
        if let e = e as? ServerError {
            if e.message.localizedCaseInsensitiveContains("not set up") { unavailable = true; return }
            note = e.retry ? "Can't reach knotwork.ca — tests need a connection" : e.message
        } else { note = e.localizedDescription }
    }
    private func reload() async {
        do {
            tests = try await store.list("test_print&photo=\(photoId)")
            pigment = try await store.list("pigment_test")
            sizing = (try? await store.list("size_test")) ?? []
            note = nil
        } catch { fail(error) }
    }
    private func open(_ t: JSON) async {
        guard let kind = TestKind(rawValue: t["kind"].string ?? ""), let id = t["test_id"].int else { return }
        do { editing = (kind, try await store.server.request("darkroom-api.php?res=\(kind.resource)&id=\(id)")) } catch { fail(error) }
    }
    private func link(_ kind: TestKind, _ t: JSON) async {
        do {
            _ = try await store.server.request("darkroom-api.php?res=test_print", method: "POST",
                                               body: .object(["kind": .string(kind.rawValue), "test_id": t["id"], "photo_id": .from(photoId)]))
            await reload()
        } catch { fail(error) }
    }
    /// The new test takes this print's tissue, the tissue's batch and pigments, and its exposure; then it opens to be scored.
    private func newPigmentTest() async {
        do {
            let r = try await store.server.request("darkroom-api.php?res=pigment_test", method: "POST", body: .object(["from_photo": .from(photoId)]))
            await reload()
            if let id = r["id"].int { editing = (.pigment, try await store.server.request("darkroom-api.php?res=pigment_test&id=\(id)")) }
        } catch { fail(error) }
    }
}
