import SwiftUI
import QuickLook

// MARK: Models

/// A process's written directions (darkroom-api.php?res=process): sections,
/// each with steps and boxes. The same text the web page and the PDF show.
struct ProcessDoc: Identifiable, Equatable {
    var id: Int
    var name: String
    var summary: String
    var photoTypeId: Int?
    var typeName: String?
    var archived: Bool
    var sections: [ProcSection]

    init(_ j: JSON) {
        id = j["id"].int ?? 0; name = j["name"].string ?? "Process"; summary = j["summary"].string ?? ""
        photoTypeId = j["photo_type_id"].int; typeName = j["type_name"].string; archived = j["archived"].flag
        sections = j["sections"].array.map(ProcSection.init)
    }

    /// The whole process, as PATCH takes it (sections in order, each rewritten).
    func payload() -> JSON {
        .object(["name": .string(name), "summary": .from(summary.isEmpty ? nil : summary),
                 "photo_type_id": .from(photoTypeId), "archived": .bool(archived),
                 "sections": .array(sections.map { $0.payload() })])
    }
}

struct ProcSection: Identifiable, Equatable, Hashable {
    /// Stable across reads of the sync feed: the server id, or a new one's own.
    let key: String
    var serverId: Int?
    var title: String
    var intro: String
    var presetId: Int?
    var presetName: String?
    var steps: [ProcStep]
    var boxes: [ProcBox]
    var id: String { key }

    init(title: String = "") {
        key = UUID().uuidString; self.title = title; intro = ""; steps = []; boxes = []
    }
    init(_ j: JSON) {
        serverId = j["id"].int; key = "s\(j["id"].int ?? 0)"; title = j["title"].string ?? ""; intro = j["intro"].string ?? ""
        presetId = j["preset_id"].int; presetName = j["preset_name"].string
        steps = j["steps"].array.map(ProcStep.init); boxes = j["boxes"].array.map(ProcBox.init)
    }

    func payload() -> JSON {
        .object(["id": .from(serverId), "title": .string(title), "intro": .from(intro.isEmpty ? nil : intro),
                 "preset_id": .from(presetId),
                 "steps": .array(steps.map { $0.payload() }), "boxes": .array(boxes.map { $0.payload() })])
    }

    /// Steps under their group headings, in order ("" for none).
    var groups: [(title: String, steps: [(n: Int, step: ProcStep)])] {
        var out: [(title: String, steps: [(n: Int, step: ProcStep)])] = []
        for (i, s) in steps.enumerated() {
            if out.last?.title != s.group || out.isEmpty { out.append((s.group, [])) }
            out[out.count - 1].steps.append((i + 1, s))
        }
        return out
    }
}

struct ProcStep: Identifiable, Equatable, Hashable {
    let id = UUID()
    var group = ""
    var heading = ""
    var detail = ""
    var seconds: Int?
    var temp: Double?

    init() {}
    init(_ j: JSON) {
        group = j["group_title"].string ?? ""; heading = j["heading"].string ?? ""; detail = j["detail"].string ?? ""
        seconds = j["seconds"].int; temp = j["temp"].double
    }
    func payload() -> JSON {
        .object(["group_title": .from(group.isEmpty ? nil : group), "heading": .string(heading),
                 "detail": .from(detail.isEmpty ? nil : detail), "seconds": .from(seconds), "temp": .from(temp)])
    }
    var chips: String {
        [seconds.map(Duration.format), temp.map { "\($0.formatted()) °C" }].compactMap { $0 }.joined(separator: " · ")
    }
}

struct ProcBox: Identifiable, Equatable, Hashable {
    static let kinds = [("list", "List"), ("caution", "Caution"), ("options", "Options"), ("note", "Note")]
    let id = UUID()
    var kind = "list"
    var title = ""
    var body = ""

    init() {}
    init(_ j: JSON) { kind = j["kind"].string ?? "list"; title = j["title"].string ?? ""; body = j["body"].string ?? "" }
    func payload() -> JSON {
        .object(["kind": .string(kind), "title": .from(title.isEmpty ? nil : title), "body": .string(body)])
    }
    var kindName: String { Self.kinds.first { $0.0 == kind }?.1 ?? kind.capitalized }
}

extension Snapshot {
    var processes: [ProcessDoc] { raw["processes"].array.map(ProcessDoc.init).filter { !$0.archived } }
    func process(_ id: Int) -> ProcessDoc? { processes.first { $0.id == id } }
}

extension AppStore {
    func saveProcess(_ p: ProcessDoc) async throws {
        _ = try await server.request("darkroom-api.php?res=process&id=\(p.id)", method: "PATCH", body: p.payload())
        await refresh()
    }
    func newProcess(name: String, typeId: Int?) async throws -> Int? {
        let d = try await server.request("darkroom-api.php?res=process", method: "POST",
                                         body: .object(["name": .string(name), "photo_type_id": .from(typeId)]))
        await refresh()
        return d["id"].int
    }
    func deleteProcess(_ id: Int) async throws {
        _ = try await server.request("darkroom-api.php?res=process&id=\(id)", method: "DELETE")
        await refresh()
    }
    /// The process (or one section) as a PDF in a temporary file, to look at, print or share.
    func processPdf(_ p: ProcessDoc, section: Int? = nil) async throws -> URL {
        var path = "darkroom-process-pdf.php?id=\(p.id)"
        if let section { path += "&section=\(section)" }
        let data = try await server.data(path)
        let title = section.flatMap { s in p.sections.first { $0.serverId == s }?.title }.map { "\(p.name) – \($0)" } ?? p.name
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(title.replacingOccurrences(of: "/", with: "-") + ".pdf")
        try data.write(to: url)
        return url
    }
}

private func message(_ e: Error) -> String {
    if let e = e as? ServerError { return e.retry ? "Can't reach knotwork.ca — try again with a connection" : e.message }
    return e.localizedDescription
}

// MARK: Home: the Processes list

/// Under PROCESSES on the start page: each process opens to its two choices.
struct ProcessesList: View {
    @Environment(AppStore.self) private var store
    @State private var openId: Int?
    @State private var defining: ProcessDoc?
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 10) {
            ForEach(store.snapshot?.processes ?? []) { p in
                VStack(spacing: 8) {
                    Button { withAnimation(.snappy) { openId = openId == p.id ? nil : p.id } } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(p.name).font(Theme.body.weight(.bold))
                                Text(p.sections.isEmpty ? "Not written yet" : "\(p.sections.count) sections · \(p.sections.reduce(0) { $0 + $1.steps.count }) steps")
                                    .font(Theme.small).foregroundStyle(Theme.dim)
                            }
                            Spacer()
                            Image(systemName: openId == p.id ? "chevron.down" : "chevron.right").font(.body.weight(.bold))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(WalkButtonStyle(on: openId == p.id))
                    if openId == p.id {
                        HStack(spacing: 10) {
                            Button { defining = p } label: { Text("Define").frame(maxWidth: .infinity) }
                                .buttonStyle(WalkButtonStyle())
                            NavigationLink(value: ProcessRoute(id: p.id)) { Text("Show steps ›").frame(maxWidth: .infinity) }
                                .buttonStyle(NextButtonStyle(compact: true))
                        }
                        .padding(.leading, 16)
                    }
                }
            }
            if adding {
                HStack(spacing: 10) {
                    TextField("Name of the new process", text: $newName)
                        .font(Theme.body.weight(.bold)).foregroundStyle(.black)
                        .padding(12).background(Theme.box, in: .rect(cornerRadius: 8))
                        .submitLabel(.done).onSubmit(add)
                    Button("Add", action: add).buttonStyle(NextButtonStyle(compact: true)).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } else {
                Button("+ New process") { adding = true }.buttonStyle(WalkButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .sheet(item: $defining) { p in ProcessEditor(doc: p) }
    }

    private func add() {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        Task {
            do {
                if let id = try await store.newProcess(name: name, typeId: nil), let p = store.snapshot?.process(id) {
                    newName = ""; adding = false; openId = id; defining = p
                }
            } catch { store.message = message(error) }
        }
    }
}

struct ProcessRoute: Hashable { let id: Int; var section: Int? }

// MARK: Overview and sections

/// A process: its summary, then every section to tap into.
struct ProcessView: View {
    @Environment(AppStore.self) private var store
    let id: Int
    @State private var editing = false
    @State private var pdf: URL?
    @State private var busy = false

    var body: some View {
        if let p = store.snapshot?.process(id) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(p.name.uppercased()).font(Theme.display(40)).foregroundStyle(Theme.red)
                    if let t = p.typeName { Text(t).font(Theme.label).tracking(2).foregroundStyle(Theme.dim) }
                    if !p.summary.isEmpty { Text(p.summary).font(Theme.small).foregroundStyle(Theme.red) }
                    if p.sections.isEmpty {
                        Text("No sections yet. Tap Edit to write the first one.").font(Theme.small).foregroundStyle(Theme.dim)
                    }
                    ForEach(Array(p.sections.enumerated()), id: \.element.key) { i, s in
                        NavigationLink(value: ProcessRoute(id: p.id, section: i)) {
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text("\(i + 1)").font(Theme.display(30)).frame(width: 34, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(s.title).font(Theme.body.weight(.bold)).multilineTextAlignment(.leading)
                                    Text(["\(s.steps.count) steps", s.presetId != nil ? "walk-through" : nil].compactMap { $0 }.joined(separator: " · "))
                                        .font(Theme.small).foregroundStyle(Theme.dim)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.body.weight(.bold))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(WalkButtonStyle())
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Process")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(busy ? "PDF…" : "PDF") { Task { await showPdf(p) } }.disabled(busy || p.sections.isEmpty)
                }
                ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
            }
            .sheet(isPresented: $editing) { ProcessEditor(doc: p) }
            .quickLookPreview($pdf)
            .homeBulb()
        } else {
            Text("This process is no longer on the server.").font(Theme.small).foregroundStyle(Theme.dim)
        }
    }

    private func showPdf(_ p: ProcessDoc) async {
        busy = true
        do { pdf = try await store.processPdf(p) } catch { store.message = message(error) }
        busy = false
    }
}

/// One section's steps; swipe for the next or previous section.
struct SectionPager: View {
    @Environment(AppStore.self) private var store
    let id: Int
    @State var index: Int
    @State private var editing = false
    @State private var pdf: URL?
    @State private var busy = false

    var body: some View {
        if let p = store.snapshot?.process(id), !p.sections.isEmpty {
            let i = min(index, p.sections.count - 1)
            TabView(selection: $index) {
                ForEach(Array(p.sections.enumerated()), id: \.element.key) { n, s in
                    SectionPage(process: p, section: s, number: n + 1).tag(n)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .background(Theme.bg)
            .navigationTitle("\(i + 1) of \(p.sections.count)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button(busy ? "PDF…" : "PDF") { Task { await showPdf(p, p.sections[i]) } }.disabled(busy)
                }
                ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true } }
            }
            .sheet(isPresented: $editing) { ProcessEditor(doc: p, startOn: p.sections[i].key) }
            .quickLookPreview($pdf)
            .homeBulb()
        } else {
            Text("This section is no longer on the server.").font(Theme.small).foregroundStyle(Theme.dim)
        }
    }

    private func showPdf(_ p: ProcessDoc, _ s: ProcSection) async {
        guard let sid = s.serverId else { return }
        busy = true
        do { pdf = try await store.processPdf(p, section: sid) } catch { store.message = message(error) }
        busy = false
    }
}

/// A section as the poster has it: intro, boxes, then the numbered steps.
private struct SectionPage: View {
    @Environment(AppStore.self) private var store
    @Environment(Walks.self) private var walks
    let process: ProcessDoc
    let section: ProcSection
    let number: Int

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(process.name.uppercased()).font(Theme.label).tracking(2).foregroundStyle(Theme.dim)
                Text("\(number). \(section.title)").font(Theme.display(34)).foregroundStyle(Theme.red)
                if !section.intro.isEmpty { Text(section.intro).font(Theme.body).foregroundStyle(Theme.red) }
                if let pid = section.presetId, let preset = store.snapshot?.preset(pid) {
                    Button("▶ Begin walk-through") { walks.start(preset: preset) }
                        .buttonStyle(NextButtonStyle())
                    Text(preset.name).font(Theme.small).foregroundStyle(Theme.dim)
                }
                ForEach(section.boxes) { b in BoxView(box: b) }
                ForEach(Array(section.groups.enumerated()), id: \.offset) { _, g in
                    if !g.title.isEmpty {
                        Text(g.title.uppercased()).font(Theme.label.weight(.bold)).tracking(2)
                            .foregroundStyle(Theme.onRed)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Theme.red, in: .rect(cornerRadius: 4))
                            .padding(.top, 6)
                    }
                    ForEach(g.steps, id: \.step.id) { n, s in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text("\(n)").font(Theme.display(26)).frame(width: 32, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(s.heading).font(Theme.body.weight(.bold))
                                if !s.chips.isEmpty { Text(s.chips).font(Theme.label).foregroundStyle(Theme.bright) }
                                if !s.detail.isEmpty { Text(s.detail).font(Theme.small) }
                            }
                        }
                        .foregroundStyle(Theme.red)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct BoxView: View {
    let box: ProcBox
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text((box.title.isEmpty ? box.kindName : box.title).uppercased())
                .font(Theme.label.weight(.bold)).tracking(1.5).foregroundStyle(Theme.bright)
            ForEach(Array(box.body.split(separator: "\n", omittingEmptySubsequences: true).enumerated()), id: \.offset) { _, line in
                Text(box.kind == "list" || box.kind == "options" ? "• " + line : String(line)).font(Theme.small)
            }
        }
        .foregroundStyle(Theme.red)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(box.kind == "caution" ? Theme.fill : Theme.bg, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.red, style: StrokeStyle(lineWidth: box.kind == "caution" ? 2 : 1, dash: box.kind == "note" ? [4, 3] : [])))
    }
}

// MARK: Editing

/// The process being edited, saved as one PATCH.
@MainActor @Observable
final class ProcessEdit {
    var doc: ProcessDoc
    let original: ProcessDoc
    var saving = false
    var error: String?
    init(_ d: ProcessDoc) { doc = d; original = d }
    var changed: Bool { doc != original }
}

/// Define a process: its name, kind of print and sections; each section's
/// intro, boxes, steps and the walk-through it opens.
struct ProcessEditor: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var edit: ProcessEdit
    @State private var path: [String]
    @State private var confirmLeave = false
    @State private var confirmDelete = false

    init(doc: ProcessDoc, startOn: String? = nil) {
        _edit = State(initialValue: ProcessEdit(doc))
        _path = State(initialValue: startOn.map { [$0] } ?? [])
    }

    var body: some View {
        NavigationStack(path: $path) {
            List {
                Section {
                    TextField("Name", text: $edit.doc.name).font(Theme.body.weight(.bold))
                        .listRowBackground(Theme.box).foregroundStyle(.black)
                    Picker("Kind of print", selection: $edit.doc.photoTypeId) {
                        Text("—").tag(Int?.none)
                        ForEach(store.snapshot?.photoTypes ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .font(Theme.small).listRowBackground(Theme.bg)
                    TextField("Summary", text: $edit.doc.summary, axis: .vertical).lineLimit(2...6).font(Theme.small)
                        .listRowBackground(Theme.box).foregroundStyle(.black)
                }
                Section {
                    ForEach(edit.doc.sections) { s in
                        NavigationLink(value: s.key) {
                            let i = (edit.doc.sections.firstIndex { $0.key == s.key } ?? 0) + 1
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Text("\(i)").font(Theme.display(22)).frame(width: 28, alignment: .trailing)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.title.isEmpty ? "Untitled" : s.title).font(Theme.body.weight(.bold))
                                    Text(["\(s.steps.count) steps", s.presetId.flatMap { store.snapshot?.preset($0)?.name }.map { "walk-through: \($0)" }]
                                        .compactMap { $0 }.joined(separator: " · ")).font(Theme.small).opacity(0.7)
                                }
                            }
                        }
                        .listRowBackground(Theme.box).foregroundStyle(.black)
                    }
                    .onMove { edit.doc.sections.move(fromOffsets: $0, toOffset: $1) }
                    .onDelete { edit.doc.sections.remove(atOffsets: $0) }
                    Button("+ Add section") {
                        let s = ProcSection(title: "New section")
                        edit.doc.sections.append(s); path.append(s.key)
                    }
                    .font(Theme.body.weight(.bold)).listRowBackground(Theme.bg)
                } header: {
                    Text("SECTIONS · hold and drag to reorder · swipe left to remove").font(Theme.label).foregroundStyle(Theme.bright)
                }
                Section {
                    NavigationLink("Edit walk-throughs") { EditWalksView(embedded: true) }
                        .font(Theme.body.weight(.semibold)).listRowBackground(Theme.bg)
                    Toggle("Archived (hidden from the list)", isOn: $edit.doc.archived).font(Theme.small).tint(Theme.red)
                        .listRowBackground(Theme.bg)
                    Button("Delete process", role: .destructive) { confirmDelete = true }
                        .font(Theme.small).listRowBackground(Theme.bg)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(edit.doc.name)
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { key in
                if let i = edit.doc.sections.firstIndex(where: { $0.key == key }) {
                    SectionForm(section: $edit.doc.sections[i], typeId: edit.doc.photoTypeId)
                        .toolbar { saveButton }
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(edit.changed ? "Cancel" : "Done") { if edit.changed { confirmLeave = true } else { dismiss() } }
                }
                saveButton
            }
            .confirmationDialog("Leave without saving?", isPresented: $confirmLeave, titleVisibility: .visible) {
                Button("Discard changes", role: .destructive) { dismiss() }
            }
            .confirmationDialog("Delete \(edit.doc.name) and all its sections?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) { remove() }
            } message: { Text("Export it from the web page first to keep a copy.") }
        }
        .tint(Theme.red)
        .foregroundStyle(Theme.red)
        .interactiveDismissDisabled(edit.changed)
        .alert("Not saved", isPresented: Binding(get: { edit.error != nil }, set: { if !$0 { edit.error = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(edit.error ?? "") }
    }

    private var saveButton: some ToolbarContent {
        ToolbarItem(placement: .confirmationAction) {
            Button(edit.saving ? "Saving…" : "Save") { save() }.disabled(!edit.changed || edit.saving).bold()
        }
    }

    private func save() {
        if edit.doc.name.trimmingCharacters(in: .whitespaces).isEmpty { edit.error = "The process needs a name"; return }
        if let i = edit.doc.sections.firstIndex(where: { $0.title.trimmingCharacters(in: .whitespaces).isEmpty }) {
            edit.error = "Section \(i + 1) needs a title"; return
        }
        edit.saving = true; edit.error = nil
        Task {
            do { try await store.saveProcess(edit.doc); dismiss() } catch { edit.error = message(error) }
            edit.saving = false
        }
    }

    private func remove() {
        Task {
            do { try await store.deleteProcess(edit.doc.id); dismiss() } catch { edit.error = message(error) }
        }
    }
}

/// One section: title, walk-through, intro, boxes and steps.
private struct SectionForm: View {
    @Environment(AppStore.self) private var store
    @Binding var section: ProcSection
    let typeId: Int?

    var body: some View {
        List {
            Section {
                TextField("Title", text: $section.title).font(Theme.body.weight(.bold))
                    .listRowBackground(Theme.box).foregroundStyle(.black)
                Picker("Walk-through", selection: $section.presetId) {
                    Text("None").tag(Int?.none)
                    ForEach(presets) { Text($0.name).tag(Optional($0.id)) }
                }
                .font(Theme.small).listRowBackground(Theme.bg)
                TextField("Introduction", text: $section.intro, axis: .vertical).lineLimit(2...8).font(Theme.small)
                    .listRowBackground(Theme.box).foregroundStyle(.black)
            }
            Section {
                ForEach($section.boxes) { $b in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Picker("Kind", selection: $b.kind) { ForEach(ProcBox.kinds, id: \.0) { Text($0.1).tag($0.0) } }
                                .labelsHidden().pickerStyle(.menu)
                            TextField("Title", text: $b.title).font(Theme.body.weight(.bold))
                        }
                        TextField("One item per line", text: $b.body, axis: .vertical).lineLimit(2...10).font(Theme.small)
                    }
                    .listRowBackground(Theme.box).foregroundStyle(.black)
                }
                .onMove { section.boxes.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { section.boxes.remove(atOffsets: $0) }
                Button("+ Add box") { section.boxes.append(ProcBox()) }.font(Theme.body.weight(.bold)).listRowBackground(Theme.bg)
            } header: {
                Text("BOXES · materials, cautions, options").font(Theme.label).foregroundStyle(Theme.bright)
            }
            Section {
                ForEach(Array(section.steps.enumerated()), id: \.element.id) { i, s in
                    NavigationLink(value: StepRoute(id: s.id)) {
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(i + 1)").font(Theme.display(22)).frame(width: 28, alignment: .trailing)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.heading.isEmpty ? "Untitled" : s.heading).font(Theme.body.weight(.bold))
                                let sub = [s.group.isEmpty ? nil : s.group, s.chips.isEmpty ? nil : s.chips].compactMap { $0 }.joined(separator: " · ")
                                if !sub.isEmpty { Text(sub).font(Theme.small).opacity(0.7) }
                            }
                        }
                    }
                    .listRowBackground(Theme.box).foregroundStyle(.black)
                }
                .onMove { section.steps.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { section.steps.remove(atOffsets: $0) }
                Button("+ Add step") {
                    var s = ProcStep(); s.group = section.steps.last?.group ?? ""
                    section.steps.append(s)
                }
                .font(Theme.body.weight(.bold)).listRowBackground(Theme.bg)
            } header: {
                Text("STEPS · hold and drag to reorder · swipe left to remove").font(Theme.label).foregroundStyle(Theme.bright)
            } footer: {
                Text("Save sends the whole process; changes are kept when you go back.").font(Theme.small)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: StepRoute.self) { r in
            if let i = section.steps.firstIndex(where: { $0.id == r.id }) { ProcStepForm(step: $section.steps[i]) }
        }
    }

    private var presets: [Preset] {
        let all = store.snapshot?.presets ?? []
        let mine = all.filter { typeId == nil || $0.photoTypeId == typeId }
        // Keep one chosen earlier even if the kind of print changed since.
        if let id = section.presetId, !mine.contains(where: { $0.id == id }), let p = all.first(where: { $0.id == id }) { return mine + [p] }
        return mine
    }
}

private struct StepRoute: Hashable { let id: UUID }

private struct ProcStepForm: View {
    @Binding var step: ProcStep
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Field(label: "Heading") { TextField("", text: $step.heading, axis: .vertical).lineLimit(1...3) }
                Field(label: "Group (a bar above the steps)") { TextField("", text: $step.group) }
                OptionalTime(label: "Time", none: "No time", seconds: $step.seconds)
                Field(label: "Temp °C") { NumberField(value: $step.temp) }
                Field(label: "Details") { TextField("", text: $step.detail, axis: .vertical).lineLimit(3...12) }
            }
            .padding(18)
        }
        .background(Theme.bg)
        .navigationTitle(step.heading)
        .navigationBarTitleDisplayMode(.inline)
    }
}
