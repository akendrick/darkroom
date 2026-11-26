import SwiftUI

// A process's Tests (sizing tests, pigment tests): the Tests category under a
// process, the tried mark, the gallery prints a test links to, and a print's
// own tests. All read and saved straight to knotwork.ca (needs a connection).

/// The kinds of test: sizing and pigment are built in; custom ones are made up by the owner
/// (a name and the fields each test records; migration 036) and their list comes from the kind (ListSpec.custom).
enum TestKind: String {
    case size, pigment, custom
    var resource: String {
        switch self { case .size: "size_test"; case .pigment: "pigment_test"; case .custom: "custom_test" }
    }
    var noun: String {
        switch self { case .size: "Sizing test"; case .pigment: "Pigment test"; case .custom: "Test" }
    }
    var icon: String {
        switch self { case .size: "square.grid.3x3"; case .pigment: "drop.fill"; case .custom: "testtube.2" }
    }
    /// The list a kind of test (a test_kind row) opens.
    static func spec(_ k: JSON) -> ListSpec? {
        switch TestKind(rawValue: k["kind"].string ?? "") {
        case .size: ListSpec.of("size_test")
        case .pigment: ListSpec.of("pigment_test")
        case .custom: ListSpec.custom(k)
        case nil: nil
        }
    }
}

extension AppStore {
    /// The kinds of test each process has (test_kind), fetched once per launch; [] when the server has none yet.
    func loadTestKinds() async {
        guard testKinds == nil else { return }
        testKinds = (try? await list("test_kind")) ?? []
    }
    func testKinds(for processId: Int) -> [JSON] { (testKinds ?? []).filter { $0["process_id"].int == processId } }
    /// Fetch them again (after a kind or its fields change).
    func reloadTestKinds() async {
        if let k = try? await list("test_kind") { testKinds = k }
    }
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
                if let kind = TestKind(rawValue: k["kind"].string ?? ""), let spec = TestKind.spec(k) {
                    NavigationLink(value: spec) {
                        HStack {
                            Label(k["name"].string ?? spec.title, systemImage: kind.icon)
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

/// On a process's overview: a Tests heading, a card for each kind of test, and New kind of test.
struct ProcessTestsCards: View {
    @Environment(AppStore.self) private var store
    let processId: Int
    @State private var newKind = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("TESTS").font(Theme.label).tracking(2).foregroundStyle(Theme.dim).padding(.top, 8)
            let kinds = store.testKinds(for: processId)
            if kinds.isEmpty {
                Text(store.testKinds == nil ? "Loading…" : "No tests for this process yet.").font(Theme.small).foregroundStyle(Theme.dim)
            }
            ForEach(kinds, id: \.self["id"].int) { k in
                if let kind = TestKind(rawValue: k["kind"].string ?? ""), let spec = TestKind.spec(k) {
                    NavigationLink(value: spec) {
                        HStack(spacing: 12) {
                            Image(systemName: kind.icon).font(.system(size: 24, weight: .semibold)).frame(width: 34, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(k["name"].string ?? spec.title).font(Theme.body.weight(.bold))
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
            if store.testKinds != nil {
                Button("New kind of test", systemImage: "plus") { newKind = true }
                    .font(Theme.body.weight(.semibold)).foregroundStyle(Theme.red).padding(.top, 2)
            }
        }
        .task { await store.loadTestKinds() }
        .sheet(isPresented: $newKind) { KindEditor(processId: processId, kind: nil) }
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
                .background(Color.white.opacity(0.7), in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.subOnBox.opacity(0.35), lineWidth: 1))
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
    /// Each made-up kind of test (test_kind row) with its tests.
    @State private var custom: [(kind: JSON, tests: [JSON])] = []
    @State private var note: String?
    @State private var unavailable = false
    @State private var editing: (ListSpec, JSON)?

    var body: some View {
        if !unavailable {
            VStack(alignment: .leading, spacing: 8) {
                Text("TESTS").font(Theme.label).tracking(1.5).foregroundStyle(Theme.bright).padding(.top, 6)
                ForEach(tests, id: \.self["id"].int) { t in
                    Button { Task { await open(t) } } label: {
                        HStack(spacing: 8) {
                            Image(systemName: t["tried"].flag ? "checkmark.circle.fill" : "circle").foregroundStyle(Theme.red)
                            Text("\(t["kind_name"].string ?? TestKind(rawValue: t["kind"].string ?? "")?.noun ?? "Test") \(t["label"].string ?? "")")
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
                                Button(ListSpec.pigmentTestLabel(t) + variantSuffix(t)) { Task { await link(.pigment, t) } }
                            }
                        }
                        Section("Sizing tests") {
                            ForEach(sizing.filter { !have.contains("size\($0["id"].int ?? 0)") }, id: \.self["id"].int) { t in
                                Button([t["code"].string, t["lane"].string].compactMap { $0 }.joined(separator: " ") + variantSuffix(t)) { Task { await link(.size, t) } }
                            }
                        }
                        ForEach(custom, id: \.kind["id"].int) { c in
                            Section(c.kind["name"].string ?? "Tests") {
                                ForEach(c.tests.filter { !have.contains("custom\($0["id"].int ?? 0)") }, id: \.self["id"].int) { t in
                                    Button(ListSpec.custom(c.kind).rowTitle(t) + variantSuffix(t)) { Task { await link(.custom, t) } }
                                }
                            }
                        }
                    } label: { Label("Add to a test", systemImage: "link") }
                    Button("New pigment test", systemImage: "plus") { Task { await newPigmentTest() } }
                }
                .font(Theme.body.weight(.semibold)).foregroundStyle(Theme.red)
                if let note { Text(note).font(Theme.small).foregroundStyle(Theme.dim) }
            }
            .task { await reload() }
            .sheet(item: Binding(get: { editing.map { EditBox(spec: $0.0, row: $0.1) } }, set: { editing = $0.map { ($0.spec, $0.row) } })) { e in
                RowForm(spec: e.spec, row: e.row) { await reload() }
            }
        }
    }

    private struct EditBox: Identifiable { let spec: ListSpec; let row: JSON; var id: Int { row["id"].int ?? 0 } }
    private func variantSuffix(_ t: JSON) -> String {
        guard let v = t["variant"].string else { return "" }
        return " · \(v)" + (t["variant_label"].string.map { " " + $0 } ?? "")
    }

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
            await store.loadTestKinds()
            var c: [(kind: JSON, tests: [JSON])] = []
            for k in (store.testKinds ?? []) where k["kind"].string == "custom" {
                if let id = k["id"].int, let ts = try? await store.list("custom_test&kind_id=\(id)") { c.append((k, ts)) }
            }
            custom = c
            note = nil
        } catch { fail(error) }
    }
    private func open(_ t: JSON) async {
        guard let kind = TestKind(rawValue: t["kind"].string ?? ""), let id = t["test_id"].int else { return }
        let spec: ListSpec? = switch kind {
        case .custom: (store.testKinds ?? []).first { $0["id"].int == t["test_kind_id"].int }.map(ListSpec.custom)
        default: TestKind.spec(.object(["kind": .string(kind.rawValue)]))
        }
        guard let spec else { note = "That kind of test isn't loaded yet; try again"; return }
        do { editing = (spec, try await store.server.request("darkroom-api.php?res=\(kind.resource)&id=\(id)")) } catch { fail(error) }
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
            if let id = r["id"].int { editing = (ListSpec.of("pigment_test"), try await store.server.request("darkroom-api.php?res=pigment_test&id=\(id)")) }
        } catch { fail(error) }
    }
}

// MARK: Variants (migration 036)

/// A variant's letter in a small filled box.
struct VariantTag: View {
    let letter: String
    var body: some View {
        Text(letter).font(Theme.small.weight(.heavy)).foregroundStyle(Theme.onInk)
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Theme.inkOnBox, in: .rect(cornerRadius: 4))
            .accessibilityLabel("Variant \(letter)")
    }
}

/// "B  Foam roller ★" on a test's row.
struct VariantLine: View {
    let row: JSON
    var body: some View {
        HStack(spacing: 6) {
            if let v = row["variant"].string { VariantTag(letter: v) }
            if let l = row["variant_label"].string { Text(l).font(Theme.body.weight(.semibold)).multilineTextAlignment(.leading) }
            if row["chosen"].flag {
                Image(systemName: "star.fill").foregroundStyle(Theme.inkOnBox).accessibilityLabel("The chosen variant")
            }
        }
    }
}

/// Split a test into variants (it becomes A) or add another: the names, and for a sizing test the new sample sheet.
struct VariantSplitSheet: View {
    let kind: TestKind
    let row: JSON
    /// Saves the test, makes the variant and opens it; returns an error to show.
    let make: (_ labelA: String?, _ label: String?, _ sheet: Int?) async -> String?
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var labelA = ""
    @State private var label = ""
    @State private var sheet: Int?
    @State private var sheets: [JSON] = []
    @State private var busy = false
    @State private var error: String?

    private var first: Bool { row["variant"].string == nil }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(first ? "This test becomes A, and the new one B. B starts as a copy of this test's setup, without its scores, notes or prints; then change what's different."
                               : "The new variant starts as a copy of this one's setup, without its scores, notes or prints; then change what's different.")
                        .font(Theme.small).foregroundStyle(Theme.dim)
                    if first {
                        Field(label: "This test (A) is") { TextField("e.g. Brush, 5 mL", text: $labelA) }
                    }
                    Field(label: "The new variant is") { TextField("e.g. Foam roller, 10 mL", text: $label) }
                    if kind == .size {
                        Field(label: "Its sample sheet (each variant is its own sheet)") {
                            if sheets.isEmpty {
                                Text("Every sample sheet already has a test. Add the new sheet under Lists › Support papers first.")
                                    .font(Theme.small).foregroundStyle(Theme.subOnBox)
                            } else {
                                Picker("Sample sheet", selection: $sheet) {
                                    Text("—").tag(Int?.none)
                                    ForEach(sheets, id: \.self["id"].int) { s in Text(ListSpec.optionLabel("support_paper", s)).tag(s["id"].int) }
                                }.pickerStyle(.menu).labelsHidden()
                            }
                        }
                    }
                    Text("Your changes to the test are saved first.").font(Theme.small).foregroundStyle(Theme.dim)
                    if let error { Text(error).font(Theme.small).foregroundStyle(Theme.red) }
                }
                .padding(18)
            }
            .background(Theme.bg)
            .navigationTitle(first ? "Split into variants" : "Add a variant")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Making…" : "Make it") {
                        if kind == .size && sheet == nil { error = "Pick the sample sheet the new variant is on"; return }
                        busy = true; error = nil
                        Task {
                            let t = { (s: String) in s.trimmingCharacters(in: .whitespaces).isEmpty ? nil : s.trimmingCharacters(in: .whitespaces) }
                            if let e = await make(first ? t(labelA) : nil, t(label), sheet) { error = e; busy = false } else { dismiss() }
                        }
                    }.bold().disabled(busy)
                }
            }
            .task {
                guard kind == .size, sheets.isEmpty else { return }
                let used = Set(((try? await store.list("size_test")) ?? []).compactMap { $0["support_paper_id"].int })
                sheets = ((try? await store.list("support_paper")) ?? []).filter { !used.contains($0["id"].int ?? 0) }
            }
        }
        .tint(Theme.red)
        .presentationDetents([.medium, .large])
    }
}

// MARK: Kinds of test made up by the owner (migration 036)

/// A made-up kind's tests. The list is rebuilt whenever the kind's fields change (Fields in the toolbar).
struct CustomTestsView: View {
    let kindId: Int
    @Environment(AppStore.self) private var store
    @State private var editingKind = false

    var body: some View {
        if let k = (store.testKinds ?? []).first(where: { $0["id"].int == kindId }) {
            RowsView(spec: ListSpec.custom(k))
                .id(k["fields"].array.map { "\($0["id"].int ?? 0)\($0["name"].string ?? "")\($0["type"].string ?? "")\($0)" }.joined() + (k["name"].string ?? ""))
                .toolbar {
                    ToolbarItem(placement: .secondaryAction) { Button("Fields", systemImage: "list.bullet.rectangle") { editingKind = true } }
                }
                .sheet(isPresented: $editingKind) { KindEditor(processId: k["process_id"].int ?? 0, kind: k) }
        } else {
            ProgressView().tint(Theme.red).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
                .task { await store.reloadTestKinds() }
        }
    }
}

/// One field of a made-up kind of test, as edited.
private struct FieldDraft: Identifiable {
    let id = UUID()
    var serverId: Int?
    var name = ""
    var type = "number"
    var unit = ""
    var choices = ""          // choice: the words, separated by commas
    var list = "pigment"      // pick: which list
    var lo = 1, hi = 5
    var isResult = false

    init() {}
    init(_ j: JSON) {
        serverId = j["id"].int; name = j["name"].string ?? ""; type = j["type"].string ?? "number"; unit = j["unit"].string ?? ""
        if type == "choice" { choices = j["options"].array.compactMap(\.string).joined(separator: ", ") }
        if type == "pick" { list = j["options"].string ?? "pigment" }
        lo = j["lo"].int ?? 1; hi = j["hi"].int ?? 5; isResult = j["is_result"].flag
    }
    var asJSON: JSON {
        var o: [String: JSON] = ["id": .from(serverId), "name": .string(name.trimmingCharacters(in: .whitespaces)), "type": .string(type),
                                 "is_result": .from(isResult ? 1 : 0)]
        if ["number", "whole"].contains(type) { o["unit"] = .from(unit.isEmpty ? nil : unit) }
        if type == "choice" { o["options"] = .array(choices.split(separator: ",").map { .string($0.trimmingCharacters(in: .whitespaces)) }) }
        if type == "pick" { o["options"] = .string(list) }
        if type == "score" { o["lo"] = .from(lo); o["hi"] = .from(hi) }
        return .object(o)
    }
}

/// Make a new kind of test for a process, or change one's name and fields.
struct KindEditor: View {
    let processId: Int
    let kind: JSON?
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var notes = ""
    @State private var fields: [FieldDraft] = []
    @State private var busy = false
    @State private var error: String?
    @State private var confirmDelete = false
    @State private var started = false

    private static let types: [(String, String)] = [("number", "Number"), ("whole", "Whole number"), ("text", "Text"), ("notes", "Notes"),
        ("choice", "Choice of words"), ("score", "Score"), ("flag", "Yes / no"), ("date", "Date"), ("duration", "Time (90s, 1:30)"), ("pick", "Pick from a list")]
    private static let lists: [(String, String)] = [("chemistry", "Chemistry batches"), ("pigment", "Pigments"), ("carbon_tissue", "Carbon tissue"),
        ("support_paper", "Support papers"), ("paper", "Papers")]
    private var custom: Bool { kind == nil || kind?["kind"].string == "custom" }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name, e.g. Support tests", text: $name)
                    TextField("What it's for (optional)", text: $notes, axis: .vertical).lineLimit(1...3)
                }
                if custom {
                    Section {
                        ForEach($fields) { $f in fieldRow($f) }
                            .onDelete { fields.remove(atOffsets: $0) }
                            .onMove { fields.move(fromOffsets: $0, toOffset: $1) }
                        Button("Add a field", systemImage: "plus") { fields.append(FieldDraft()) }
                    } header: {
                        Text("Fields")
                    } footer: {
                        Text("What each test records. Mark the ones that say how it came out as results: a new variant starts with those empty. Removing a field stops it being asked; values already recorded stay.")
                    }
                    if let kind, kind["id"].int != nil {
                        Section {
                            Button(kind["archived"].flag ? "Show this kind again" : "Hide this kind") { Task { await send(["archived": .from(kind["archived"].flag ? 0 : 1)], close: true) } }
                            if (kind["tests"].int ?? 0) == 0 {
                                Button("Delete this kind", role: .destructive) { confirmDelete = true }
                            }
                        }
                    }
                }
                if let error { Text(error).foregroundStyle(Theme.red) }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle(kind == nil ? "New kind of test" : "Fields")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "Saving…" : "Save") { Task { await save() } }.bold().disabled(busy) }
            }
            .confirmationDialog("Delete this kind of test?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { Task { await remove() } }
            } message: { Text("It has no tests. This can't be undone.") }
            .onAppear {
                guard !started else { return }
                started = true
                name = kind?["name"].string ?? ""; notes = kind?["notes"].string ?? ""
                fields = (kind?["fields"].array ?? []).map(FieldDraft.init)
                if fields.isEmpty && custom { fields = [FieldDraft()] }
            }
        }
        .tint(Theme.red)
    }

    @ViewBuilder private func fieldRow(_ f: Binding<FieldDraft>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Field name, e.g. PVA amount", text: f.name).font(.body.weight(.semibold))
            Picker("Type", selection: f.type) { ForEach(Self.types, id: \.0) { Text($0.1).tag($0.0) } }
            switch f.wrappedValue.type {
            case "number", "whole": TextField("Unit (mL, g, °C), optional", text: f.unit)
            case "choice": TextField("The words, separated by commas", text: f.choices)
            case "pick": Picker("From", selection: f.list) { ForEach(Self.lists, id: \.0) { Text($0.1).tag($0.0) } }
            case "score":
                Stepper("Lowest \(f.wrappedValue.lo)", value: f.lo, in: 0...9)
                Stepper("Highest \(f.wrappedValue.hi)", value: f.hi, in: 1...10)
            default: EmptyView()
            }
            Toggle("A result (how it came out)", isOn: f.isResult)
        }
        .padding(.vertical, 4)
    }

    private func save() async {
        let named = fields.filter { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty }
        if let bad = named.first(where: { $0.type == "score" && $0.lo >= $0.hi }) { error = "\(bad.name): the lowest score must be below the highest"; return }
        var body: [String: JSON] = ["name": .string(name.trimmingCharacters(in: .whitespaces)), "notes": .from(notes.isEmpty ? nil : notes)]
        if custom { body["fields"] = .array(named.map(\.asJSON)) }
        if kind == nil { body["process_id"] = .from(processId) }
        await send(body, close: true)
    }
    private func send(_ body: [String: JSON], close: Bool) async {
        busy = true; error = nil; defer { busy = false }
        do {
            if let id = kind?["id"].int {
                _ = try await store.server.request("darkroom-api.php?res=test_kind&id=\(id)", method: "PATCH", body: .object(body))
            } else {
                _ = try await store.server.request("darkroom-api.php?res=test_kind", method: "POST", body: .object(body))
            }
            await store.reloadTestKinds()
            if close { dismiss() }
        } catch let e as ServerError { error = e.retry ? "Can't reach knotwork.ca — try again with a connection" : e.message }
        catch { self.error = error.localizedDescription }
    }
    private func remove() async {
        guard let id = kind?["id"].int else { return }
        do {
            _ = try await store.server.request("darkroom-api.php?res=test_kind&id=\(id)", method: "DELETE")
            await store.reloadTestKinds(); dismiss()
        } catch let e as ServerError { error = e.message } catch { self.error = error.localizedDescription }
    }
}
