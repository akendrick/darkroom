import SwiftUI

/// The lists behind the walk-through, edited on the phone: chemistry,
/// tissues, papers, negatives and the names they're sorted by. Each one is
/// described by its fields, the same ones darkroom-api.php keeps, and read
/// and saved straight to the server (so these need a connection).
struct ListSpec: Identifiable, Hashable {
    enum Kind: Hashable { case text, notes, number, whole, date, dateTime, flag, pick(String) }
    struct Field: Hashable { let key: String, label: String, kind: Kind }

    let id: String              // the API resource
    let title: String
    let fields: [Field]
    let required: [String]
    let archives: Bool          // removing hides it (prints keep it); else no remove here
    let rowTitle: (JSON) -> String
    let rowSub: (JSON) -> String?
    /// Sent with every new row (a material's kind).
    var fixed: [String: JSON] = [:]
    /// The list's own query, when it's part of a resource ("material&kind_id=3").
    var listRes: String? = nil

    /// The API resource: the id up to any ":" ("material:3" → material).
    var resource: String { String(id.split(separator: ":").first ?? "") }

    static func == (a: ListSpec, b: ListSpec) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let all: [ListSpec] = [
        ListSpec(id: "chemistry", title: "Chemistry batches", fields: [
            .init(key: "label", label: "Label", kind: .text),
            .init(key: "type_id", label: "Type", kind: .pick("chemistry_types")),
            .init(key: "date_created", label: "Made", kind: .date),
            .init(key: "percent_solution", label: "Strength %", kind: .number),
            .init(key: "volume_ml", label: "Volume ml", kind: .number),
            .init(key: "mixed_at", label: "Mixed at", kind: .dateTime),
            .init(key: "use_within_min", label: "Use within (min)", kind: .whole),
            .init(key: "notes", label: "Notes", kind: .notes),
        ], required: ["date_created"], archives: true,
           rowTitle: { chemLabel($0) }, rowSub: { [$0["date_created"].string, $0["sheets_used"].int.map { "\($0) used" }].compactMap { $0 }.joined(separator: " · ") }),
        ListSpec(id: "carbon_tissue", title: "Carbon tissue", fields: [
            .init(key: "title_id", label: "Name", kind: .text),
            .init(key: "date_poured", label: "Poured", kind: .date),
            .init(key: "size", label: "Size", kind: .text),
            .init(key: "chemistry_id", label: "Glop batch", kind: .pick("chemistry")),
            .init(key: "amount_poured", label: "Amount poured", kind: .text),
            .init(key: "notes", label: "Notes", kind: .notes),
        ], required: ["date_poured"], archives: true,
           rowTitle: { Material(what: .carbon_tissue, row: $0).label }, rowSub: { Material(what: .carbon_tissue, row: $0).sub }),
        ListSpec(id: "support_paper", title: "Support papers", fields: [
            .init(key: "mark", label: "Mark", kind: .text),
            .init(key: "paper_id", label: "Paper", kind: .pick("paper")),
            .init(key: "treatment_chemistry_id", label: "Treated with", kind: .pick("chemistry")),
            .init(key: "notes", label: "Notes", kind: .notes),
        ], required: ["paper_id"], archives: true,
           rowTitle: { Material(what: .support_paper, row: $0).label }, rowSub: { $0["treatment_label"].string }),
        ListSpec(id: "paper", title: "Papers", fields: [
            .init(key: "manufacturer", label: "Maker", kind: .text),
            .init(key: "label", label: "Name", kind: .text),
            .init(key: "weight", label: "Weight gsm", kind: .number),
            .init(key: "hot_press", label: "Hot press", kind: .flag),
            .init(key: "notes", label: "Notes", kind: .notes),
        ], required: [], archives: true,
           rowTitle: { Paper($0).name }, rowSub: { $0["weight"].double.map { "\($0.formatted()) gsm" } }),
        ListSpec(id: "negative", title: "Negatives", fields: [
            .init(key: "title_id", label: "Name", kind: .text),
            .init(key: "date_created", label: "Made", kind: .date),
            .init(key: "type_id", label: "Type", kind: .pick("negative_types")),
            .init(key: "settings_notes", label: "Settings", kind: .notes),
        ], required: ["date_created"], archives: true,
           rowTitle: { Material(what: .negative, row: $0).label }, rowSub: { $0["type_name"].string }),
        ListSpec(id: "pigment", title: "Pigments", fields: [
            .init(key: "name", label: "Name", kind: .text),
            .init(key: "short_code", label: "Short code for IDs (Ind.I)", kind: .text),
            .init(key: "maker", label: "Maker", kind: .text),
            .init(key: "notes", label: "Notes", kind: .notes),
        ], required: ["name"], archives: true,
           rowTitle: { $0["name"].string ?? "Pigment" },
           rowSub: { j in [Pigment(j).short, j["maker"].string].compactMap { $0 }.joined(separator: " · ") }),
        ListSpec(id: "chemistry_types", title: "Chemistry types", fields: [.init(key: "name", label: "Name", kind: .text)],
                 required: ["name"], archives: false, rowTitle: { $0["name"].string ?? "" }, rowSub: { _ in nil }),
        ListSpec(id: "negative_types", title: "Negative types", fields: [.init(key: "name", label: "Name", kind: .text)],
                 required: ["name"], archives: false, rowTitle: { $0["name"].string ?? "" }, rowSub: { _ in nil }),
        ListSpec(id: "photo_types", title: "Kinds of print", fields: [
            .init(key: "name", label: "Name", kind: .text),
            .init(key: "has_layers", label: "Prints can have layers", kind: .flag),
        ], required: ["name"], archives: false, rowTitle: { $0["name"].string ?? "" }, rowSub: { $0["has_layers"].flag ? "layers" : nil }),
        ListSpec(id: "step_kind", title: "Step kinds", fields: [.init(key: "name", label: "Name", kind: .text)],
                 required: ["name"], archives: true, rowTitle: { $0["name"].string ?? "" }, rowSub: { $0["built_in"].flag ? "built in" : nil }),
    ]

    static func of(_ id: String) -> ListSpec { all.first { $0.id == id }! }

    /// The owner's own kinds of material ("Photo Paper"): add one to get a new list.
    static let materialKinds = ListSpec(id: "material_kind", title: "Kinds of material",
        fields: [.init(key: "name", label: "Name", kind: .text)], required: ["name"], archives: true,
        rowTitle: { $0["name"].string ?? "" }, rowSub: { _ in nil })

    /// One kind's materials, each named and edited to be whatever is in use.
    static func materials(_ k: MaterialKind) -> ListSpec {
        ListSpec(id: "material:\(k.id)", title: k.name, fields: [
            .init(key: "label", label: "Name", kind: .text),
            .init(key: "maker", label: "Maker", kind: .text),
            .init(key: "notes", label: "Notes", kind: .notes),
        ], required: ["label"], archives: true,
           rowTitle: { $0["label"].string ?? "" },
           rowSub: { j in [j["maker"].string, j["notes"].string].compactMap { $0 }.joined(separator: " · ") },
           fixed: ["kind_id": .from(k.id)], listRes: "material&kind_id=\(k.id)")
    }

    static func chemLabel(_ j: JSON) -> String {
        j["label"].string ?? [j["type_name"].string ?? "Batch", j["date_created"].string].compactMap { $0 }.joined(separator: " ")
    }
    /// How a row of a pick list is named.
    static func optionLabel(_ source: String, _ j: JSON) -> String {
        switch source {
        case "chemistry": chemLabel(j)
        case "paper": Paper(j).name
        default: j["name"].string ?? "#\(j["id"].int ?? 0)"
        }
    }
}

extension AppStore {
    func list(_ res: String) async throws -> [JSON] { try await server.request("darkroom-api.php?res=\(res)").array }
    @discardableResult
    func saveRow(_ res: String, id: Int?, _ body: JSON) async throws -> JSON {
        let r = try await server.request("darkroom-api.php?res=\(res)" + (id.map { "&id=\($0)" } ?? ""),
                                         method: id == nil ? "POST" : "PATCH", body: body)
        await refresh()     // the walk-through's lists come from sync
        return r
    }
}

// MARK: Screens

struct ListsView: View {
    @Environment(AppStore.self) private var store
    var body: some View {
        List((store.snapshot?.materialKinds ?? []).map(ListSpec.materials) + ListSpec.all + [ListSpec.materialKinds]) { spec in
            NavigationLink(spec.title) { RowsView(spec: spec) }.font(Theme.body.weight(.bold))
                .listRowBackground(Theme.box).foregroundStyle(.black)
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Lists")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct RowRef: Hashable { let res: String; let id: Int? }

/// One list's rows.
struct RowsView: View {
    @Environment(AppStore.self) private var store
    let spec: ListSpec
    @State private var rows: [JSON] = []
    @State private var error: String?
    @State private var search = ""
    @State private var editing: JSON?
    @State private var adding = false

    private var shown: [JSON] {
        guard !search.isEmpty else { return rows }
        return rows.filter { (spec.rowTitle($0) + " " + (spec.rowSub($0) ?? "")).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if let error { Text(error).font(Theme.small).listRowBackground(Theme.bg) }
            ForEach(shown, id: \.self["id"].int) { r in
                Button { editing = r } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spec.rowTitle(r)).font(Theme.body.weight(.bold))
                        if let s = spec.rowSub(r), !s.isEmpty { Text(s).font(Theme.small).opacity(0.7) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .listRowBackground(Theme.box).foregroundStyle(.black)
            }
        }
        .searchable(text: $search)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(spec.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .primaryAction) { Button("Add", systemImage: "plus") { adding = true } } }
        .homeBulb()
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: Binding(get: { editing.map(Wrapped.init) }, set: { editing = $0?.row })) { w in
            RowForm(spec: spec, row: w.row) { await load() }
        }
        .sheet(isPresented: $adding) { RowForm(spec: spec, row: nil) { await load() } }
    }

    private func load() async {
        do { rows = try await store.list(spec.listRes ?? spec.resource); error = nil }
        catch let e as ServerError { error = e.retry ? "Can't reach knotwork.ca — lists need a connection" : e.message }
        catch { self.error = error.localizedDescription }
    }
}

private struct Wrapped: Identifiable { let row: JSON; var id: Int { row["id"].int ?? 0 } }

/// Add or change one row.
struct RowForm: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let spec: ListSpec
    let row: JSON?
    let saved: () async -> Void
    @State private var values: [String: JSON] = [:]
    @State private var options: [String: [JSON]] = [:]
    @State private var busy = false
    @State private var error: String?
    @State private var confirmArchive = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(spec.fields, id: \.key) { f in field(f) }
                    if let error { Text(error).font(Theme.small).foregroundStyle(Theme.red) }
                    if row != nil && spec.archives {
                        Button("Remove from lists", role: .destructive) { confirmArchive = true }
                            .font(Theme.body.weight(.bold)).padding(.top, 10)
                    }
                }
                .padding(18)
            }
            .background(Theme.bg)
            .navigationTitle(row == nil ? "New" : spec.rowTitle(row!))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "Saving…" : "Save") { save() }.bold().disabled(busy) }
            }
            .confirmationDialog("Remove from lists?", isPresented: $confirmArchive, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { send(.object(["archived": .from(1)])) }
            } message: { Text("It stops being offered. Prints that used it keep it.") }
            .task { await setUp() }
        }
        .tint(Theme.red)
    }

    @ViewBuilder private func field(_ f: ListSpec.Field) -> some View {
        switch f.kind {
        case .text, .notes:
            Field(label: f.label) {
                TextField("", text: text(f.key), axis: f.kind == .notes ? .vertical : .horizontal)
                    .lineLimit(f.kind == .notes ? 2...6 : 1...1)
            }
        case .number, .whole:
            Field(label: f.label) {
                NumberField(value: Binding(get: { values[f.key]?.double }, set: { values[f.key] = .from($0) }), whole: f.kind == .whole)
            }
        case .flag:
            Toggle(f.label, isOn: Binding(get: { values[f.key]?.flag ?? false }, set: { values[f.key] = .from($0 ? 1 : 0) }))
                .font(Theme.body.weight(.semibold)).foregroundStyle(Theme.red).tint(Theme.red)
        case .date, .dateTime:
            let time = f.kind == .dateTime
            Field(label: f.label) {
                HStack {
                    if let d = values[f.key]?.string.flatMap({ parse($0, time) }) {
                        DatePicker("", selection: Binding(get: { d }, set: { values[f.key] = .string(fmt($0, time)) }),
                                   displayedComponents: time ? [.date, .hourAndMinute] : [.date]).labelsHidden()
                        Spacer()
                        Button("Clear") { values[f.key] = .null }.font(Theme.small)
                    } else {
                        Button("Set") { values[f.key] = .string(fmt(.now, time)) }.font(Theme.body.weight(.bold))
                        Spacer()
                    }
                }
            }
        case .pick(let source):
            Field(label: f.label) {
                Picker(f.label, selection: Binding(get: { values[f.key]?.int }, set: { values[f.key] = .from($0) })) {
                    Text("—").tag(Int?.none)
                    ForEach(options[source] ?? [], id: \.self["id"].int) { o in
                        Text(ListSpec.optionLabel(source, o)).tag(o["id"].int)
                    }
                }.pickerStyle(.menu).labelsHidden()
            }
        }
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { values[key]?.string ?? "" }, set: { values[key] = $0.isEmpty ? .null : .string($0) })
    }

    private func setUp() async {
        if values.isEmpty {
            for f in spec.fields { values[f.key] = row?[f.key] ?? .null }
            if row == nil {     // a new one is made today
                for f in spec.fields where f.kind == .date && spec.required.contains(f.key) { values[f.key] = .string(fmt(.now, false)) }
            }
        }
        for f in spec.fields {
            if case .pick(let s) = f.kind, options[s] == nil { options[s] = (try? await store.list(s)) ?? [] }
        }
    }

    private func save() {
        if let miss = spec.required.first(where: { values[$0]?.string == nil }) {
            error = "\(spec.fields.first { $0.key == miss }?.label ?? miss) is needed"; return
        }
        send(.object(values.merging(spec.fixed) { _, f in f }))
    }

    private func send(_ body: JSON) {
        busy = true; error = nil
        Task {
            do { try await store.saveRow(spec.resource, id: row?["id"].int, body); await saved(); dismiss() }
            catch let e as ServerError { error = e.retry ? "Can't reach knotwork.ca — try again with a connection" : e.message }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func parse(_ s: String, _ time: Bool) -> Date? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = time ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd"
        return f.date(from: time ? s : String(s.prefix(10)))
    }
    private func fmt(_ d: Date, _ time: Bool) -> String { time ? Clock.stamp(d) : Clock.today(d) }
}
