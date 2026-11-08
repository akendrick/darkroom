import SwiftUI

/// One step being edited: every field darkroom-api.php keeps for a step.
/// Kept by value; the whole list is sent back at once, as the web page does.
struct StepEdit: Identifiable, Equatable {
    var id = UUID()             // for the list; serverId is the step's own
    var serverId: Int?
    var name = "New step"
    var kind = "bath"
    var selectWhat: String?     // kept as the server's text: it may name things this app doesn't list yet
    var materialKindId: Int?    // or one of the owner's own kinds of material
    var timed = true            // off: no timer, "do this, then Next"
    var perLayer = false
    var asksTemp = false
    var tray: Int?
    var chemistryTypeId: Int?
    var defaultSeconds: Int?
    var minSeconds: Int?
    var maxSeconds: Int?
    var defaultTemp: Double?
    var optional = false
    var recordsPh = false
    var lightsOkAfter = false
    var notes = ""
    var sameAs: UUID?           // an earlier step in this list: "same batch as"
    var timesUsed = 0
    var defaultAmount: Double?  // add steps: the recipe's amount
    var unit: String?
    var pigmentId: Int?         // pigment steps (selectWhat "pigment"): the usual pigment
    var bathTypeId: Int?        // bath steps: Fog, Develop…
    var defaultHumidity: Double?
    var instructionId: Int?     // the overview step it belongs to, as the server has it
    var block: UUID?            // while editing a process: that overview step (nil: before the first)

    init() {}

    init(_ j: JSON) {
        serverId = j["id"].int; name = j["name"].string ?? "Step"; kind = j["kind"].string ?? "bath"
        selectWhat = j["select_what"].string
        materialKindId = j["material_kind_id"].int; timed = j["timed"] == .null ? true : j["timed"].flag
        perLayer = j["per_layer"].flag; asksTemp = j["asks_temp"].flag; tray = j["tray"].int
        chemistryTypeId = j["chemistry_type_id"].int; defaultSeconds = j["default_seconds"].int
        minSeconds = j["min_seconds"].int; maxSeconds = j["max_seconds"].int; defaultTemp = j["default_temp"].double
        optional = j["optional"].flag; recordsPh = j["records_ph"].flag; lightsOkAfter = j["lights_ok_after"].flag
        notes = j["notes"].string ?? ""; timesUsed = j["times_used"].int ?? 0
        defaultAmount = j["default_amount"].double; unit = j["unit"].string; pigmentId = j["pigment_id"].int
        bathTypeId = j["bath_type_id"].int; defaultHumidity = j["default_humidity"].double; instructionId = j["instruction_id"].int
        if kind == "do", timed, materialKindId != nil || selectWhat != nil { kind = "select" }
    }

    /// A list with a timer is kept as a To-do that also chooses: only
    /// those pages can show both.
    private var storedKind: String { isSelect && timed && selectWhat != "chemistry" ? "do" : kind }

    var isSelect: Bool { kind == "select" }
    var isAdd: Bool { kind == "add" }
    var isPigment: Bool { isAdd && selectWhat == "pigment" }

    func payload(sameAsIndex: Int?) -> JSON {
        .object([
            "id": .from(serverId), "name": .string(name), "kind": .string(storedKind), "bath_type_id": .from(kind == "bath" ? bathTypeId : nil),
            "default_humidity": .from(kind == "dry" ? defaultHumidity : nil), "timed": .from(timed ? 1 : 0),
            "select_what": .from(materialKindId == nil ? selectWhat : nil),     // any step can also choose a material
            "material_kind_id": .from(materialKindId),
            "per_layer": .from(perLayer ? 1 : 0), "asks_temp": .from(asksTemp ? 1 : 0), "tray": .from(tray),
            // A choose step keeps a type only when it chooses a batch (the glop).
            "chemistry_type_id": .from(isSelect && selectWhat != "chemistry" ? nil : chemistryTypeId),
            "default_amount": .from(isAdd ? defaultAmount : nil), "unit": .from(isAdd ? unit.flatMap { $0.isEmpty ? nil : $0 } : nil),
            "pigment_id": .from(isPigment ? pigmentId : nil),
            "default_seconds": .from(defaultSeconds), "min_seconds": .from(minSeconds), "max_seconds": .from(maxSeconds),
            "default_temp": .from(defaultTemp), "optional": .from(optional ? 1 : 0), "records_ph": .from(recordsPh ? 1 : 0),
            "lights_ok_after": .from(lightsOkAfter ? 1 : 0), "notes": .from(notes.isEmpty ? nil : notes),
            "same_as_index": .from(sameAsIndex),
        ])
    }
}

extension StepEdit {
    /// A walk's live steps from the sync feed.
    static func list(_ preset: JSON) -> [StepEdit] {
        let raw = preset["steps"].array.filter { !$0["archived"].flag }
        var s = raw.map(StepEdit.init)
        // "Same batch as" points at a server id; here it points at the row.
        for (i, r) in raw.enumerated() {
            if let other = r["same_as_step_id"].int { s[i].sameAs = s.first { $0.serverId == other }?.id }
        }
        return s
    }
}

extension Snapshot {
    /// One line on a step, for lists of steps.
    func summary(_ s: StepEdit) -> String {
        if s.isSelect {
            if let k = s.materialKindId { return "Choose " + (kindName(k)?.lowercased() ?? "material") }
            if s.selectWhat == "chemistry" { return "Choose " + (chemistryTypeName(s.chemistryTypeId)?.lowercased() ?? "a batch") }
            return "Choose " + (s.selectWhat.map { SelectWhat(rawValue: $0)?.noun ?? $0.replacingOccurrences(of: "_", with: " ") } ?? "…")
        }
        if s.isAdd {
            let amt = s.defaultAmount.map { "\(Amount.format($0)) \(s.unit ?? (s.isPigment ? "g" : ""))" }
            let pig = s.isPigment ? (pigment(s.pigmentId)?.name ?? "pigment") : nil
            return [[amt, pig].compactMap { $0 }.joined(separator: " "), s.optional ? "optional" : nil].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        }
        let bath = s.kind == "bath" ? bathTypes.first { $0.id == s.bathTypeId }?.name : nil
        let kind = bath ?? stepKinds.first { $0["code"].string == s.kind }?["name"].string ?? s.kind
        return [kind, s.timed ? s.defaultSeconds.map(Duration.format) : nil, s.tray.map { "tray \($0)" },
                s.defaultTemp.map { "\($0.formatted()) °C" }, s.timed ? nil : "no timer", s.optional ? "optional" : nil, s.perLayer ? "per layer" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

/// A preset (one walk-through) being edited.
@MainActor @Observable
final class PresetEdit {
    let id: Int
    var name: String
    var isDefault: Bool
    var steps: [StepEdit]
    private let original: [StepEdit]
    private let originalName: String, originalDefault: Bool
    var saving = false
    var error: String?

    init(_ j: JSON) {
        let n = j["name"].string ?? "", d = j["is_default"].flag
        id = j["id"].int ?? 0
        name = n; isDefault = d; originalName = n; originalDefault = d
        let s = StepEdit.list(j)
        steps = s; original = s
    }

    var changed: Bool { steps != original || name != originalName || isDefault != originalDefault }

    func payload() -> JSON {
        let list = steps.map { st -> JSON in
            let idx = st.sameAs.flatMap { ref in steps.firstIndex { $0.id == ref } }
            return st.payload(sameAsIndex: idx)
        }
        return .object(["name": .string(name), "is_default": .from(isDefault ? 1 : 0), "steps": .array(list)])
    }
}

extension AppStore {
    /// The preset as the server sent it, with every step field.
    func rawPreset(_ id: Int) -> JSON? {
        snapshot?.raw["presets"].array.first { $0["id"].int == id }
    }

    /// Saves a walk-through's design. Needs a connection: unlike prints,
    /// these aren't queued, so two phones can't quietly overwrite each other.
    func savePreset(_ p: PresetEdit) async throws {
        _ = try await server.request("darkroom-api.php?res=process_preset&id=\(p.id)", method: "PATCH", body: p.payload())
        await refresh()
    }
}

// MARK: Screens

/// Every walk-through, by process. Opened from the menus.
struct EditWalksView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    /// Opens straight on this one (the walk-through in use), if set.
    var startOn: Int?
    /// Shown inside another screen's navigation (Settings) rather than as its own sheet.
    var embedded = false
    @State private var path = NavigationPath()

    var body: some View {
        if embedded { list }
        else {
            NavigationStack(path: $path) {
                list
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
                    .onAppear { if let s = startOn, path.isEmpty, store.rawPreset(s) != nil { path.append(s) } }
            }
            .tint(Theme.red)
            .foregroundStyle(Theme.red)
        }
    }

    private var list: some View {
            ScrollView {
                WalkTreeView(tree: WalkTree.build(store.snapshot), openOn: startOn) { p in
                    NavigationLink(value: p.id) {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name + (p.isDefault ? "  ★" : ""))
                                Text("\(p.steps.count) steps").font(Theme.small).opacity(0.7)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                        }
                    }
                    .buttonStyle(TreeRowStyle(fill: Theme.walkBar, text: .black))
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle("Walk-throughs")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Int.self) { id in
                PresetEditView(presetId: id)
            }
    }
}

/// Holds one walk-through's edit for as long as its screen is open.
struct PresetEditView: View {
    @Environment(AppStore.self) private var store
    let presetId: Int
    @State private var edit: PresetEdit?

    var body: some View {
        Group {
            if let edit { PresetStepsView(edit: edit) }
            else { Text("This walk-through is no longer on the server.").font(Theme.small) }
        }
        .onAppear { if edit == nil, let raw = store.rawPreset(presetId) { edit = PresetEdit(raw) } }
    }
}

/// A walk-through's steps: reorder, add, remove, and open one to change it.
struct PresetStepsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable var edit: PresetEdit
    @State private var confirmLeave = false

    var body: some View {
        List {
            Section {
                TextField("Name", text: $edit.name).font(Theme.body.weight(.bold))
                    .listRowBackground(Theme.box).foregroundStyle(.black)
                Toggle("Default for this process", isOn: $edit.isDefault).font(Theme.small)
                    .listRowBackground(Theme.bg)
            }
            Section {
                ForEach(edit.steps) { s in
                    NavigationLink(value: s.id) {
                        let i = (edit.steps.firstIndex { $0.id == s.id } ?? 0) + 1
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i)").font(Theme.display(22)).frame(width: 28, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.name).font(Theme.body.weight(.bold))
                                Text(summary(s)).font(Theme.small).opacity(0.7)
                            }
                        }
                    }
                    .listRowBackground(Theme.box).foregroundStyle(.black)
                }
                .onMove { edit.steps.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { edit.steps.remove(atOffsets: $0) }
                Button("+ Add step") { edit.steps.append(StepEdit()) }
                    .font(Theme.body.weight(.bold)).listRowBackground(Theme.bg)
            } header: {
                Text("STEPS · hold and drag to reorder · swipe left to remove").font(Theme.label).foregroundStyle(Theme.bright)
            } footer: {
                Text("A step used by earlier prints is kept with them when removed here.").font(Theme.small)
            }
            if let e = edit.error {
                Text(e).font(Theme.small).listRowBackground(Theme.bg)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(edit.name)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(edit.changed)
        .navigationDestination(for: UUID.self) { [edit] id in StepEditView(edit: edit, stepId: id) }
        .toolbar {
            if edit.changed {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirmLeave = true } }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(edit.saving ? "Saving…" : "Save") { save() }.disabled(!edit.changed || edit.saving).bold()
            }
        }
        .confirmationDialog("Leave without saving?", isPresented: $confirmLeave, titleVisibility: .visible) {
            Button("Discard changes", role: .destructive) { dismiss() }
        }
    }

    private func summary(_ s: StepEdit) -> String { store.snapshot?.summary(s) ?? "" }

    private func save() {
        if let blank = edit.steps.firstIndex(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) {
            edit.error = "Step \(blank + 1) needs a name"; return
        }
        edit.saving = true; edit.error = nil
        Task {
            do { try await store.savePreset(edit); dismiss() }
            catch let e as ServerError { edit.error = e.retry ? "Can't reach knotwork.ca — try again with a connection" : e.message }
            catch { edit.error = error.localizedDescription }
            edit.saving = false
        }
    }
}

/// Finds the step in the walk-through being edited, which owns it.
struct StepEditView: View {
    @Bindable var edit: PresetEdit
    let stepId: UUID
    var body: some View {
        if let i = edit.steps.firstIndex(where: { $0.id == stepId }) {
            StepForm(step: $edit.steps[i], number: i + 1, earlier: edit.steps.prefix(i).filter { !$0.isSelect })
        }
    }
}

/// The Step Selection: the eight types and the kind stored for each.
private enum StepType: String, CaseIterable, Identifiable {
    case exposure, timer, todo, important, add, select, bath, dry
    var id: String { rawValue }
    var label: String {
        switch self {
        case .exposure: "EXPOSURE"; case .timer: "TIMER"; case .todo: "TO-DO"; case .important: "IMPORTANT"
        case .add: "ADD + MEASURE"; case .select: "SELECT MATERIAL"; case .bath: "BATH"; case .dry: "DRY"
        }
    }
    var kind: String {
        switch self {
        case .todo: "do"
        default: rawValue
        }
    }
    init(kind: String) {
        switch kind {
        case "exposure", "light": self = .exposure
        case "timer", "wait": self = .timer
        case "add": self = .add
        case "select": self = .select
        case "bath", "rinse", "chemical_fog": self = .bath
        case "dry": self = .dry
        case "important": self = .important
        default: self = .todo
        }
    }
}

/// One step's settings: number and title, the type, then what that type needs.
struct StepForm: View {
    @Environment(AppStore.self) private var store
    @Binding var step: StepEdit
    let number: Int
    let earlier: [StepEdit]

    private var type: StepType { StepType(kind: step.kind) }
    /// A batch list can't share a page with a timer.
    private var noTimer: Bool { step.isSelect && step.selectWhat == "chemistry" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .bottom, spacing: 10) {
                    Text("\(number).").font(Theme.display(40)).foregroundStyle(Theme.red)
                    Field(label: "Title") { TextField("", text: $step.name) }
                }
                Text("STEP SELECTION").font(Theme.label.weight(.bold)).tracking(1.5).foregroundStyle(Theme.bright)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
                    ForEach(StepType.allCases) { t in
                        Button { pick(t) } label: {
                            Text(t.label).font(Theme.label.weight(.bold)).multilineTextAlignment(.center)
                                .lineLimit(2).minimumScaleFactor(0.6)
                                .foregroundStyle(type == t ? Theme.onRed : .black)
                                .frame(maxWidth: .infinity, minHeight: 54).padding(.horizontal, 2)
                                .background(type == t ? Theme.red : Theme.box, in: .rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if noTimer {
                    Text("A step that chooses a batch can't also have a timer.").font(Theme.small).foregroundStyle(Theme.dim)
                } else {
                    Toggle("Timer", isOn: $step.timed).font(Theme.body.weight(.semibold)).tint(Theme.red)
                }
                if step.timed && !noTimer {
                    OptionalTime(label: "Default time", none: "None — the timer counts up", seconds: $step.defaultSeconds)
                    HStack(alignment: .top, spacing: 10) {
                        OptionalTime(label: "Shortest", none: "No limit", seconds: $step.minSeconds, compact: true)
                        OptionalTime(label: "Longest", none: "No limit", seconds: $step.maxSeconds, compact: true)
                    }
                }
                switch type {
                case .exposure:
                    flag("Light re-exposure (no negative)", Binding(get: { step.kind == "light" }, set: { step.kind = $0 ? "light" : "exposure" }))
                case .bath: bathFields
                case .dry:
                    Field(label: "Room humidity %") { NumberField(value: $step.defaultHumidity) }
                case .add: addFields
                case .select: chooser(label: "Choose")
                case .timer, .todo, .important: EmptyView()
                }
                VStack(spacing: 0) {
                    flag("Optional (can be skipped)", $step.optional)
                    flag("Once per layer", $step.perLayer)
                    flag("Room lights can go on after", $step.lightsOkAfter)
                }
                Field(label: "Directions shown on the step") {
                    TextField("", text: $step.notes, axis: .vertical).lineLimit(5...14)
                }
                if step.timesUsed > 0 {
                    Text("Used by \(step.timesUsed) print\(step.timesUsed == 1 ? "" : "s") so far. Changes apply from the next one.")
                        .font(Theme.small).foregroundStyle(Theme.dim)
                }
            }
            .padding(18)
        }
        .background(Theme.bg)
        .navigationTitle(step.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func pick(_ t: StepType) {
        step.kind = t.kind
        if t == .timer { step.timed = true }
        if t == .todo || t == .important || t == .select { step.timed = false }
        if t == .bath, step.bathTypeId == nil { step.bathTypeId = store.snapshot?.bathTypes.first?.id }
    }

    @ViewBuilder private var bathFields: some View {
        Field(label: "Bath") {
            Picker("Bath", selection: $step.bathTypeId) {
                ForEach(store.snapshot?.bathTypes ?? [], id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }.pickerStyle(.menu).labelsHidden()
        }
        HStack(spacing: 10) {
            Field(label: "Temp °C") { NumberField(value: $step.defaultTemp) }
            Field(label: "Tray") { NumberField(value: Binding(get: { step.tray.map(Double.init) }, set: { step.tray = $0.map { Int($0) } }), whole: true) }
        }
        VStack(spacing: 0) {
            flag("Ask the temperature", $step.asksTemp)
            flag("Record pH", $step.recordsPh)
        }
        chemistry
        chooser(label: "Also choose")
    }

    @ViewBuilder private var addFields: some View {
        HStack(spacing: 10) {
            Field(label: "Amount") { NumberField(value: $step.defaultAmount) }
            Field(label: "Unit") { TextField("g, mL…", text: Binding(get: { step.unit ?? "" }, set: { step.unit = String($0.prefix(12)) })) }
        }
        chemistry
        Field(label: "Pigment") {
            Picker("Pigment", selection: pigmentChoice) {
                Text("— not a pigment —").tag(String?.none)
                Text("Any pigment (choose on the day)").tag(Optional("any"))
                ForEach(store.snapshot?.pigments ?? []) { Text($0.name).tag(Optional(String($0.id))) }
            }.pickerStyle(.menu).labelsHidden()
        }
        if !step.isPigment { chooser(label: "Choose") }
    }

    /// A chemistry type: the walk then lists those batches, with + New.
    @ViewBuilder private var chemistry: some View {
        Field(label: "Chemistry") {
            Picker("Chemistry", selection: $step.chemistryTypeId) {
                Text("—").tag(Int?.none)
                ForEach(chemTypes, id: \.id) { Text($0.name).tag(Optional($0.id)) }
            }.pickerStyle(.menu).labelsHidden()
        }
        if !earlier.isEmpty {
            Field(label: "Same batch as") {
                Picker("Same batch as", selection: $step.sameAs) {
                    Text("—").tag(UUID?.none)
                    ForEach(earlier) { Text($0.name).tag(Optional($0.id)) }
                }.pickerStyle(.menu).labelsHidden()
            }
        }
    }

    /// The built-in lists, the batches, then the owner's own kinds ("mk:3").
    @ViewBuilder private func chooser(label: String) -> some View {
        Field(label: label) {
            Picker(label, selection: choice) {
                Text("—").tag(String?.none)
                ForEach(SelectWhat.allCases, id: \.self) { Text($0.noun.capitalized).tag(Optional($0.rawValue)) }
                if let w = step.selectWhat, SelectWhat(rawValue: w) == nil, w != "chemistry", w != "pigment", step.materialKindId == nil {
                    Text(w.replacingOccurrences(of: "_", with: " ").capitalized).tag(Optional(w))
                }
                if step.isSelect { Text("Chemistry batch").tag(Optional("chemistry")) }
                ForEach(store.snapshot?.materialKinds ?? []) { Text($0.name).tag(Optional("mk:\($0.id)")) }
            }.pickerStyle(.menu).labelsHidden()
        }
        if step.isSelect && step.selectWhat == "chemistry" {
            Field(label: "Batch type") {
                Picker("Batch type", selection: $step.chemistryTypeId) {
                    Text("Any").tag(Int?.none)
                    ForEach(chemTypes, id: \.id) { Text($0.name).tag(Optional($0.id)) }
                }.pickerStyle(.menu).labelsHidden()
            }
        }
    }

    /// "any" or a pigment id: the step lists pigments; nil: a plain amount.
    private var pigmentChoice: Binding<String?> {
        Binding(get: { step.isPigment ? (step.pigmentId.map(String.init) ?? "any") : nil },
                set: { v in step.selectWhat = v == nil ? nil : "pigment"; step.pigmentId = v.flatMap { Int($0) } })
    }

    private var choice: Binding<String?> {
        Binding(get: { step.materialKindId.map { "mk:\($0)" } ?? step.selectWhat },
                set: { v in
                    if let v, v.hasPrefix("mk:") { step.materialKindId = Int(v.dropFirst(3)); step.selectWhat = nil }
                    else {
                        step.materialKindId = nil; step.selectWhat = v
                        if v == "chemistry" { step.timed = false }
                    }
                })
    }

    private var chemTypes: [(id: Int, name: String)] {
        (store.snapshot?.raw["chemistry_types"].array ?? []).compactMap { j in
            j["id"].int.map { (id: $0, name: j["name"].string ?? "#\($0)") }
        }
    }

    private func flag(_ label: String, _ on: Binding<Bool>) -> some View {
        Toggle(label, isOn: on).font(Theme.body.weight(.semibold)).tint(Theme.red)
            .padding(.vertical, 8)
    }
}

/// A time that may be left unset: a switch, then the wheels.
struct OptionalTime: View {
    let label: String
    let none: String
    @Binding var seconds: Int?
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label.uppercased()).font(Theme.label.weight(.bold)).tracking(1.5).foregroundStyle(Theme.bright)
                Spacer()
                Toggle(label, isOn: Binding(get: { seconds != nil }, set: { seconds = $0 ? (seconds ?? 60) : nil }))
                    .labelsHidden().tint(Theme.red)
            }
            if let s = seconds {
                if compact {
                    // Two side by side: minutes and seconds only.
                    HStack(spacing: 0) {
                        wheel(s / 60, 0...240, "m") { seconds = $0 * 60 + s % 60 }
                        wheel(s % 60, 0...59, "s") { seconds = s / 60 * 60 + $0 }
                    }
                    .frame(height: 110).background(Theme.box, in: .rect(cornerRadius: 8))
                } else {
                    TimeWheels(seconds: s) { seconds = $0 }.background(Theme.box, in: .rect(cornerRadius: 8))
                }
            } else {
                Text(none).font(Theme.small).foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func wheel(_ v: Int, _ range: ClosedRange<Int>, _ unit: String, _ change: @escaping (Int) -> Void) -> some View {
        Picker(unit, selection: Binding(get: { v }, set: change)) {
            ForEach(range, id: \.self) { Text("\($0)\(unit)").font(Theme.display(22)).foregroundStyle(.black).tag($0) }
        }
        .pickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity).clipped()
    }
}

/// A number typed in, or blank for none.
struct NumberField: View {
    @Binding var value: Double?
    var whole = false
    @State private var text = ""

    var body: some View {
        TextField("—", text: $text)
            .keyboardType(whole ? .numberPad : .decimalPad)
            .onAppear { text = value.map { whole ? String(Int($0)) : $0.formatted() } ?? "" }
            .onChange(of: text) { _, t in value = Double(t.replacingOccurrences(of: ",", with: ".")) }
    }
}
