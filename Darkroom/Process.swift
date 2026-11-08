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
    var nextKey: String?        // the stage to go on to; same as its key
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
        nextKey = j["next_section_id"].int.map { "s\($0)" }
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
    var serverId: Int?
    var group = ""
    var heading = ""
    var detail = ""
    var seconds: Int?
    var temp: Double?

    init() {}
    init(_ j: JSON) {
        serverId = j["id"].int; group = j["group_title"].string ?? ""; heading = j["heading"].string ?? ""; detail = j["detail"].string ?? ""
        seconds = j["seconds"].int; temp = j["temp"].double
    }
    func payload() -> JSON {
        .object(["id": .from(serverId), "group_title": .from(group.isEmpty ? nil : group), "heading": .string(heading),
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
    func saveProcess(_ e: ProcessEdit) async throws {
        _ = try await server.request("darkroom-api.php?res=process&id=\(e.doc.id)", method: "PATCH", body: e.payload())
        await refresh()
    }
    /// Stars a walk, or takes its star off. Needs a connection.
    func setFavourite(_ preset: Int, on: Bool) async throws {
        _ = try await server.request("darkroom-api.php?res=process_preset&id=\(preset)", method: "PATCH", body: .object(["favourite": .from(on ? 1 : 0)]))
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

/// Under PROCESSES on the start page: each process opens to its stages. A
/// stage's name opens its overview; beside it, the runner begins its walk
/// and the star puts that walk on the start page.
struct ProcessesList: View {
    @Environment(AppStore.self) private var store
    @Environment(Walks.self) private var walks
    @State private var openId: Int?
    @State private var defining: ProcessDoc?
    /// The stage to open on, when defining from a stage's pencil.
    @State private var definingStage: String?
    @State private var adding = false
    @State private var newName = ""

    var body: some View {
        VStack(spacing: 8) {
            ForEach(store.snapshot?.processes ?? []) { p in
                Button { withAnimation(.snappy) { openId = openId == p.id ? nil : p.id } } label: {
                    HStack {
                        Text(p.name)
                        Spacer(minLength: 54)
                        Image(systemName: openId == p.id ? "chevron.down" : "chevron.right")
                    }
                }
                .buttonStyle(TreeRowStyle(fill: Theme.procBar, text: Theme.procText))
                .overlay(alignment: .trailing) {
                    NavigationLink(value: ProcessRoute(id: p.id)) {
                        Image(systemName: "eye").font(.system(size: 22, weight: .semibold)).foregroundStyle(Theme.procText).frame(width: 50, height: 54).contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 34)
                    .accessibilityLabel("Overview of \(p.name)")
                }
                if openId == p.id {
                    VStack(spacing: 6) {
                        ForEach(Array(p.sections.enumerated()), id: \.element.key) { i, s in
                            stage(s, in: p, at: i)
                        }
                    }
                    .padding(.leading, 12)
                }
            }
            unfiled
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
        .sheet(item: $defining) { p in ProcessEditor(doc: p, startOn: definingStage) }
    }

    private func stage(_ s: ProcSection, in p: ProcessDoc, at i: Int) -> some View {
        HStack(spacing: 4) {
            NavigationLink(value: ProcessRoute(id: p.id, section: i)) {
                Text(s.title).lineLimit(2).minimumScaleFactor(0.8).multilineTextAlignment(.leading)
            }
            .buttonStyle(TreeRowStyle(fill: Theme.stageBar, text: Theme.stageText))
            if let w = store.snapshot?.preset(s.presetId) { icons(w) }
            else {
                Button { definingStage = s.key; defining = p } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.red).frame(width: 88, height: 54)
                }
                .accessibilityLabel("Create walkthrough for \(s.title)")
            }
        }
    }

    /// The runner and the star.
    private func icons(_ w: Preset) -> some View {
        HStack(spacing: 0) {
            Button { walks.start(preset: w) } label: {
                Image(systemName: "figure.run").font(.system(size: 26, weight: .bold)).foregroundStyle(Theme.red).frame(width: 44, height: 54)
            }
            .accessibilityLabel("Begin walk-through: \(w.name)")
            Button {
                Task {
                    do { try await store.setFavourite(w.id, on: !w.favourite) } catch { store.message = message(error) }
                }
            } label: {
                Image(systemName: w.favourite ? "star.circle.fill" : "star.circle").font(.system(size: 26, weight: .bold))
                    .foregroundStyle(w.favourite ? Theme.bright : Theme.dim).frame(width: 44, height: 54)
            }
            .accessibilityLabel(w.favourite ? "Remove from favourites" : "Add to favourites")
        }
    }

    /// Walks not on any stage yet.
    @ViewBuilder private var unfiled: some View {
        let loose = (store.snapshot?.presets ?? []).filter { $0.stageId == nil }
        if !loose.isEmpty {
            Button { withAnimation(.snappy) { openId = openId == 0 ? nil : 0 } } label: {
                HStack {
                    Text("Not filed yet")
                    Spacer()
                    Image(systemName: openId == 0 ? "chevron.down" : "chevron.right")
                }
            }
            .buttonStyle(TreeRowStyle(fill: Theme.procBar, text: Theme.procText))
            if openId == 0 {
                ForEach(loose) { w in
                    HStack(spacing: 4) {
                        Text(w.name).font(Theme.body.weight(.bold)).foregroundStyle(Theme.stageText)
                            .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .background(Theme.stageBar, in: .rect(cornerRadius: 10))
                        icons(w)
                    }
                    .padding(.leading, 12)
                }
            }
        }
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
                    SectionPage(process: p, section: s, number: n + 1, editMode: editing).tag(n)
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
                ToolbarItem(placement: .primaryAction) { Button(editing ? "Done" : "Edit") { withAnimation(.snappy) { editing.toggle() } }.bold(editing) }
            }
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
    /// Edit is on: every step shows its own edit icon.
    let editMode: Bool
    @State private var editing: WalkStepTarget?
    @State private var editingStep: ProcStep?
    /// What a dragged walk step is hovering over.
    @State private var dropOn: String?
    /// The step a new walk is being started from, while asking what it makes.
    @State private var startingOn: Int?
    /// The overview steps showing their walk steps as bars.
    @State private var open: Set<Int> = []

    /// The walk's steps by the overview step they belong to.
    private var walkSteps: [Int: [(n: Int, step: StepEdit)]]? {
        let e = ProcessEdit(process)
        e.load { store.rawPreset($0) }
        guard let list = e.walks[section.key] else { return nil }
        var out: [Int: [(n: Int, step: StepEdit)]] = [:]
        for (i, w) in list.enumerated() {
            out[w.block.flatMap { b in section.steps.firstIndex { $0.id == b } } ?? -1, default: []].append((i + 1, w))
        }
        return out
    }

    private func start(_ makes: [String: JSON]) {
        if let i = startingOn { editing = WalkStepTarget(stepId: nil, block: i, makes: .object(makes)) }
        startingOn = nil
    }

    /// A step with nothing in the walk: starts its walk step (and the walk, if none yet).
    private func pencil(_ i: Int, hasWalk: Bool) -> some View {
        Button { add(i, hasWalk: hasWalk) } label: {
            Image(systemName: "square.and.pencil").font(.system(size: 20, weight: .semibold)).frame(minWidth: 62, minHeight: 40)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.red)
        .accessibilityLabel(hasWalk ? "Add a walk step" : "Create walkthrough")
    }

    private func add(_ i: Int, hasWalk: Bool) {
        if hasWalk { editing = WalkStepTarget(stepId: nil, block: i) } else { startingOn = i }
    }

    /// One step's walk steps as a line of widgets. Tapping one opens the group as
    /// bars, in order, with what each is set to; tapping a bar folds them again.
    @ViewBuilder private func dropdown(_ i: Int, _ steps: [(n: Int, step: StepEdit)], hasWalk: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if editMode || open.contains(i) {
                ForEach(steps, id: \.step.id) { n, w in bar(i, n, w) }
                if editMode {
                    Button(hasWalk ? "+ Add step" : "+ Create walkthrough") { add(i, hasWalk: hasWalk) }
                        .font(Theme.small.weight(.bold)).foregroundStyle(Theme.red).frame(minHeight: 36)
                }
            } else if !steps.isEmpty {
                ChipFlow {
                    ForEach(steps, id: \.step.id) { _, w in
                        Button { toggle(i) } label: { chip(Text(w.name)) }.buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.leading, 44)
    }

    private func toggle(_ i: Int) {
        withAnimation(.snappy) { if open.remove(i) == nil { open.insert(i) } }
    }

    private func chip(_ label: Text) -> some View {
        label.font(Theme.label.weight(.bold)).lineLimit(1).foregroundStyle(.black)
            .padding(.horizontal, 9).padding(.vertical, 8)
            .background(Theme.walkBar, in: .rect(cornerRadius: 6))
    }

    /// In Edit a bar can be dragged onto another bar, or onto a process step.
    @ViewBuilder private func bar(_ i: Int, _ n: Int, _ w: StepEdit) -> some View {
        if editMode, let sid = w.serverId {
            barBody(i, n, w)
                .draggable(String(sid)) { chip(Text(w.name)) }
                .dropDestination(for: String.self) { items, _ in drop(items) { $0.walk?.serverId == sid } }
                isTargeted: { dropOn = $0 ? "w\(sid)" : (dropOn == "w\(sid)" ? nil : dropOn) }
                .overlay { if dropOn == "w\(sid)" { RoundedRectangle(cornerRadius: 8).stroke(Theme.red, lineWidth: 2) } }
        } else {
            barBody(i, n, w)
        }
    }

    /// Moves a dropped walk step and saves it. On a bar it takes that bar's place;
    /// on a process step it becomes the first walk step under it.
    private func drop(_ items: [String], on target: (ProcessEdit.Row) -> Bool) -> Bool {
        guard let sid = items.first.flatMap({ Int($0) }) else { return false }
        let e = ProcessEdit(process)
        e.load { store.rawPreset($0) }
        let rows = e.rows(section.key)
        guard let from = rows.firstIndex(where: { $0.walk?.serverId == sid }),
              let to = rows.firstIndex(where: target), from != to else { return false }
        e.moveRows(section.key, from: [from], to: rows[to].overview != nil || from < to ? to + 1 : to)
        guard e.changed else { return false }
        Task {
            do { try await store.saveProcess(e) } catch { store.message = message(error) }
        }
        return true
    }

    private func barBody(_ i: Int, _ n: Int, _ w: StepEdit) -> some View {
        HStack(spacing: 4) {
            Button { if editMode { editing = WalkStepTarget(stepId: w.serverId, block: i) } else { toggle(i) } } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(n). \(w.name)").font(Theme.small.weight(.bold)).multilineTextAlignment(.leading)
                    Text(store.snapshot?.summary(w) ?? "").font(Theme.label).opacity(0.75).multilineTextAlignment(.leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            if editMode {
                Button { editing = WalkStepTarget(stepId: w.serverId, block: i) } label: {
                    Image(systemName: "square.and.pencil").font(.system(size: 17, weight: .semibold)).frame(width: 40, height: 40).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(w.name)")
            }
        }
        .foregroundStyle(.black)
        .padding(.leading, 10).padding(.vertical, editMode ? 4 : 8).padding(.trailing, 4)
        .background(Theme.walkBar, in: .rect(cornerRadius: 8))
    }

    var body: some View {
        let walk = walkSteps
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
                if let before = walk?[-1] {
                    dropdown(-1, before, hasWalk: true).padding(.leading, -44)
                }
                if section.steps.isEmpty && walk?[-1] == nil { dropdown(-1, [], hasWalk: walk != nil).padding(.leading, -44) }
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
                            .frame(maxWidth: .infinity, alignment: .leading)
                            if editMode {
                                Button { editingStep = s } label: {
                                    Image(systemName: "square.and.pencil").font(.system(size: 20, weight: .semibold)).frame(width: 44, height: 40).contentShape(.rect)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Edit \(s.heading)")
                            } else if walk?[n - 1]?.isEmpty ?? true { pencil(n - 1, hasWalk: walk != nil) }
                        }
                        .foregroundStyle(Theme.red)
                        .dropDestination(for: String.self) { items, _ in editMode && drop(items) { $0.overview?.id == s.id } }
                        isTargeted: { dropOn = $0 ? "s\(n)" : (dropOn == "s\(n)" ? nil : dropOn) }
                        .background { if dropOn == "s\(n)" { RoundedRectangle(cornerRadius: 8).stroke(Theme.red, lineWidth: 2).padding(-4) } }
                        if editMode || !(walk?[n - 1]?.isEmpty ?? true) { dropdown(n - 1, walk?[n - 1] ?? [], hasWalk: walk != nil) }
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .sheet(item: $editing) { WalkStepSheet(process: process, sectionKey: section.key, target: $0) }
        .sheet(item: $editingStep) { OverviewStepSheet(process: process, sectionKey: section.key, stepId: $0.id) }
        .confirmationDialog("What does this walk make?", isPresented: Binding(get: { startingOn != nil }, set: { if !$0 { startingOn = nil } }), titleVisibility: .visible) {
            if let t = process.photoTypeId { Button("A print") { start(["makes": .string("print"), "photo_type_id": .from(t)]) } }
            Button("A carbon tissue") { start(["makes": .string("tissue")]) }
            ForEach(store.snapshot?.chemistryTypes ?? [], id: \.id) { c in
                Button("Chemistry: \(c.name)") { start(["makes": .string("chemistry"), "chemistry_type_id": .from(c.id)]) }
            }
        }
    }
}

/// Widgets left to right, wrapping when a line is full.
private struct ChipFlow: Layout {
    var spacing: CGFloat = 6

    private func frames(_ width: CGFloat, _ views: Subviews) -> [CGRect] {
        var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
        return views.map { v in
            var s = v.sizeThatFits(.unspecified)
            s.width = min(s.width, width)
            if x > 0 && x + s.width > width { x = 0; y += line + spacing; line = 0 }
            defer { x += s.width + spacing; line = max(line, s.height) }
            return CGRect(origin: CGPoint(x: x, y: y), size: s)
        }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.replacingUnspecifiedDimensions().width
        return CGSize(width: width, height: frames(width, subviews).map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (v, f) in zip(subviews, frames(bounds.width, subviews)) {
            v.place(at: CGPoint(x: bounds.minX + f.minX, y: bounds.minY + f.minY), proposal: ProposedViewSize(f.size))
        }
    }
}

/// A walk step to open from the overview: an existing one, or nil to add one.
private struct WalkStepTarget: Identifiable {
    let id = UUID()
    let stepId: Int?, block: Int
    /// Starts the stage's walk: what it makes.
    var makes: JSON?
}

/// One walk step edited straight from the overview, saved with its process.
private struct WalkStepSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var edit: ProcessEdit
    let sectionKey: String
    let target: WalkStepTarget
    @State private var stepId: UUID?
    @State private var confirmRemove = false

    init(process: ProcessDoc, sectionKey: String, target: WalkStepTarget) {
        _edit = State(initialValue: ProcessEdit(process)); self.sectionKey = sectionKey; self.target = target
    }

    private var list: [StepEdit] { edit.walks[sectionKey] ?? [] }

    var body: some View {
        NavigationStack {
            Group {
                if let id = stepId, let i = list.firstIndex(where: { $0.id == id }) {
                    StepForm(step: Binding(get: { edit.walks[sectionKey]?.first { $0.id == id } ?? StepEdit() },
                                           set: { v in if let n = edit.walks[sectionKey]?.firstIndex(where: { $0.id == id }) { edit.walks[sectionKey]?[n] = v } }),
                             number: i + 1, earlier: list.prefix(i).filter { !$0.isSelect })
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(edit.saving ? "Saving…" : "Save") { save() }.disabled(!edit.changed || edit.saving).bold()
                }
                if target.stepId != nil {
                    ToolbarItem(placement: .bottomBar) { Button("Remove step", role: .destructive) { confirmRemove = true } }
                }
            }
            .confirmationDialog("Remove this walk step?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { if let id = stepId { stepId = nil; edit.removeWalkStep(sectionKey, id); save() } }
            }
            .alert("Not saved", isPresented: Binding(get: { edit.error != nil }, set: { if !$0 { edit.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(edit.error ?? "") }
        }
        .tint(Theme.red)
        .foregroundStyle(Theme.red)
        .interactiveDismissDisabled(edit.changed)
        .onAppear {
            guard stepId == nil else { return }
            edit.load { store.rawPreset($0) }
            if let s = target.stepId { stepId = list.first { $0.serverId == s }?.id }
            else {
                let steps = edit.doc.sections.first { $0.key == sectionKey }?.steps ?? []
                if let m = target.makes { edit.newWalks[sectionKey] = m; edit.walks[sectionKey] = [] }
                guard steps.indices.contains(target.block) else { stepId = edit.addWalkStep(sectionKey, block: nil); return }
                // A step with nothing in the walk yet starts from its own words.
                let o = steps[target.block]
                var first = StepEdit()
                if !list.contains(where: { $0.block == o.id }) {
                    first.name = o.heading; first.notes = o.detail; first.kind = o.seconds != nil ? "timer" : "do"
                    first.timed = o.seconds != nil; first.defaultSeconds = o.seconds; first.defaultTemp = o.temp
                }
                stepId = edit.addWalkStep(sectionKey, block: o.id, copy: first)
            }
        }
    }

    private func save() {
        if list.contains(where: { $0.name.trimmingCharacters(in: .whitespaces).isEmpty }) { edit.error = "The step needs a title"; return }
        edit.saving = true; edit.error = nil
        Task {
            do { try await store.saveProcess(edit); dismiss() } catch { edit.error = message(error) }
            edit.saving = false
        }
    }
}

/// One overview step edited on its own, saved with its process.
private struct OverviewStepSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var edit: ProcessEdit
    let sectionKey: String
    let stepId: UUID

    init(process: ProcessDoc, sectionKey: String, stepId: UUID) {
        _edit = State(initialValue: ProcessEdit(process)); self.sectionKey = sectionKey; self.stepId = stepId
    }

    private var at: (s: Int, n: Int)? {
        guard let s = edit.doc.sections.firstIndex(where: { $0.key == sectionKey }),
              let n = edit.doc.sections[s].steps.firstIndex(where: { $0.id == stepId }) else { return nil }
        return (s, n)
    }

    var body: some View {
        NavigationStack {
            Group {
                if let a = at { ProcStepForm(step: $edit.doc.sections[a.s].steps[a.n]) }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(edit.saving ? "Saving…" : "Save") { save() }.disabled(!edit.changed || edit.saving).bold()
                }
            }
            .alert("Not saved", isPresented: Binding(get: { edit.error != nil }, set: { if !$0 { edit.error = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(edit.error ?? "") }
        }
        .tint(Theme.red)
        .foregroundStyle(Theme.red)
        .interactiveDismissDisabled(edit.changed)
        .onAppear { edit.load { store.rawPreset($0) } }
    }

    private func save() {
        if let a = at, edit.doc.sections[a.s].steps[a.n].heading.trimmingCharacters(in: .whitespaces).isEmpty { edit.error = "The step needs a heading"; return }
        edit.saving = true; edit.error = nil
        Task {
            do { try await store.saveProcess(edit); dismiss() } catch { edit.error = message(error) }
            edit.saving = false
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

/// A step copied in View all steps, ready to paste anywhere.
enum CopiedStep { case overview(ProcStep), walk(StepEdit) }

/// The process being edited with each stage's walk, saved as one PATCH.
@MainActor @Observable
final class ProcessEdit {
    var doc: ProcessDoc
    let original: ProcessDoc
    /// Each stage's walk steps, by section key, in walk order. A step's block
    /// is the overview step it sits beside, so the order follows the overview.
    var walks: [String: [StepEdit]] = [:]
    private var originalWalks: [String: [StepEdit]] = [:]
    /// Walks to create on save: what they make.
    var newWalks: [String: JSON] = [:]
    var copied: CopiedStep?
    private var loaded = false
    var saving = false
    var error: String?
    init(_ d: ProcessDoc) { doc = d; original = d }

    var changed: Bool { doc != original || walks != originalWalks || !newWalks.isEmpty }
    func hasWalk(_ key: String) -> Bool { walks[key] != nil }

    func load(_ raw: (Int) -> JSON?) {
        guard !loaded else { return }
        loaded = true
        for s in doc.sections {
            guard let p = s.presetId, let j = raw(p) else { continue }
            var last: UUID?
            var list = StepEdit.list(j)
            for i in list.indices {
                if let n = list[i].instructionId, let o = s.steps.first(where: { $0.serverId == n }) { last = o.id }
                list[i].block = last
            }
            walks[s.key] = list
            resort(s.key)
        }
        originalWalks = walks
    }

    private func section(_ key: String) -> Int? { doc.sections.firstIndex { $0.key == key } }

    /// Puts the walk steps in the order of the overview steps they sit beside.
    func resort(_ key: String) {
        guard let i = section(key), let list = walks[key] else { return }
        let rank = Dictionary(uniqueKeysWithValues: doc.sections[i].steps.enumerated().map { ($0.element.id, $0.offset) })
        let sorted = list.enumerated().sorted {
            let a = $0.element.block.flatMap { rank[$0] } ?? -1, b = $1.element.block.flatMap { rank[$0] } ?? -1
            return (a, $0.offset) < (b, $1.offset)
        }.map(\.element)
        if sorted != list { walks[key] = sorted }
    }

    func moveOverview(_ key: String, _ id: UUID, by d: Int) {
        guard let s = section(key), let i = doc.sections[s].steps.firstIndex(where: { $0.id == id }),
              doc.sections[s].steps.indices.contains(i + d) else { return }
        doc.sections[s].steps.swapAt(i, i + d)
        resort(key)
    }

    /// The overview step goes; its walk steps stay, beside the one before.
    func removeOverview(_ key: String, _ id: UUID) {
        guard let s = section(key), let i = doc.sections[s].steps.firstIndex(where: { $0.id == id }) else { return }
        let before = i > 0 ? doc.sections[s].steps[i - 1].id : nil
        for n in walks[key]?.indices ?? 0..<0 where walks[key]?[n].block == id { walks[key]?[n].block = before }
        doc.sections[s].steps.remove(at: i)
        resort(key)
    }

    @discardableResult func addWalkStep(_ key: String, block: UUID?, copy: StepEdit? = nil) -> UUID {
        var st = copy ?? StepEdit()
        st.id = UUID(); st.serverId = nil; st.sameAs = nil; st.timesUsed = 0; st.block = block
        walks[key, default: []].append(st)
        resort(key)
        return st.id
    }

    func removeWalkStep(_ key: String, _ id: UUID) {
        walks[key]?.removeAll { $0.id == id }
        for n in walks[key]?.indices ?? 0..<0 where walks[key]?[n].sameAs == id { walks[key]?[n].sameAs = nil }
    }

    /// Up or down beside its overview step, then on to the one before or after.
    func moveWalkStep(_ key: String, _ id: UUID, by d: Int) {
        guard let s = section(key), var list = walks[key], let i = list.firstIndex(where: { $0.id == id }) else { return }
        let block = list[i].block
        let same = list.indices.filter { list[$0].block == block }
        if let p = same.firstIndex(of: i), same.indices.contains(p + d) {
            list.swapAt(i, same[p + d])
        } else {
            let blocks: [UUID?] = [nil] + doc.sections[s].steps.map { Optional($0.id) }
            guard let b = blocks.firstIndex(of: block), blocks.indices.contains(b + d) else { return }
            list[i].block = blocks[b + d]
        }
        walks[key] = list
        resort(key)
    }

    func addOverview(_ key: String, after id: UUID?, copy: ProcStep? = nil) {
        guard let s = section(key) else { return }
        var st = ProcStep()
        if let copy { st.group = copy.group; st.heading = copy.heading; st.detail = copy.detail; st.seconds = copy.seconds; st.temp = copy.temp }
        else { st.group = doc.sections[s].steps.last?.group ?? "" }
        let at = id.flatMap { o in doc.sections[s].steps.firstIndex { $0.id == o } }.map { $0 + 1 } ?? doc.sections[s].steps.count
        doc.sections[s].steps.insert(st, at: at)
        resort(key)
    }

    /// Pastes beside an overview step: walk steps as walk steps; an overview
    /// step's words become a walk step's title and directions.
    func pasteWalk(_ key: String, block: UUID?) {
        switch copied {
        case .walk(let w): addWalkStep(key, block: block, copy: w)
        case .overview(let o):
            var w = StepEdit(); w.name = o.heading; w.notes = o.detail; w.kind = "do"; w.timed = o.seconds != nil; w.defaultSeconds = o.seconds; w.defaultTemp = o.temp
            guard hasWalk(key) else { return }
            addWalkStep(key, block: block, copy: w)
        case nil: break
        }
    }

    func pasteOverview(_ key: String, after id: UUID?) {
        switch copied {
        case .overview(let o): addOverview(key, after: id, copy: o)
        case .walk(let w):
            var o = ProcStep(); o.heading = w.name; o.detail = w.notes; o.seconds = w.defaultSeconds; o.temp = w.defaultTemp
            addOverview(key, after: id, copy: o)
        case nil: break
        }
    }

    /// One row of the interleaved list: an overview step or a walk step.
    struct Row: Identifiable {
        let overview: ProcStep?, walk: StepEdit?
        var id: UUID { overview?.id ?? walk?.id ?? UUID() }
    }

    /// Each overview step with its walk steps straight after it.
    func rows(_ key: String) -> [Row] {
        guard let s = section(key) else { return [] }
        let list = walks[key] ?? []
        var out = list.filter { $0.block == nil }.map { Row(overview: nil, walk: $0) }
        for o in doc.sections[s].steps {
            out.append(Row(overview: o, walk: nil))
            out += list.filter { $0.block == o.id }.map { Row(overview: nil, walk: $0) }
        }
        return out
    }

    /// A drag. A walk step belongs to the overview step above where it lands;
    /// an overview step carries its walk steps and lands between whole groups.
    func moveRows(_ key: String, from: IndexSet, to: Int) {
        guard let s = section(key), let first = from.first else { return }
        var f = rows(key), source = from, dest = to
        if f[first].overview != nil {
            var end = first + 1
            while end < f.count, f[end].overview == nil { end += 1 }
            if dest > first && dest < end { return }
            while dest < f.count, f[dest].overview == nil { dest += 1 }
            source = IndexSet(first..<end)
        }
        f.move(fromOffsets: source, toOffset: dest)
        var list: [StepEdit] = [], last: UUID?
        for r in f {
            if let o = r.overview { last = o.id }
            else if var w = r.walk { w.block = last; list.append(w) }
        }
        doc.sections[s].steps = f.compactMap(\.overview)
        if walks[key] != nil { walks[key] = list }
    }

    /// A new walk step beside an overview step, starting from its words.
    @discardableResult func addWalkStep(_ key: String, from o: ProcStep) -> UUID {
        var w = StepEdit()
        w.name = o.heading; w.notes = o.detail; w.kind = o.seconds != nil ? "timer" : "do"
        w.timed = o.seconds != nil; w.defaultSeconds = o.seconds; w.defaultTemp = o.temp
        return addWalkStep(key, block: o.id, copy: w)
    }

    func payload() -> JSON {
        let secs = doc.sections.map { s -> JSON in
            guard case .object(var o) = s.payload() else { return s.payload() }
            o["next_index"] = .from(s.nextKey.flatMap { k in doc.sections.firstIndex { $0.key == k } })
            if let w = newWalks[s.key] { o["walk"] = w }
            if let list = walks[s.key] {
                o["walk_steps"] = .array(list.map { st in
                    guard case .object(var p) = st.payload(sameAsIndex: st.sameAs.flatMap { ref in list.firstIndex { $0.id == ref } }) else { return .null }
                    p["instruction_index"] = .from(st.block.flatMap { b in s.steps.firstIndex { $0.id == b } })
                    return .object(p)
                })
            }
            return .object(o)
        }
        guard case .object(var top) = doc.payload() else { return doc.payload() }
        top["sections"] = .array(secs)
        return .object(top)
    }
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
                    NavigationLink("View all steps") { AllStepsView(edit: edit) }
                        .font(Theme.body.weight(.semibold)).listRowBackground(Theme.bg)
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
                    SectionForm(edit: edit, section: $edit.doc.sections[i], typeId: edit.doc.photoTypeId)
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
        .onAppear { edit.load { store.rawPreset($0) } }
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
        if let blank = edit.doc.sections.first(where: { s in (edit.walks[s.key] ?? []).contains { $0.name.trimmingCharacters(in: .whitespaces).isEmpty } }) {
            edit.error = "A walk step in \(blank.title) needs a title"; return
        }
        edit.saving = true; edit.error = nil
        Task {
            do { try await store.saveProcess(edit); dismiss() } catch { edit.error = message(error) }
            edit.saving = false
        }
    }

    private func remove() {
        Task {
            do { try await store.deleteProcess(edit.doc.id); dismiss() } catch { edit.error = message(error) }
        }
    }
}

/// One stage: title, next stage, intro, boxes, and its overview steps. The
/// runner beside a step opens the walk beside the overview.
private struct SectionForm: View {
    @Environment(AppStore.self) private var store
    @Bindable var edit: ProcessEdit
    @Binding var section: ProcSection
    let typeId: Int?
    /// The overview step a new walk starts from, while asking what it makes.
    @State private var startFrom: ProcStep?
    @State private var overview: StepRoute?
    @State private var walkStep: StepRoute?

    private var key: String { section.key }
    private var walk: [StepEdit] { edit.walks[key] ?? [] }

    var body: some View {
        List {
            Section {
                TextField("Title", text: $section.title).font(Theme.body.weight(.bold))
                    .listRowBackground(Theme.box).foregroundStyle(.black)
                Picker("Optional next step", selection: $section.nextKey) {
                    Text("None").tag(String?.none)
                    ForEach(edit.doc.sections.filter { $0.key != key && ($0.presetId != nil || edit.newWalks[$0.key] != nil) }) { Text($0.title).tag(Optional($0.key)) }
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
                let rows = edit.rows(key)
                ForEach(rows) { r in
                    if let o = r.overview { overviewRow(o) } else if let w = r.walk { walkRow(w) }
                }
                .onMove { edit.moveRows(key, from: $0, to: $1) }
                .onDelete { $0.map { rows[$0] }.forEach { r in
                    if let o = r.overview { edit.removeOverview(key, o.id) } else if let w = r.walk { edit.removeWalkStep(key, w.id) }
                } }
                Button("+ Add step") { edit.addOverview(key, after: nil) }
                    .font(Theme.body.weight(.bold)).listRowBackground(Theme.bg)
            } header: {
                Text("STEPS · overview with its walk steps under it · drag to match them up").font(Theme.label).foregroundStyle(Theme.bright)
            } footer: {
                Text("Save sends the whole process; changes are kept when you go back.").font(Theme.small)
            }
        }
        .environment(\.editMode, .constant(.active))
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(section.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $overview) { r in
            if let i = section.steps.firstIndex(where: { $0.id == r.id }) { ProcStepForm(step: $section.steps[i]) }
        }
        .navigationDestination(item: $walkStep) { r in
            if let i = walk.firstIndex(where: { $0.id == r.id }) {
                StepForm(step: Binding(get: { edit.walks[key]?[safe: i] ?? StepEdit() }, set: { edit.walks[key]?[i] = $0 }),
                         number: i + 1, earlier: walk.prefix(i).filter { !$0.isSelect })
            }
        }
        .confirmationDialog("What does this walk make?", isPresented: Binding(get: { startFrom != nil }, set: { if !$0 { startFrom = nil } }), titleVisibility: .visible) {
            if let t = typeId { Button("A print") { create(["makes": .string("print"), "photo_type_id": .from(t)]) } }
            Button("A carbon tissue") { create(["makes": .string("tissue")]) }
            ForEach(store.snapshot?.chemistryTypes ?? [], id: \.id) { c in
                Button("Chemistry: \(c.name)") { create(["makes": .string("chemistry"), "chemistry_type_id": .from(c.id)]) }
            }
        }
    }

    private func overviewRow(_ s: ProcStep) -> some View {
        let n = (section.steps.firstIndex { $0.id == s.id } ?? 0) + 1
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Button { overview = StepRoute(id: s.id) } label: {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(n)").font(Theme.display(22))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.heading.isEmpty ? "Untitled" : s.heading).font(Theme.body.weight(.bold)).multilineTextAlignment(.leading)
                        let sub = [s.group.isEmpty ? nil : s.group, s.chips.isEmpty ? nil : s.chips].compactMap { $0 }.joined(separator: " · ")
                        if !sub.isEmpty { Text(sub).font(Theme.small).opacity(0.7) }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderless)
            Button { addWalk(s) } label: {
                Image(systemName: "figure.run").font(.system(size: 18, weight: .bold)).frame(width: 38, height: 38)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Add a walk step")
        }
        .foregroundStyle(.black)
        .listRowBackground(Theme.box)
    }

    private func walkRow(_ w: StepEdit) -> some View {
        let n = (walk.firstIndex { $0.id == w.id } ?? 0) + 1
        return Button { walkStep = StepRoute(id: w.id) } label: {
            HStack(spacing: 8) {
                Image(systemName: "figure.run").font(.system(size: 14, weight: .bold))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(n). \(w.name)").font(Theme.small.weight(.bold)).multilineTextAlignment(.leading)
                    Text(store.snapshot?.summary(w) ?? "").font(Theme.label).opacity(0.75).multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.black)
        .padding(.leading, 18)
        .listRowBackground(Theme.walkBar)
    }

    /// A walk step under this overview step; first asks what the walk makes if there's none.
    private func addWalk(_ s: ProcStep) {
        guard edit.hasWalk(key) else { startFrom = s; return }
        walkStep = StepRoute(id: edit.addWalkStep(key, from: s))
    }

    private func create(_ walk: [String: JSON]) {
        edit.newWalks[key] = .object(walk)
        edit.walks[key] = []
        if let s = startFrom { walkStep = StepRoute(id: edit.addWalkStep(key, from: s)) }
        startFrom = nil
    }
}

private struct StepRoute: Hashable, Identifiable { let id: UUID }

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

/// Everything in the process on one page: copy any step, paste it anywhere,
/// to put right a pairing or move words between overview and walk.
private struct AllStepsView: View {
    @Environment(AppStore.self) private var store
    @Bindable var edit: ProcessEdit

    var body: some View {
        List {
            ForEach(edit.doc.sections) { s in
                Section {
                    ForEach([nil] + s.steps.map { Optional($0) }, id: \.?.id) { o in block(s, o) }
                } header: {
                    Text(s.title.uppercased()).font(Theme.label).foregroundStyle(Theme.bright)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("All steps")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder private func block(_ s: ProcSection, _ o: ProcStep?) -> some View {
        let beside = (edit.walks[s.key] ?? []).filter { $0.block == o?.id }
        if o != nil || !beside.isEmpty || edit.copied != nil {
            VStack(alignment: .leading, spacing: 6) {
                if let o {
                    line(o.heading, o.detail, copied: edit.copiedOverview(o)) { edit.copied = .overview(o) } remove: { edit.removeOverview(s.key, o.id) }
                } else {
                    Text("Before the first step").font(Theme.small).opacity(0.7)
                }
                ForEach(beside) { w in
                    line(w.name, store.snapshot?.summary(w) ?? "", copied: edit.copiedWalk(w)) { edit.copied = .walk(w) } remove: { edit.removeWalkStep(s.key, w.id) }
                        .padding(6).background(Theme.walkBar, in: .rect(cornerRadius: 6)).padding(.leading, 18)
                }
                if edit.copied != nil {
                    HStack(spacing: 14) {
                        if o != nil { Button("Paste as overview") { edit.pasteOverview(s.key, after: o?.id) }.buttonStyle(.borderless) }
                        if edit.hasWalk(s.key) { Button("Paste in walk") { edit.pasteWalk(s.key, block: o?.id) }.buttonStyle(.borderless) }
                    }
                    .font(Theme.small.weight(.bold))
                }
            }
            .foregroundStyle(.black)
            .listRowBackground(Theme.box)
        }
    }

    private func line(_ title: String, _ sub: String, copied: Bool, copy: @escaping () -> Void, remove: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title.isEmpty ? "Untitled" : title).font(Theme.small.weight(.bold))
                if !sub.isEmpty { Text(sub).font(Theme.label).opacity(0.75) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: copy) {
                Image(systemName: copied ? "doc.on.doc.fill" : "doc.on.doc").frame(width: 34, height: 34)
            }
            .buttonStyle(.borderless).accessibilityLabel("Copy")
            Button(action: remove) { Image(systemName: "xmark").frame(width: 34, height: 34) }
                .buttonStyle(.borderless).accessibilityLabel("Remove")
        }
    }
}

private extension ProcessEdit {
    func copiedOverview(_ o: ProcStep) -> Bool { if case .overview(let c) = copied { return c.id == o.id }; return false }
    func copiedWalk(_ w: StepEdit) -> Bool { if case .walk(let c) = copied { return c.id == w.id }; return false }
}

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
