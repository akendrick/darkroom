import SwiftUI
import QuickLook

// Stage revisions (the Processes plan): a stage's directions are changed in a
// draft revision, then published. Published revisions are never changed
// again, so the prints made from them still say exactly what was done. The
// same API the website's draft editor uses (darkroom-api.php?res=stage_revision).

enum Day {
    /// "2026-11-21 14:30:00" → "21 Nov 2026".
    static func short(_ s: String) -> String? {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: String(s.prefix(10))) else { return nil }
        return d.formatted(.dateTime.day().month(.abbreviated).year())
    }
}

private func errText(_ e: Error) -> String {
    if let e = e as? ServerError { return e.retry ? "Can't reach knotwork.ca — try again with a connection" : e.message }
    return e.localizedDescription
}

// MARK: Drafts and saving

extension AppStore {
    /// Fetches the drafts open on a process's stages: Edit and the editor show those.
    func loadDrafts(_ p: ProcessDoc) async {
        for s in p.sections {
            guard let sid = s.serverId else { continue }
            guard let d = s.draftId else { stageDrafts[sid] = nil; continue }
            do { stageDrafts[sid] = try await server.request("darkroom-api.php?res=stage_revision&id=\(d)") }
            catch { self.message = errText(error) }
        }
    }

    /// The process with each stage that has a draft showing the draft's directions.
    func editingDoc(_ p: ProcessDoc) -> ProcessDoc {
        var p = p
        p.sections = p.sections.map { s in
            guard let sid = s.serverId, let d = stageDrafts[sid], d["id"].int == s.draftId else { return s }
            return s.withDraft(d)
        }
        return p
    }

    /// A draft's walk, as the revision sent it (drafts aren't in the sync feed).
    func draftWalk(_ id: Int) -> JSON? {
        for d in stageDrafts.values { if let w = d["walks"].array.first(where: { $0["id"].int == id }) { return w } }
        return nil
    }

    /// Saves an edit. What isn't part of a revision changes at once: the
    /// process itself and its stages' titles, order and next stage; a new stage
    /// is sent whole and starts as Rev 1. A stage's directions (introduction,
    /// boxes, steps and its walk's steps) go into the stage's draft, made from
    /// the published revision the first time. Nothing is walked differently
    /// until the draft is published.
    func saveProcess(_ e: ProcessEdit) async throws {
        if e.shellChanged {
            let full = e.payload()
            var top = full.object
            top["sections"] = .array(zip(e.doc.sections, full["sections"].array).map { s, j in
                s.serverId == nil ? j : .object(["id": j["id"], "title": j["title"], "next_index": j["next_index"]])
            })
            _ = try await server.request("darkroom-api.php?res=process&id=\(e.doc.id)", method: "PATCH", body: .object(top))
        }
        for s in e.doc.sections {
            guard let sid = s.serverId, let o = e.original.sections.first(where: { $0.key == s.key }), e.directionsChanged(s, from: o) else { continue }
            let d: JSON
            if s.isDraft, let have = stageDrafts[sid] { d = have }
            else { d = try await server.request("darkroom-api.php?res=stage_revision&action=draft", method: "POST", body: .object(["section_id": .from(sid)])) }
            guard let rid = d["id"].int else { throw ServerError(message: "Server error", status: 500) }
            stageDrafts[sid] = try await server.request("darkroom-api.php?res=stage_revision&id=\(rid)", method: "PATCH", body: e.draftPayload(s, draft: d))
        }
        await refresh()
        if let p = snapshot?.process(e.doc.id) { await loadDrafts(p) }
    }

    func publishDraft(_ rid: Int, comments: String) async throws {
        let c = comments.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await server.request("darkroom-api.php?res=stage_revision&id=\(rid)&action=publish", method: "POST", body: .object(["comments": .from(c.isEmpty ? nil : c)]))
        stageDrafts = stageDrafts.filter { $0.value["id"].int != rid }
        await refresh()
    }

    func discardDraft(_ rid: Int) async throws {
        _ = try await server.request("darkroom-api.php?res=stage_revision&id=\(rid)", method: "DELETE")
        stageDrafts = stageDrafts.filter { $0.value["id"].int != rid }
        await refresh()
    }

    /// A new draft copied from an earlier revision, to go back to it.
    func draftFrom(stage sid: Int, revision rid: Int) async throws {
        stageDrafts[sid] = try await server.request("darkroom-api.php?res=stage_revision&action=draft", method: "POST",
                                                    body: .object(["section_id": .from(sid), "from_revision_id": .from(rid)]))
        await refresh()
    }

    func revisions(stage sid: Int) async throws -> [JSON] {
        try await server.request("darkroom-api.php?res=stage_revision&section_id=\(sid)").array
    }
    func revision(_ rid: Int) async throws -> JSON { try await server.request("darkroom-api.php?res=stage_revision&id=\(rid)") }
    /// What changed from `from` to revision `rid` ("current", or a revision id).
    func revisionDiff(_ rid: Int, from: String = "current") async throws -> JSON {
        try await server.request("darkroom-api.php?res=stage_revision&id=\(rid)&diff=\(from)")
    }
    func archiveRevision(_ rid: Int, _ on: Bool) async throws {
        _ = try await server.request("darkroom-api.php?res=stage_revision&id=\(rid)&action=\(on ? "archive" : "unarchive")", method: "POST", body: .object([:]))
    }

    /// One revision of a stage as a PDF.
    func revisionPdf(process: Int, stage: Int, revision: Int, title: String) async throws -> URL {
        let data = try await server.data("darkroom-process-pdf.php?id=\(process)&section=\(stage)&rev=\(revision)")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(title.replacingOccurrences(of: "/", with: "-") + ".pdf")
        try data.write(to: url)
        return url
    }
}

extension ProcessEdit {
    /// The process, or its list of stages (titles, order, next stage), changed.
    var shellChanged: Bool {
        func shell(_ d: ProcessDoc) -> [String] {
            [d.name, d.summary, "\(d.photoTypeId ?? 0)", "\(d.archived)"] + d.sections.map { "\($0.key)|\($0.title)|\($0.nextKey ?? "")" }
        }
        return shell(doc) != shell(original) || doc.sections.contains { $0.serverId == nil }
    }

    /// A stage's directions changed: what goes into its draft.
    func directionsChanged(_ s: ProcSection, from o: ProcSection) -> Bool {
        s.intro != o.intro || s.steps != o.steps || s.boxes != o.boxes || walks[s.key] != originalWalks[s.key] || newWalks[s.key] != nil
    }

    /// The PATCH for a stage's draft. Edited from the published revision, each
    /// row is sent as its copy in the draft (copied_from_id), so the change
    /// notes carry on from it. Every walk of the draft is sent, so none is
    /// taken out; only the one edited here sends its steps.
    func draftPayload(_ s: ProcSection, draft d: JSON) -> JSON {
        func copies(_ rows: [JSON]) -> [Int: Int] {
            Dictionary(rows.compactMap { r in r["copied_from_id"].int.flatMap { c in r["id"].int.map { (c, $0) } } }, uniquingKeysWith: { a, _ in a })
        }
        let dw = d["walks"].array
        let ins = copies(d["steps"].array), box = copies(d["boxes"].array), walk = copies(dw), step = copies(dw.flatMap { $0["steps"].array })
        func id(_ t: [Int: Int], _ v: Int?) -> Int? { v.flatMap { s.isDraft ? $0 : t[$0] } }
        let steps: [JSON] = s.steps.map { st in var o = st.payload().object; o["id"] = .from(id(ins, st.serverId)); return .object(o) }
        let boxes: [JSON] = s.boxes.map { b in var o = b.payload().object; o["id"] = .from(id(box, b.serverId)); return .object(o) }
        func walkSteps(_ list: [StepEdit]) -> JSON {
            .array(list.map { st in
                var p = st.payload(sameAsIndex: st.sameAs.flatMap { ref in list.firstIndex { $0.id == ref } }).object
                p["id"] = .from(id(step, st.serverId))
                p["instruction_index"] = .from(st.pairedBlock.flatMap { b in s.steps.firstIndex { $0.id == b } })
                return .object(p)
            })
        }
        let mine = id(walk, s.presetId)
        var ws: [JSON] = dw.map { w in
            var o: [String: JSON] = ["id": w["id"], "name": w["name"]]
            if let mine, w["id"].int == mine, let list = walks[s.key] { o["steps"] = walkSteps(list) }
            return .object(o)
        }
        if mine == nil, let n = newWalks[s.key], let list = walks[s.key] {
            var o = n.object; o["name"] = .string(s.title); o["steps"] = walkSteps(list)
            ws.append(.object(o))
        }
        return .object(["intro": .from(s.intro.isEmpty ? nil : s.intro), "steps": .array(steps), "boxes": .array(boxes), "walks": .array(ws)])
    }
}

// MARK: The draft bar on a stage

/// Shown on a stage with a draft open: look at it, publish it or discard it.
struct DraftBar: View {
    @Environment(AppStore.self) private var store
    let section: ProcSection
    @Binding var showDraft: Bool
    /// Edit is on: the draft is what's shown, whatever showDraft says.
    let editing: Bool
    @State private var publishing = false
    @State private var confirmDiscard = false

    var body: some View {
        if let rid = section.draftId {
            VStack(alignment: .leading, spacing: 8) {
                Text("REV \(section.draftRevNo ?? 0) DRAFT").font(Theme.label.weight(.bold)).tracking(1.5)
                Text(editing ? "Changes made here go into the draft. Walks keep using Rev \(section.revNo ?? 0) until it is published."
                             : "Not published yet: walks still use Rev \(section.revNo ?? 0).")
                    .font(Theme.small)
                HStack(spacing: 16) {
                    if !editing { Button(showDraft ? "Show published" : "Show draft") { Task { await toggle() } } }
                    Button("Publish…") { publishing = true }.bold()
                    Button("Discard", role: .destructive) { confirmDiscard = true }
                }
                .font(Theme.small.weight(.semibold))
            }
            .foregroundStyle(Theme.red)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.fill, in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.red, style: StrokeStyle(lineWidth: 1, dash: [5, 3])))
            .sheet(isPresented: $publishing) { PublishSheet(stage: section.title, revisionId: rid, revNo: section.draftRevNo ?? 0) }
            .confirmationDialog("Discard the Rev \(section.draftRevNo ?? 0) draft?", isPresented: $confirmDiscard, titleVisibility: .visible) {
                Button("Discard draft", role: .destructive) {
                    Task {
                        do { try await store.discardDraft(rid); showDraft = false } catch { store.message = errText(error) }
                    }
                }
            } message: { Text("Its changes are lost. Rev \(section.revNo ?? 0) stays as it is.") }
        }
    }

    private func toggle() async {
        if !showDraft, let sid = section.serverId, store.stageDrafts[sid] == nil,
           let p = store.snapshot?.processes.first(where: { $0.sections.contains { $0.serverId == sid } }) {
            await store.loadDrafts(p)
        }
        showDraft.toggle()
    }
}

/// What publishing will change, written for the change notes, and your comments.
struct PublishSheet: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let stage: String, revisionId: Int, revNo: Int
    @State private var notes: String?
    @State private var changes: [JSON] = []
    @State private var comments = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("\(stage) Rev \(revNo)".uppercased()).font(Theme.display(30))
                    Text("Publishing makes this the revision every new walk uses. Prints already made keep the revision they were made from.")
                        .font(Theme.small)
                    Text("CHANGE NOTES").font(Theme.label.weight(.bold)).tracking(1.5).foregroundStyle(Theme.bright)
                    if let notes { Text(notes.isEmpty ? "No changes to the directions." : notes).font(Theme.small) }
                    else { ProgressView().tint(Theme.red) }
                    ForEach(Array(changes.enumerated()), id: \.offset) { _, c in ChangeLine(change: c) }
                    Field(label: "Your comments (optional)") {
                        TextField("Why it changed, what to watch for", text: $comments, axis: .vertical).lineLimit(2...8)
                    }
                    if let error { Text(error).font(Theme.small).bold() }
                }
                .foregroundStyle(Theme.red)
                .padding(18)
            }
            .background(Theme.bg)
            .navigationTitle("Publish")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(busy ? "Publishing…" : "Publish") { publish() }.bold().disabled(busy)
                }
            }
            .task {
                do { let d = try await store.revisionDiff(revisionId); notes = d["notes"].string ?? ""; changes = d["changes"].array }
                catch { notes = ""; self.error = errText(error) }
            }
        }
        .tint(Theme.red)
    }

    private func publish() {
        busy = true; error = nil
        Task {
            do { try await store.publishDraft(revisionId, comments: comments); dismiss() } catch { self.error = errText(error) }
            busy = false
        }
    }
}

/// One change between two revisions: "Changed step: Pour — time 2:00 → 3:00".
private struct ChangeLine: View {
    let change: JSON
    var body: some View {
        let fields = change["fields"].array.map { f -> String in
            let a = f.array
            // Long text (directions, notes) is named but not quoted.
            let label = a.first?.string ?? ""
            guard a.count > 2, a[1] != .null || a[2] != .null else { return "\(label) changed" }
            return "\(label): \(a[1].string ?? "—") → \(a[2].string ?? "—")"
        }
        VStack(alignment: .leading, spacing: 2) {
            Text([(change["change"].string ?? "").capitalized, change["area"].string, change["name"].string.map { "“\($0)”" },
                  change["walk"].string.map { "in \($0)" }].compactMap { $0 }.joined(separator: " "))
                .font(Theme.small.weight(.bold))
            ForEach(fields, id: \.self) { Text($0).font(Theme.label) }
        }
        .padding(.leading, 8)
        .overlay(alignment: .leading) { Rectangle().fill(Theme.line).frame(width: 2) }
    }
}

// MARK: History

/// Every revision of a stage, newest first: what changed in each and why.
struct RevisionsView: View {
    @Environment(AppStore.self) private var store
    let processId: Int
    let stageId: Int
    @State private var list: [JSON]?
    @State private var error: String?

    private var stage: ProcSection? { store.snapshot?.process(processId)?.sections.first { $0.serverId == stageId } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text((stage?.title ?? "Stage").uppercased()).font(Theme.display(34))
                NavigationLink {
                    PrintSearchView(initial: PrintFilter(stageId: stageId), title: "Prints: \(stage?.title ?? "stage")")
                } label: { linkRow("Prints made from \(stage?.title ?? "this stage")", sub: "any revision") }
                if let error { Text(error).font(Theme.small) }
                if list == nil && error == nil { ProgressView().tint(Theme.red) }
                ForEach(list ?? [], id: \.self["id"].int) { r in
                    NavigationLink { RevisionDetail(processId: processId, stageId: stageId, revisionId: r["id"].int ?? 0) } label: { row(r) }
                        .buttonStyle(.plain)
                }
            }
            .foregroundStyle(Theme.red)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .navigationTitle("Revisions")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: store.snapshot?.fetchedAt) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        do { list = try await store.revisions(stage: stageId); error = nil } catch { self.error = errText(error) }
    }

    private func row(_ r: JSON) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rev \(r["rev_no"].int ?? 0)").font(Theme.display(24))
                Text(RevisionDetail.state(r).uppercased()).font(Theme.label).tracking(1.5).foregroundStyle(Theme.bright)
                Spacer()
                Text(r["published_at"].string.flatMap(Day.short) ?? "").font(Theme.label).foregroundStyle(Theme.dim)
                Image(systemName: "chevron.right").font(.footnote.weight(.bold))
            }
            if let n = r["change_notes"].string { Text(n).font(Theme.small).multilineTextAlignment(.leading) }
            if let c = r["comments"].string { Text("“\(c)”").font(Theme.small).italic().foregroundStyle(Theme.dim).multilineTextAlignment(.leading) }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(r["is_current"].flag ? Theme.fill : Theme.bg, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line, style: StrokeStyle(lineWidth: 1, dash: r["status"].string == "draft" ? [5, 3] : [])))
        .opacity(r["status"].string == "archived" ? 0.6 : 1)
    }
}

/// A link styled as a row: title, and a line under it.
@MainActor func linkRow(_ title: String, sub: String? = nil) -> some View {
    HStack {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Theme.body.weight(.bold)).multilineTextAlignment(.leading)
            if let sub { Text(sub).font(Theme.small).foregroundStyle(Theme.dim) }
        }
        Spacer()
        Image(systemName: "chevron.right").font(.body.weight(.bold))
    }
    .foregroundStyle(Theme.red)
    .padding(.vertical, 6)
}

/// One revision as it was published: its directions, the prints made from
/// it, what changed since, and archiving or going back to it.
struct RevisionDetail: View {
    @Environment(AppStore.self) private var store
    let processId: Int, stageId: Int, revisionId: Int
    @State private var rev: JSON?
    @State private var since: JSON?
    @State private var error: String?
    @State private var pdf: URL?
    @State private var busy = false

    static func state(_ r: JSON) -> String {
        if r["is_current"].flag { return "current" }
        return r["status"].string == "published" ? "earlier" : (r["status"].string ?? "")
    }
    private var stage: ProcSection? { store.snapshot?.process(processId)?.sections.first { $0.serverId == stageId } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let r = rev { content(r) } else if let error { Text(error).font(Theme.small) } else { ProgressView().tint(Theme.red) }
            }
            .foregroundStyle(Theme.red)
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Theme.bg)
        .navigationTitle("Rev \(rev?["rev_no"].int ?? 0)")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(busy ? "PDF…" : "PDF") { Task { await showPdf() } }.disabled(busy || rev == nil)
            }
        }
        .quickLookPreview($pdf)
        .task { await load() }
    }

    private func load() async {
        do {
            let r = try await store.revision(revisionId)
            rev = r
            // What changed between this one and the current one.
            if !r["is_current"].flag, r["status"].string != "draft", let cur = stage?.revisionId {
                since = try? await store.revisionDiff(cur, from: String(revisionId))
            }
        } catch { self.error = errText(error) }
    }

    private func showPdf() async {
        guard let r = rev else { return }
        busy = true
        do { pdf = try await store.revisionPdf(process: processId, stage: stageId, revision: revisionId, title: "\(r["stage_title"].string ?? "Stage") Rev \(r["rev_no"].int ?? 0)") }
        catch { self.error = errText(error) }
        busy = false
    }

    @ViewBuilder private func content(_ r: JSON) -> some View {
        let n = r["rev_no"].int ?? 0
        let title = r["stage_title"].string ?? stage?.title ?? "Stage"
        let draft = r["status"].string == "draft"
        Text("\(title) Rev \(n)".uppercased()).font(Theme.display(32))
        Text(([Self.state(r), r["published_at"].string.flatMap(Day.short).map { "published \($0)" },
               r["based_on_rev_no"].int.map { "from Rev \($0)" }] as [String?]).compactMap { $0 }.joined(separator: " · "))
            .font(Theme.label).tracking(1).foregroundStyle(Theme.bright)
        if let c = r["change_notes"].string { Text(c).font(Theme.small) }
        if let c = r["comments"].string { Text("“\(c)”").font(Theme.small).italic() }
        if !draft {
            NavigationLink { PrintSearchView(initial: PrintFilter(stageId: stageId, revisionId: revisionId), title: "Prints: \(title) Rev \(n)") }
                label: { linkRow("Prints made from \(title) Rev \(n)") }
        }
        if let since {
            Text("CHANGED SINCE, IN THE CURRENT REVISION").font(Theme.label.weight(.bold)).tracking(1.5).foregroundStyle(Theme.bright)
            let ch = since["changes"].array
            if ch.isEmpty { Text("Nothing in the directions.").font(Theme.small) }
            ForEach(Array(ch.enumerated()), id: \.offset) { _, c in ChangeLine(change: c) }
        }
        if !r["is_current"].flag && !draft {
            HStack(spacing: 18) {
                if stage?.draftId == nil {
                    Button("Start a draft from Rev \(n)") { act { try await store.draftFrom(stage: stageId, revision: revisionId) } }
                }
                let archived = r["status"].string == "archived"
                Button(archived ? "Unarchive" : "Archive") { act { try await store.archiveRevision(revisionId, !archived); await load() } }
            }
            .font(Theme.small.weight(.bold))
        }
        Divider().overlay(Theme.line)
        RevisionBody(rev: r)
    }

    private func act(_ run: @escaping () async throws -> Void) {
        Task { do { try await run(); error = nil } catch { self.error = errText(error) } }
    }
}

/// A revision's directions as they read: introduction, boxes, steps, and its walks.
struct RevisionBody: View {
    @Environment(AppStore.self) private var store
    let rev: JSON

    var body: some View {
        let s = ProcSection(title: "").withDraft(rev)
        VStack(alignment: .leading, spacing: 12) {
            if !s.intro.isEmpty { Text(s.intro).font(Theme.body) }
            ForEach(s.boxes) { BoxView(box: $0) }
            ForEach(Array(s.groups.enumerated()), id: \.offset) { _, g in
                if !g.title.isEmpty {
                    Text(g.title.uppercased()).font(Theme.label.weight(.bold)).tracking(2).foregroundStyle(Theme.onRed)
                        .padding(.horizontal, 10).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.red, in: .rect(cornerRadius: 4))
                }
                ForEach(g.steps, id: \.step.id) { n, st in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(n)").font(Theme.display(22)).frame(width: 28, alignment: .trailing)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(st.heading).font(Theme.body.weight(.bold))
                            if !st.chips.isEmpty { Text(st.chips).font(Theme.label).foregroundStyle(Theme.bright) }
                            if !st.detail.isEmpty { Text(st.detail).font(Theme.small) }
                        }
                    }
                }
            }
            ForEach(rev["walks"].array, id: \.self["id"].int) { w in
                VStack(alignment: .leading, spacing: 4) {
                    Text("WALK-THROUGH: \(w["name"].string ?? "")".uppercased()).font(Theme.label.weight(.bold)).tracking(1.5)
                    ForEach(Array(StepEdit.list(w).enumerated()), id: \.offset) { i, st in
                        Text("\(i + 1). \(st.name) — \(store.snapshot?.summary(st) ?? "")").font(Theme.small)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.walkBar, in: .rect(cornerRadius: 8))
                .foregroundStyle(Theme.darkroom ? Theme.red : .black)
            }
        }
    }
}

// MARK: Search

/// What the prints are searched by (darkroom-api.php?res=print_search). Filters combine.
struct PrintFilter: Equatable, Hashable {
    var processId: Int?, stageId: Int?, revisionId: Int?, pigmentId: Int?
    var words = ""

    var isEmpty: Bool { processId == nil && stageId == nil && revisionId == nil && pigmentId == nil && words.trimmingCharacters(in: .whitespaces).isEmpty }
    var query: String {
        var q = ""
        for (k, v) in [("process_id", processId), ("stage_id", stageId), ("revision_id", revisionId), ("pigment_id", pigmentId)] {
            if let v { q += "&\(k)=\(v)" }
        }
        let w = words.trimmingCharacters(in: .whitespaces)
        if !w.isEmpty, let e = w.addingPercentEncoding(withAllowedCharacters: .alphanumerics) { q += "&q=\(e)" }
        return q
    }
}

/// The filter lists: processes with their stages and published revisions, and pigments.
struct SearchOptions: Equatable {
    let processes: [JSON], pigments: [JSON]
    var stages: [JSON] { processes.flatMap { $0["stages"].array } }
    func process(_ id: Int?) -> JSON? { processes.first { $0["id"].int == id } }
    func stage(_ id: Int?) -> JSON? { stages.first { $0["id"].int == id } }
    func revisionLabel(_ id: Int?) -> String? {
        for s in stages { if let r = s["revisions"].array.first(where: { $0["id"].int == id }) { return "\(s["title"].string ?? "") Rev \(r["rev_no"].int ?? 0)" } }
        return nil
    }
}

extension AppStore {
    func searchOptions() async throws -> SearchOptions {
        let o = try await server.request("darkroom-api.php?res=print_search&options=1")
        return SearchOptions(processes: o["processes"].array, pigments: o["pigments"].array)
    }
    /// The matching prints' ids, newest first, each with why it matched.
    func searchPrints(_ f: PrintFilter) async throws -> [(id: Int, why: [String])] {
        try await server.request("darkroom-api.php?res=print_search" + f.query)["results"].array.compactMap { r in
            r["id"].int.map { ($0, r["why"].array.compactMap(\.string)) }
        }
    }
}

/// The search bar above the prints: words, then a menu each for Process,
/// Stage, revision and pigment.
struct PrintSearchBar: View {
    @Binding var filter: PrintFilter
    let options: SearchOptions?
    let count: Int?
    @State private var words = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass")
                TextField("Title, edition or notes", text: $words)
                    .submitLabel(.search).onSubmit { filter.words = words }
                    .foregroundStyle(.black)
                if !words.isEmpty { Button { words = ""; filter.words = "" } label: { Image(systemName: "xmark.circle.fill") }.accessibilityLabel("Clear words") }
            }
            .padding(10).background(Theme.box, in: .rect(cornerRadius: 8))
            ChipFlow {
                menu(options?.process(filter.processId)?["name"].string ?? "Any process", on: filter.processId != nil) {
                    Button("Any process") { filter.processId = nil; filter.stageId = nil; filter.revisionId = nil }
                    ForEach(options?.processes ?? [], id: \.self["id"].int) { p in
                        Button(p["name"].string ?? "") { filter.processId = p["id"].int; filter.stageId = nil; filter.revisionId = nil }
                    }
                }
                menu(options?.stage(filter.stageId)?["title"].string ?? "Any stage", on: filter.stageId != nil) {
                    Button("Any stage") { filter.stageId = nil; filter.revisionId = nil }
                    // Under their process: several have a Safety stage.
                    ForEach((options?.processes ?? []).filter { filter.processId == nil || $0["id"].int == filter.processId }, id: \.self["id"].int) { p in
                        Section(p["name"].string ?? "") {
                            ForEach(p["stages"].array, id: \.self["id"].int) { s in
                                Button(s["title"].string ?? "") { filter.stageId = s["id"].int; filter.revisionId = nil }
                            }
                        }
                    }
                }
                if let s = options?.stage(filter.stageId) {
                    menu(options?.revisionLabel(filter.revisionId).map { String($0.split(separator: " ").suffix(2).joined(separator: " ")) } ?? "Any revision", on: filter.revisionId != nil) {
                        Button("Any revision") { filter.revisionId = nil }
                        ForEach(s["revisions"].array, id: \.self["id"].int) { r in
                            Button("Rev \(r["rev_no"].int ?? 0)" + (r["status"].string == "archived" ? " (archived)" : "")) { filter.revisionId = r["id"].int }
                        }
                    }
                }
                menu(options?.pigments.first { $0["id"].int == filter.pigmentId }?["name"].string ?? "Any pigment", on: filter.pigmentId != nil) {
                    Button("Any pigment") { filter.pigmentId = nil }
                    ForEach(options?.pigments ?? [], id: \.self["id"].int) { p in Button(p["name"].string ?? "") { filter.pigmentId = p["id"].int } }
                }
            }
            if let count, !filter.isEmpty {
                HStack {
                    Text("\(count) print\(count == 1 ? "" : "s")").font(Theme.small.weight(.bold))
                    Spacer()
                    Button("Clear") { words = ""; filter = PrintFilter() }.font(Theme.small.weight(.bold))
                }
            }
        }
        .foregroundStyle(Theme.red)
        .onAppear { words = filter.words }
    }

    private func menu<C: View>(_ title: String, on: Bool, @ViewBuilder _ items: () -> C) -> some View {
        Menu { items() } label: {
            HStack(spacing: 4) { Text(title).lineLimit(1); Image(systemName: "chevron.down").font(.caption2.weight(.bold)) }
                .font(Theme.label.weight(.bold))
                .foregroundStyle(on ? Theme.onRed : Theme.red)
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(on ? Theme.red : Theme.bg, in: .rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Theme.red, lineWidth: 1))
        }
    }
}

/// Prints found from a stage or one of its revisions, as their own page.
struct PrintSearchView: View {
    let initial: PrintFilter
    let title: String
    var body: some View {
        ScrollView { PrintsGrid(initial: initial).padding(16) }
            .background(Theme.bg)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
    }
}
