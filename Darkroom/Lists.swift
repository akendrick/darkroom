import SwiftUI
import PhotosUI

/// The lists behind the walk-through, edited on the phone: chemistry,
/// tissues, papers, negatives and the names they're sorted by. Each one is
/// described by its fields, the same ones darkroom-api.php keeps, and read
/// and saved straight to the server (so these need a connection).
struct ListSpec: Identifiable, Hashable {
    /// stage: the Stage a batch or tissue was made from (its current revision is recorded).
    enum Kind: Hashable { case text, notes, number, whole, date, dateTime, flag, pick(String), links, stage
        /// A fixed set of words (Matte / Glossy). rating: a score from lo to hi, one tap, tap again to clear.
        case choice([String]), rating(Int, Int)
        /// A time typed as 2, 90s, 1:30 and kept in seconds (same rules as the web page).
        case duration
        /// 0-100 % on a slider (whole numbers); untouched means not recorded, and Clear puts it back.
        case percent
        /// The test's photos (main photo and others); needs the row to be saved first.
        case photos
        /// A sizing test's coats, each with its day and time; needs the row to be saved first.
        case coats
        /// The picked lane's recipe card and the source notes for it (read only).
        case laneNotes
        /// A test's prints from the gallery (kind "size" or "pigment"); needs the row to be saved first.
        case prints(String)
        /// A pigment test's pigments, each with grams and/or mL.
        case pigments
        /// A test's variant (letter, name, chosen mark) and Split into variants; needs the row to be saved first.
        case variant }
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
    /// A small picture for the row (a sizing test's main photo): a path on knotwork.ca.
    var rowImage: ((JSON) -> String?)? = nil
    /// A test list (Tests.swift): each row has the tried mark on the left and its main print on the right.
    var testKind: TestKind? = nil

    /// The new-row form's title: "New pigment test", "New chemistry batch", "New kind of print".
    var newTitle: String {
        var t = title
        if t.hasPrefix("Kinds of ") { t = "Kind of " + t.dropFirst(9) }
        else if t.hasSuffix("ches") { t = String(t.dropLast(2)) }
        else if t.hasSuffix("s") { t = String(t.dropLast()) }
        // Lower the first letter only when it starts a plain word (keeps "PVA test").
        if t.count > 1, t.dropFirst().first?.isLowercase == true { t = t.prefix(1).lowercased() + t.dropFirst() }
        return "New " + t
    }
    /// An existing row's form title, short enough to fit: a variant leads with its code and letter ("PVA1 · B").
    func editTitle(_ j: JSON) -> String {
        guard let v = j["variant"].string else { return rowTitle(j) }
        if let c = j["code"].string { return "\(c) · \(v)" }
        return "\(v) · \(rowTitle(j))"
    }

    /// The API resource: the id up to any ":" ("material:3" → material).
    var resource: String { String(id.split(separator: ":").first ?? "") }

    static func == (a: ListSpec, b: ListSpec) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static let all: [ListSpec] = [
        ListSpec(id: "chemistry", title: "Chemistry batches", fields: [
            .init(key: "label", label: "Label", kind: .text),
            .init(key: "type_id", label: "Type", kind: .pick("chemistry_types")),
            .init(key: "stage_id", label: "Stage it was made from", kind: .stage),
            .init(key: "date_created", label: "Made", kind: .date),
            .init(key: "percent_solution", label: "Strength %", kind: .number),
            .init(key: "volume_ml", label: "Volume ml", kind: .number),
            .init(key: "mixed_at", label: "Mixed at", kind: .dateTime),
            .init(key: "use_within_min", label: "Use within (min)", kind: .whole),
            .init(key: "links", label: "Made from", kind: .links),
            .init(key: "notes", label: "Notes", kind: .notes),
        ], required: ["date_created"], archives: true,
           rowTitle: { chemLabel($0) }, rowSub: { [$0["date_created"].string, $0["rev_label"].string, $0["sheets_used"].int.map { "\($0) used" }].compactMap { $0 }.joined(separator: " · ") }),
        ListSpec(id: "carbon_tissue", title: "Carbon tissue", fields: [
            .init(key: "title_id", label: "Name", kind: .text),
            .init(key: "date_poured", label: "Poured", kind: .date),
            .init(key: "size", label: "Size", kind: .text),
            .init(key: "chemistry_id", label: "Glop batch", kind: .pick("chemistry")),
            .init(key: "stage_id", label: "Stage it was made from", kind: .stage),
            .init(key: "amount_poured", label: "Amount poured", kind: .text),
            .init(key: "finish", label: "Matte or glossy", kind: .choice(["Matte", "Glossy"])),
            .init(key: "curl_mm", label: "Curl: corner lift mm", kind: .number),
            .init(key: "curl_score", label: "Curl 1-5 (5 = flat)", kind: .rating(1, 5)),
            .init(key: "links", label: "Made from", kind: .links),
            .init(key: "notes", label: "Notes", kind: .notes),
        ], required: ["date_poured"], archives: true,
           rowTitle: { Material(what: .carbon_tissue, row: $0).label },
           rowSub: { j in [Material(what: .carbon_tissue, row: j).sub, j["rev_label"].string, LinkRow.summary(j["links"].array).map { "from " + $0 }].compactMap { $0 }.joined(separator: " · ") }),
        ListSpec(id: "support_paper", title: "Support papers", fields: [
            .init(key: "mark", label: "Mark", kind: .text),
            .init(key: "paper_id", label: "Paper", kind: .pick("paper")),
            .init(key: "treatment_chemistry_id", label: "Treated with", kind: .pick("chemistry")),
            .init(key: "links", label: "Made from", kind: .links),
            .init(key: "notes", label: "Notes", kind: .notes),
        ], required: ["paper_id"], archives: true,
           rowTitle: { Material(what: .support_paper, row: $0).label }, rowSub: { $0["treatment_label"].string }),
        ListSpec(id: "size_test", title: "Sizing tests", fields: [
            .init(key: "tried", label: "It has been tried", kind: .flag),
            .init(key: "lane_id", label: "Lane", kind: .pick("size_lane")),
            .init(key: "support_paper_id", label: "Sample sheet", kind: .pick("support_paper")),
            .init(key: "retention_pct", label: "Image retention %", kind: .percent),
            .init(key: "frilling", label: "Frilling / lifting", kind: .choice(["None", "Minor", "Moderate", "Failed"])),
            .init(key: "highlight_colour", label: "Staining 0-3", kind: .rating(0, 3)),
            .init(key: "score_display", label: "Image display 1-5", kind: .rating(1, 5)),
            .init(key: "score_density", label: "Density 1-5", kind: .rating(1, 5)),
            .init(key: "score_surface", label: "Surface texture 0-5", kind: .rating(0, 5)),
            .init(key: "gloss", label: "Gloss", kind: .choice(["Matte", "Satin", "Gloss"])),
            .init(key: "measured_display", label: "Steps visible (optional)", kind: .number),
            .init(key: "carbon_tissue_id", label: "Tissue used", kind: .pick("carbon_tissue")),
            .init(key: "sized_on", label: "Sized", kind: .date),
            .init(key: "coats", label: "Coats", kind: .whole),
            .init(key: "sheet_w_cm", label: "Sheet width, cm", kind: .number),
            .init(key: "sheet_h_cm", label: "Sheet height, cm", kind: .number),
            .init(key: "coat_list", label: "Coats: the day, time and mL of each layer", kind: .coats),
            .init(key: "actual_dose", label: "Actual mix / dose used", kind: .text),
            .init(key: "cure_start", label: "Cure start", kind: .date),
            .init(key: "printed_on", label: "Print date", kind: .date),
            .init(key: "presoak_seconds", label: "Pre-soak, support alone (e.g. 2 or 90s)", kind: .duration),
            .init(key: "mating_seconds", label: "Mating soak, support + tissue (e.g. 45s)", kind: .duration),
            .init(key: "water_temp_c", label: "Water temperature °C", kind: .number),
            .init(key: "rescored_on", label: "Re-scored on", kind: .date),
            .init(key: "rescore_retention_pct", label: "Re-score retention %", kind: .percent),
            .init(key: "rescore_highlight_colour", label: "Re-score staining 0-3", kind: .rating(0, 3)),
            .init(key: "variant", label: "Variants", kind: .variant),
            .init(key: "prints", label: "Prints from the gallery (the outlined one is the main print; press and hold to change)", kind: .prints("size")),
            .init(key: "photos", label: "Other photos of the test", kind: .photos),
            .init(key: "notes", label: "Notes", kind: .notes),
            .init(key: "lane_directions", label: "Lane directions (for reference)", kind: .laneNotes),
        ], required: ["lane_id", "support_paper_id"], archives: false,
           rowTitle: { [$0["code"].string, $0["lane"].string].compactMap { $0 }.joined(separator: " ") },
           rowSub: { j in
               [j["weighted_score"].double.map { "score \(Amount.format($0))" }, j["result"].string,
                j["retention_pct"].double.map { "\(Amount.format($0))% kept" },
                j["presoak_seconds"].int.map { "pre \(Duration.format($0))" }, j["mating_seconds"].int.map { "mating \(Duration.format($0))" },
                j["water_temp_c"].double.map { "\(Amount.format($0)) °C" },
                j["print_count"].int.flatMap { $0 > 1 ? "\($0) prints" : nil },
                j["image_count"].int.flatMap { $0 > 0 ? "\($0) photo\($0 == 1 ? "" : "s")" : nil }].compactMap { $0 }.joined(separator: " · ") },
           rowImage: { $0["main_thumb"].string }, testKind: .size),
        ListSpec(id: "pigment_test", title: "Pigment tests", fields: [
            .init(key: "tried", label: "It has been tried", kind: .flag),
            .init(key: "tried_on", label: "Tried on", kind: .date),
            .init(key: "code", label: "Code (PT9)", kind: .text),
            .init(key: "name", label: "What is being tested", kind: .text),
            .init(key: "chemistry_id", label: "Glop batch", kind: .pick("chemistry")),
            .init(key: "carbon_tissue_id", label: "Tissue", kind: .pick("carbon_tissue")),
            .init(key: "pigments", label: "Pigments: amount of each", kind: .pigments),
            .init(key: "gelatin_ml", label: "Gelatin solution mL", kind: .number),
            .init(key: "antifloc", label: "Anti-flocculant (empty if none)", kind: .text),
            .init(key: "antifloc_amount", label: "Anti-flocculant amount", kind: .number),
            .init(key: "antifloc_unit", label: "Anti-flocculant unit", kind: .choice(["mL", "drops", "g"])),
            .init(key: "exposure_seconds", label: "Exposure (e.g. 3 or 180s)", kind: .duration),
            .init(key: "dmax", label: "Black density (Dmax) 1-5", kind: .rating(1, 5)),
            .init(key: "dmax_measured", label: "Measured density (optional)", kind: .number),
            .init(key: "highlight", label: "Highlight separation 1-5", kind: .rating(1, 5)),
            .init(key: "tone", label: "Colour / tone 1-5", kind: .rating(1, 5)),
            .init(key: "staining", label: "Staining / clearing 1-5", kind: .rating(1, 5)),
            .init(key: "gloss", label: "Glossy to matte 0-5", kind: .rating(0, 5)),
            .init(key: "warmth", label: "Warm or cool black 0-5", kind: .rating(0, 5)),
            .init(key: "secondary_colour", label: "Secondary colour", kind: .choice(["None", "Blue", "Red", "Purple", "Green", "Brown", "Other"])),
            .init(key: "secondary_note", label: "Secondary colour note", kind: .text),
            .init(key: "curl", label: "Tissue curl", kind: .choice(["None", "Some", "Lots"])),
            .init(key: "flagging", label: "Tissue flagging 0-5", kind: .rating(0, 5)),
            .init(key: "sensitivity", label: "Tissue sensitivity 1-5", kind: .rating(1, 5)),
            .init(key: "variant", label: "Variants", kind: .variant),
            .init(key: "prints", label: "Prints from the gallery (the outlined one is the main print; press and hold to change)", kind: .prints("pigment")),
            .init(key: "notes", label: "Notes", kind: .notes),
        ], required: [], archives: true,
           rowTitle: { pigmentTestLabel($0) },
           rowSub: { j in
               [j["pigment_summary"].string,
                j["antifloc"].string.map { a in [a, j["antifloc_amount"].double.map { Amount.format($0) }, j["antifloc_unit"].string].compactMap { $0 }.joined(separator: " ") },
                pigmentScores(j),
                j["print_count"].int.flatMap { $0 > 1 ? "\($0) prints" : nil }].compactMap { $0 }.joined(separator: " · ") },
           rowImage: { $0["main_thumb"].string }, testKind: .pigment),
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
            .init(key: "links", label: "Made from", kind: .links),
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
                 required: ["name"], archives: true, rowTitle: { $0["name"].string ?? "" }, rowSub: { _ in nil }),
        ListSpec(id: "bath_type", title: "Bath types", fields: [.init(key: "name", label: "Name", kind: .text)],
                 required: ["name"], archives: true, rowTitle: { $0["name"].string ?? "" }, rowSub: { _ in nil }),
        ListSpec(id: "negative_types", title: "Negative types", fields: [.init(key: "name", label: "Name", kind: .text)],
                 required: ["name"], archives: true, rowTitle: { $0["name"].string ?? "" }, rowSub: { _ in nil }),
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
            .init(key: "on_hand", label: "On hand", kind: .number),
            .init(key: "unit", label: "Unit (sheets, g, mL)", kind: .text),
            .init(key: "acquired_on", label: "Acquired", kind: .date),
            .init(key: "links", label: "Made from", kind: .links),
            .init(key: "notes", label: "Notes", kind: .notes),
        ], required: ["label"], archives: true,
           rowTitle: { $0["label"].string ?? "" },
           rowSub: { j in
               let stock = j["on_hand"].double.map { Amount.format($0) + (j["unit"].string.map { " " + $0 } ?? "") + " on hand" }
               return [stock, j["maker"].string, LinkRow.summary(j["links"].array).map { "from " + $0 }, j["notes"].string]
                   .compactMap { $0 }.joined(separator: " · ")
           },
           fixed: ["kind_id": .from(k.id)], listRes: "material&kind_id=\(k.id)")
    }

    /// A kind of test the owner made up (test_kind with its fields): its tests' list and form.
    /// Each field is f_<id> in the row and the body; result fields start empty in a new variant.
    static func custom(_ k: JSON) -> ListSpec {
        let kid = k["id"].int ?? 0
        var fields: [Field] = [
            .init(key: "tried", label: "It has been tried", kind: .flag),
            .init(key: "tried_on", label: "Tried on", kind: .date),
            .init(key: "code", label: "Code", kind: .text),
            .init(key: "name", label: "What is being tested", kind: .text),
        ]
        for f in k["fields"].array {
            guard let id = f["id"].int else { continue }
            let lo = f["lo"].int ?? 1, hi = f["hi"].int ?? 5
            let kind: Kind = switch f["type"].string {
            case "whole": .whole
            case "text": .text
            case "notes": .notes
            case "choice": .choice(f["options"].array.compactMap(\.string))
            case "score": .rating(lo, hi)
            case "flag": .flag
            case "date": .date
            case "duration": .duration
            case "pick": .pick(f["options"].string ?? "pigment")
            default: .number
            }
            var label = f["name"].string ?? "Field"
            if f["type"].string == "score" { label += " \(lo)-\(hi)" }
            if let u = f["unit"].string, ["number", "whole"].contains(f["type"].string ?? "") { label += " (\(u))" }
            if f["type"].string == "duration" { label += " (e.g. 90s or 1:30)" }
            if f["is_result"].flag { label += " · result" }
            fields.append(.init(key: "f_\(id)", label: label, kind: kind))
        }
        fields += [
            .init(key: "notes", label: "Notes", kind: .notes),
            .init(key: "variant", label: "Variants", kind: .variant),
            .init(key: "prints", label: "Prints from the gallery (the outlined one is the main print; press and hold to change)", kind: .prints("custom")),
        ]
        return ListSpec(id: "custom_test:\(kid)", title: k["name"].string ?? "Tests", fields: fields, required: [], archives: true,
            rowTitle: { j in
                let s = [j["code"].string, j["name"].string].compactMap { $0 }.joined(separator: " ")
                return s.isEmpty ? "Test #\(j["id"].int ?? 0)" : s
            },
            rowSub: { j in
                let s = [j["setup"].string, j["results"].string, j["print_count"].int.flatMap { $0 > 1 ? "\($0) prints" : nil }]
                    .compactMap { $0 }.joined(separator: " · ")
                return s.isEmpty ? nil : s
            },
            fixed: ["test_kind_id": .from(kid)], listRes: "custom_test&kind_id=\(kid)", rowImage: { $0["main_thumb"].string }, testKind: .custom)
    }

    /// "PT6 Black Velvet India ink…", or the tissue, or its number.
    static func pigmentTestLabel(_ j: JSON) -> String {
        let s = [j["code"].string, j["name"].string].compactMap { $0 }.joined(separator: " ")
        return s.isEmpty ? (j["tissue"].string ?? "Pigment test #\(j["id"].int ?? 0)") : s
    }
    /// What was scored on a pigment test, shortest first: "Dmax 4 · tone 5 · curl Some".
    static func pigmentScores(_ j: JSON) -> String? {
        let parts: [String?] = [
            j["dmax"].int.map { "Dmax \($0)" }, j["highlight"].int.map { "highlights \($0)" }, j["tone"].int.map { "tone \($0)" },
            j["staining"].int.map { "staining \($0)" }, j["gloss"].int.map { "gloss→matte \($0)" }, j["warmth"].int.map { "cool→warm \($0)" },
            j["flagging"].int.map { "flagging \($0)" }, j["sensitivity"].int.map { "sensitivity \($0)" },
            j["curl"].string.map { "curl \($0)" }, j["secondary_colour"].string.map { "2nd colour \($0)" }]
        let s = parts.compactMap { $0 }.joined(separator: " · ")
        return s.isEmpty ? nil : s
    }

    static func chemLabel(_ j: JSON) -> String {
        j["label"].string ?? [j["type_name"].string ?? "Batch", j["date_created"].string].compactMap { $0 }.joined(separator: " ")
    }
    /// How a row of a pick list is named.
    static func optionLabel(_ source: String, _ j: JSON) -> String {
        switch source {
        case "chemistry": chemLabel(j)
        case "paper": Paper(j).name
        case "size_lane": [j["code"].string, j["name"].string].compactMap { $0 }.joined(separator: " ")
        case "support_paper": Material(what: .support_paper, row: j).label
        case "carbon_tissue": Material(what: .carbon_tissue, row: j).label
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
    func deleteRow(_ res: String, id: Int) async throws {
        _ = try await server.request("darkroom-api.php?res=\(res)&id=\(id)", method: "DELETE", body: nil)
        await refresh()
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

/// A list's rows and what swiping does to them.
@MainActor @Observable
final class RowsModel {
    let spec: ListSpec
    var rows: [JSON] = []
    var error: String?
    var showHidden = false
    var confirmDelete: JSON?

    init(_ spec: ListSpec) { self.spec = spec }

    func isHidden(_ r: JSON) -> Bool { r["archived"].flag }

    func load(_ store: AppStore) async {
        do { rows = try await store.list((spec.listRes ?? spec.resource) + (showHidden ? "&all=1" : "")); error = nil }
        catch let e as ServerError { error = e.retry ? "Can't reach knotwork.ca — lists need a connection" : e.message }
        catch { self.error = error.localizedDescription }
    }

    func setHidden(_ r: JSON, _ on: Bool, _ store: AppStore) async {
        guard let id = r["id"].int else { return }
        do { try await store.saveRow(spec.resource, id: id, .object(["archived": .from(on ? 1 : 0)])); await load(store) }
        catch let e as ServerError { error = e.retry ? "Can't reach knotwork.ca — try again with a connection" : e.message }
        catch { self.error = error.localizedDescription }
    }

    func delete(_ r: JSON, _ store: AppStore) async {
        guard let id = r["id"].int else { return }
        do { try await store.deleteRow(spec.resource, id: id); await load(store) }
        catch let e as ServerError { error = e.retry ? "Can't reach knotwork.ca — try again with a connection" : "\(spec.rowTitle(r)) is in use, so it can't be deleted. Swipe right to hide it." }
        catch { self.error = error.localizedDescription }
    }

    /// The tried mark: on dates it today (the server does), off clears the date.
    func setTried(_ r: JSON, _ on: Bool, _ store: AppStore) async {
        guard let id = r["id"].int else { return }
        if let i = rows.firstIndex(where: { $0["id"].int == id }) {     // show it straight away
            var o = rows[i].object; o["tried"] = .from(on ? 1 : 0); rows[i] = .object(o)
        }
        let body: JSON = on ? .object(["tried": 1]) : .object(["tried": 0, "tried_on": .null])
        do { _ = try await store.server.request("darkroom-api.php?res=\(spec.resource)&id=\(id)", method: "PATCH", body: body); error = nil }
        catch let e as ServerError { error = e.retry ? "Can't reach knotwork.ca — try again with a connection" : e.message }
        catch { self.error = error.localizedDescription }
        await load(store)
    }

    func sub(_ r: JSON) -> String? {
        let s = [isHidden(r) ? "Hidden" : nil, spec.rowSub(r)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return s.isEmpty ? nil : s
    }
}

private extension View {
    func confirmsDelete(_ m: RowsModel, _ store: AppStore) -> some View {
        confirmationDialog("Delete this for good?", isPresented: Binding(get: { m.confirmDelete != nil }, set: { if !$0 { m.confirmDelete = nil } }), titleVisibility: .visible, presenting: m.confirmDelete) { r in
            Button("Delete", role: .destructive) { Task { await m.delete(r, store) } }
        } message: { r in Text(m.spec.rowTitle(r)) }
    }
}

/// One list's rows. Swipe left to delete, right to hide.
struct RowsView: View {
    @Environment(AppStore.self) private var store
    let spec: ListSpec
    @State private var model: RowsModel
    @State private var search = ""
    @State private var editing: JSON?
    @State private var adding = false
    /// A test's main print, opened from its thumbnail.
    @State private var openPrint: Int?

    /// Opens a row by its id once the form that made it has closed (a new variant).
    private func open(_ id: Int) async {
        try? await Task.sleep(for: .milliseconds(500))
        if let r = try? await store.server.request("darkroom-api.php?res=\(spec.resource)&id=\(id)") { editing = r }
    }

    init(spec: ListSpec) { self.spec = spec; _model = State(initialValue: RowsModel(spec)) }

    private var shown: [JSON] {
        guard !search.isEmpty else { return model.rows }
        return model.rows.filter { (spec.rowTitle($0) + " " + (spec.rowSub($0) ?? "")).localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if let error = model.error { Text(error).font(Theme.small).listRowBackground(Theme.bg) }
            ForEach(shown, id: \.self["id"].int) { r in
                if spec.testKind != nil { testRow(r) } else {
                Button { editing = r } label: {
                    HStack(spacing: 10) {
                        if let path = spec.rowImage?(r), let url = URL(string: path, relativeTo: store.server.base) {
                            AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Theme.line }
                                .frame(width: 52, height: 52).clipShape(.rect(cornerRadius: 5))
                                .accessibilityLabel("Main photo")
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(spec.rowTitle(r)).font(Theme.body.weight(.bold))
                            if let s = model.sub(r) { Text(s).font(Theme.small).foregroundStyle(Theme.subOnBox) }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(model.isHidden(r) ? 0.5 : 1)
                }
                .listRowBackground(Theme.box).foregroundStyle(.black)
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("DELETE") { model.confirmDelete = r }.tint(Theme.red)
                }
                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                    if spec.archives {
                        Button(model.isHidden(r) ? "SHOW" : "HIDE") { Task { await model.setHidden(r, !model.isHidden(r), store) } }.tint(Theme.dim)
                    }
                }
                }
            }
        }
        .navigationDestination(item: $openPrint) { PrintByID(id: $0) }
        .searchable(text: $search)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle(spec.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if spec.archives {
                ToolbarItem(placement: .primaryAction) {
                    Button(model.showHidden ? "Leave out hidden" : "Show hidden", systemImage: model.showHidden ? "eye.fill" : "eye.slash") {
                        model.showHidden.toggle(); Task { await model.load(store) }
                    }
                }
            }
            ToolbarItem(placement: .primaryAction) { Button("Add", systemImage: "plus") { adding = true } }
        }
        .homeBulb()
        .refreshable { await model.load(store) }
        .task { await model.load(store) }
        .confirmsDelete(model, store)
        .sheet(item: Binding(get: { editing.map(Wrapped.init) }, set: { editing = $0?.row })) { w in
            RowForm(spec: spec, row: w.row, saved: { await model.load(store) }, openRow: { id in Task { await open(id) } })
        }
        .sheet(isPresented: $adding) { RowForm(spec: spec, row: nil) { await model.load(store) } }
    }
}

extension RowsView {
    /// A test's row: tried mark on the left, the test in the middle (tap to edit), its main print on the right (tap to open the print).
    /// A variant (B, C …) sits indented under the test it was split from, which shows its own letter (A) under its title.
    @ViewBuilder func testRow(_ r: JSON) -> some View {
        let child = r["parent_id"].int != nil
        HStack(spacing: 8) {
            TriedButton(on: r["tried"].flag) { Task { await model.setTried(r, !r["tried"].flag, store) } }
            if child {
                Image(systemName: "arrow.turn.down.right").font(.footnote.weight(.bold)).foregroundStyle(Theme.subOnBox)
                    .accessibilityHidden(true)
            }
            Button { editing = r } label: {
                VStack(alignment: .leading, spacing: 2) {
                    if child { VariantLine(row: r) } else {
                        Text(spec.rowTitle(r)).font(Theme.body.weight(.bold)).multilineTextAlignment(.leading)
                        if r["variant"].string != nil { VariantLine(row: r) }
                    }
                    if let s = model.sub(r) { Text(s).font(Theme.small).foregroundStyle(Theme.subOnBox).multilineTextAlignment(.leading) }
                    if r["tried"].flag, let d = r["tried_on"].string { Text("tried \(d)").font(.caption2).foregroundStyle(Theme.subOnBox) }
                }
                .frame(maxWidth: .infinity, alignment: .leading).contentShape(.rect)
            }
            .buttonStyle(.plain)
            if let path = spec.rowImage?(r), let url = URL(string: path, relativeTo: store.server.base) {
                Button {
                    if let pid = r["main_photo_id"].int { openPrint = pid } else { editing = r }
                } label: {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Theme.line }
                        .frame(width: 56, height: 56).clipShape(.rect(cornerRadius: 5))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(r["main_photo_id"].int != nil ? "Open the main print" : "Main photo")
            }
        }
        .opacity(model.isHidden(r) ? 0.5 : 1)
        .listRowBackground(Theme.box).foregroundStyle(.black)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button("DELETE") { model.confirmDelete = r }.tint(Theme.red)
        }
        .swipeActions(edge: .leading, allowsFullSwipe: false) {
            if spec.archives {
                Button(model.isHidden(r) ? "SHOW" : "HIDE") { Task { await model.setHidden(r, !model.isHidden(r), store) } }.tint(Theme.dim)
            }
        }
    }
}

/// A list laid straight into a page, in the look of the Process list.
struct InlineRows: View {
    @Environment(AppStore.self) private var store
    let spec: ListSpec
    @Binding var adding: Bool
    @State private var model: RowsModel
    @State private var editing: JSON?
    @State private var swiped: Int?

    init(spec: ListSpec, adding: Binding<Bool>) { self.spec = spec; _adding = adding; _model = State(initialValue: RowsModel(spec)) }

    var body: some View {
        VStack(spacing: 8) {
            if let error = model.error { Text(error).font(Theme.small).foregroundStyle(Theme.red) }
            ForEach(model.rows, id: \.self["id"].int) { r in
                SwipeRow(id: r["id"].int ?? 0, open: $swiped, hide: spec.archives ? (model.isHidden(r) ? "SHOW" : "HIDE") : nil) {
                    editing = r
                } onHide: {
                    Task { await model.setHidden(r, !model.isHidden(r), store) }
                } onDelete: {
                    model.confirmDelete = r
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(spec.rowTitle(r)).lineLimit(2).multilineTextAlignment(.leading)
                        if let s = model.sub(r) { Text(s).font(Theme.small).opacity(0.75) }
                    }
                    .opacity(model.isHidden(r) ? 0.55 : 1)
                }
            }
            if spec.archives {
                Button(model.showHidden ? "Leave out hidden" : "Show hidden") {
                    model.showHidden.toggle(); Task { await model.load(store) }
                }
                .font(Theme.small.weight(.bold)).foregroundStyle(Theme.red).frame(minHeight: 36)
            }
        }
        .task(id: store.snapshot?.fetchedAt) { await model.load(store) }
        .confirmsDelete(model, store)
        .sheet(item: Binding(get: { editing.map(Wrapped.init) }, set: { editing = $0?.row })) { w in
            RowForm(spec: spec, row: w.row) { await model.load(store) }
        }
        .sheet(isPresented: $adding) { RowForm(spec: spec, row: nil) { await model.load(store) } }
    }
}

/// A bar that slides sideways to show Delete (swipe left) and Hide (swipe right).
private struct SwipeRow<Label: View>: View {
    let id: Int
    @Binding var open: Int?
    let hide: String?
    let onTap: () -> Void
    let onHide: () -> Void
    let onDelete: () -> Void
    @ViewBuilder var label: Label
    @State private var drag: CGFloat = 0
    @State private var side: CGFloat = 0
    private let reach: CGFloat = 92

    private var offset: CGFloat { (open == id ? side * reach : 0) + drag }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                if offset > 0, let hide {
                    action(hide, Theme.dim) { close(); onHide() }
                }
                Spacer(minLength: 0)
                if offset < 0 {
                    action("DELETE", Theme.red) { close(); onDelete() }
                }
            }
            label
                .font(Theme.body.weight(.bold))
                .foregroundStyle(Theme.procText)
                .padding(.horizontal, 14).padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                .background(Theme.procBar, in: .rect(cornerRadius: 10))
                .contentShape(.rect)
                .offset(x: offset)
                .onTapGesture { if open == id { close() } else { open = nil; onTap() } }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .onChanged { v in
                        guard abs(v.translation.width) > abs(v.translation.height) else { return }
                        let w = v.translation.width
                        drag = hide == nil && w > 0 && open != id ? 0 : w
                    }
                    .onEnded { v in
                        let w = v.translation.width
                        withAnimation(.snappy) {
                            drag = 0
                            guard abs(w) > abs(v.translation.height) else { return }
                            if open == id { if (w > 0) != (side > 0) && abs(w) > 30 { open = nil } }
                            else if w < -44 { side = -1; open = id }
                            else if w > 44, hide != nil { side = 1; open = id }
                        }
                    }
            )
        }
        .clipShape(.rect(cornerRadius: 10))
    }

    private func close() { withAnimation(.snappy) { open = nil } }

    private func action(_ title: String, _ fill: Color, _ run: @escaping () -> Void) -> some View {
        Button(title, action: run)
            .font(Theme.small.weight(.heavy)).foregroundStyle(Theme.onRed)
            .frame(width: reach).frame(maxHeight: .infinity)
            .background(fill)
    }
}

/// Behind Chemistry's gear: the names its lists are sorted by.
struct ChemistrySettings: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(["chemistry_types", "bath_type"], id: \.self) { id in
                        let spec = ListSpec.of(id)
                        NavigationLink { RowsView(spec: spec) } label: {
                            HStack { Text(spec.title); Spacer(); Image(systemName: "chevron.right") }
                        }
                        .buttonStyle(TreeRowStyle(fill: Theme.procBar, text: Theme.procText))
                    }
                }
                .padding(20)
            }
            .background(Theme.bg)
            .navigationTitle("Chemistry options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .tint(Theme.red)
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
    /// After Split into variants: opens the new variant (the list's own sheet).
    var openRow: ((Int) -> Void)? = nil
    @State private var values: [String: JSON] = [:]
    @State private var splitting = false
    @State private var options: [String: [JSON]] = [:]
    /// What each score means, shown under its buttons: the 0-3 highlight key is fixed;
    /// the 1-5 scores are read from the server's anchors (size_criterion) so editing them there changes the app.
    @State private var scoreKey: [String: [String]] = {
        let colour = ["0  clean paper white", "1  faint tint, only just visible", "2  noticeable tint", "3  strong stain or veil"]
        return ["highlight_colour": colour, "rescore_highlight_colour": colour,
                "score_surface": ["0  smooth", "5  highly textured"],
                // pigment tests
                "gloss": ["0  glossy", "5  matte"], "warmth": ["0  coolest black", "5  warmest black"],
                "flagging": ["0  none", "5  extreme"], "sensitivity": ["1  slow", "5  very fast"],
                "tone": ["how much you like the colour"], "staining": ["1  heavy stain", "5  clears clean"]]
    }()
    private static let scoreCodes = ["score_display": ("support", "display"), "score_density": ("support", "density"),
                                     "curl_score": ("tissue", "curl")]
    /// The "Made from" rows, kept apart from values so typing in them keeps focus.
    @State private var links: [LinkRow] = []
    /// A pigment test's pigments, kept apart from values like links.
    @State private var pigs: [PigmentAmount] = []
    @State private var busy = false
    @State private var error: String?
    @State private var confirmArchive = false
    /// The stage the row says it was made from, so it is sent only when changed.
    @State private var originalStage: Int?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    // "Tried on" only shows once the test is marked tried.
                    ForEach(spec.fields.filter { $0.key != "tried_on" || values["tried"]?.flag == true }, id: \.key) { f in field(f) }
                    if let error { Text(error).font(Theme.small).foregroundStyle(Theme.red) }
                    if row != nil && spec.archives {
                        Button("Remove from lists", role: .destructive) { confirmArchive = true }
                            .font(Theme.body.weight(.bold)).padding(.top, 10)
                    }
                }
                .padding(18)
            }
            .background(Theme.bg)
            .navigationTitle(row == nil ? spec.newTitle : spec.editTitle(row!))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button(busy ? "Saving…" : "Save") { save() }.bold().disabled(busy) }
            }
            .sheet(isPresented: $splitting) {
                if let row, let kind = spec.testKind {
                    VariantSplitSheet(kind: kind, row: row) { a, b, sheet in await split(a, b, sheet) }
                }
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
            Toggle(f.label, isOn: Binding(get: { values[f.key]?.flag ?? false }, set: { on in
                values[f.key] = .from(on ? 1 : 0)
                // A test's tried mark brings its date: today when ticked, none when unticked (as on the web).
                if f.key == "tried", spec.testKind != nil, spec.fields.contains(where: { $0.key == "tried_on" }) {
                    if !on { values["tried_on"] = .null } else if values["tried_on"]?.string == nil { values["tried_on"] = .string(fmt(.now, false)) }
                }
            }))
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
        case .choice(let words):
            Field(label: f.label) {
                Picker(f.label, selection: Binding(get: { values[f.key]?.string }, set: { values[f.key] = .from($0) })) {
                    Text("—").tag(String?.none)
                    ForEach(words, id: \.self) { w in Text(w).tag(String?.some(w)) }
                }.pickerStyle(.menu).labelsHidden()
            }
        case .variant:
            Field(label: f.label) { variantSection }
        case .prints(let kind):
            if let id = row?["id"].int, let k = TestKind(rawValue: kind) {
                Field(label: f.label) { TestPrints(kind: k, testId: id) }
            } else {
                Field(label: f.label) { Text("Save the test first, then link prints.").font(Theme.small).foregroundStyle(Theme.subOnBox) }
            }
        case .pigments:
            Field(label: f.label) {
                PigmentsEditor(rows: $pigs, options: options["pigment"] ?? []) {
                    guard let cid = values["chemistry_id"]?.int else { error = "Choose the glop batch first"; return }
                    Task {
                        if let c = try? await store.server.request("darkroom-api.php?res=chemistry&id=\(cid)") {
                            pigs = c["pigments"].array.map(PigmentAmount.init)
                            if values["gelatin_ml"]?.double == nil, let v = c["volume_ml"].double { values["gelatin_ml"] = .from(v) }
                        }
                    }
                }
            }
        case .laneNotes:
            Field(label: f.label) { SizeLaneNotes(laneId: values["lane_id"]?.int) }
        case .coats:
            if let id = row?["id"].int {
                Field(label: f.label) { SizeTestCoats(testId: id) }
            } else {
                Field(label: f.label) { Text("Save the test first, then add its coats.").font(Theme.small).foregroundStyle(Theme.subOnBox) }
            }
        case .photos:
            if let id = row?["id"].int {
                Field(label: f.label) { SizeTestPhotos(testId: id) }
            } else {
                Field(label: f.label) { Text("Save the test first, then add photos.").font(Theme.small).foregroundStyle(Theme.subOnBox) }
            }
        case .percent:
            Field(label: f.label) {
                HStack(spacing: 12) {
                    Slider(value: Binding(get: { values[f.key]?.double ?? 0 }, set: { values[f.key] = .from($0.rounded()) }), in: 0...100, step: 1)
                        .tint(Theme.inkOnBox)
                    Text(values[f.key]?.double.map { "\(Int($0))%" } ?? "—").font(Theme.body.weight(.bold)).foregroundStyle(Theme.inkOnBox)
                        .frame(width: 56, alignment: .trailing)
                    if values[f.key]?.double != nil {
                        Button("Clear") { values[f.key] = .null }.font(Theme.small.weight(.bold)).buttonStyle(.plain).foregroundStyle(Theme.subOnBox)
                    }
                }
            }
        case .duration:
            Field(label: f.label) {
                DurationField(seconds: Binding(get: { values[f.key]?.int }, set: { values[f.key] = .from($0) }))
            }
        case .rating(let lo, let hi):
            Field(label: f.label) {
                HStack(spacing: 8) {
                    ForEach(Array(lo...hi), id: \.self) { n in
                        let on = values[f.key]?.int == n
                        Button { values[f.key] = on ? .null : .from(n) } label: {
                            Text("\(n)").font(Theme.body.weight(.bold)).frame(width: 42, height: 42)
                                .foregroundStyle(on ? Theme.onInk : Theme.inkOnBox)
                                .background(on ? Theme.inkOnBox : Color.clear, in: RoundedRectangle(cornerRadius: 8))
                                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.inkOnBox, lineWidth: 1.5))
                        }.buttonStyle(.plain)
                    }
                    Spacer()
                }
                if let lines = scoreKey[f.key] {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(lines, id: \.self) { Text($0).font(Theme.small).foregroundStyle(Theme.subOnBox) }
                    }
                }
            }
        case .links:
            VStack(alignment: .leading, spacing: 6) {
                Text(f.label.uppercased()).font(Theme.label.weight(.bold)).tracking(1.5).foregroundStyle(Theme.bright)
                LinksEditor(rows: $links)
            }
        case .stage:
            Field(label: f.label) {
                VStack(alignment: .leading, spacing: 4) {
                    Picker(f.label, selection: Binding(get: { values[f.key]?.int }, set: { values[f.key] = .from($0) })) {
                        Text("—").tag(Int?.none)
                        ForEach(store.snapshot?.processes ?? []) { p in
                            ForEach(p.sections.filter { $0.serverId != nil }) { st in
                                Text("\(p.name) › \(st.title)").tag(st.serverId)
                            }
                        }
                    }.pickerStyle(.menu).labelsHidden()
                    if let r = row?["rev_label"].string, values[f.key]?.int == originalStage {
                        Text("Made from \(r)").font(Theme.small).foregroundStyle(Theme.subOnBox)
                    } else if values[f.key]?.int != nil {
                        Text("Records the stage's current revision").font(Theme.small).foregroundStyle(Theme.subOnBox)
                    }
                }
            }
        }
    }

    /// Fields kept in values and sent as they are (not the editors that save themselves or keep their own rows).
    private static func stored(_ k: ListSpec.Kind) -> Bool {
        switch k { case .links, .photos, .prints, .pigments, .variant: false; default: true }
    }

    private func text(_ key: String) -> Binding<String> {
        Binding(get: { values[key]?.string ?? "" }, set: { values[key] = $0.isEmpty ? .null : .string($0) })
    }

    private func setUp() async {
        if values.isEmpty {
            for f in spec.fields where Self.stored(f.kind) { values[f.key] = row?[f.key] ?? .null }
            pigs = (row?["pigments"].array ?? []).map(PigmentAmount.init)
            if pigs.isEmpty && spec.fields.contains(where: { $0.kind == .pigments }) { pigs = [PigmentAmount()] }
            if spec.fields.contains(where: { $0.kind == .stage }) { originalStage = row?["rev_stage_id"].int; values["stage_id"] = .from(originalStage) }
            links = (row?["links"].array ?? []).map(LinkRow.init(link:))
            if spec.fields.contains(where: { $0.kind == .variant }), row?["variant"].string != nil {
                values["variant_label"] = row?["variant_label"] ?? .null
                values["chosen"] = row?["chosen"] ?? .from(0)
            }
            if row == nil {     // a new one is made today
                for f in spec.fields where f.kind == .date && spec.required.contains(f.key) { values[f.key] = .string(fmt(.now, false)) }
            }
        }
        let wanted = spec.fields.compactMap { Self.scoreCodes[$0.key] != nil ? $0.key : nil }
        if !wanted.isEmpty, let crit = try? await store.list("size_criterion") {
            for key in wanted {
                guard let (subject, code) = Self.scoreCodes[key],
                      let c = crit.first(where: { $0["subject"].string == subject && $0["code"].string == code }) else { continue }
                scoreKey[key] = [("1", "anchor_1"), ("3", "anchor_3"), ("5", "anchor_5")]
                    .compactMap { n, k in c[k].string.map { "\(n)  \($0)" } }
            }
        }
        if spec.fields.contains(where: { $0.kind == .pigments }), options["pigment"] == nil { options["pigment"] = (try? await store.list("pigment")) ?? [] }
        for f in spec.fields {
            if case .pick(let s) = f.kind, options[s] == nil {
                do { options[s] = try await store.list(s) }
                catch let e as ServerError {
                    options[s] = []
                    error = e.retry ? "Can't reach knotwork.ca — \(f.label) can't be chosen without a connection" : "\(f.label) list: \(e.message)"
                }
                catch { options[s] = []; self.error = "\(f.label) list: \(error.localizedDescription)" }
            }
        }
    }

    private func save() {
        guard let body = makeBody() else { return }
        send(body)
    }

    /// What Save sends: the values, the pigments and the links; nil (with the error shown) when something needed is missing.
    private func makeBody() -> JSON? {
        if let miss = spec.required.first(where: { values[$0]?.string == nil }) {
            error = "\(spec.fields.first { $0.key == miss }?.label ?? miss) is needed"; return nil
        }
        var body = values.merging(spec.fixed) { _, f in f }
        // Sent only when changed: a batch walked from Rev 1 keeps Rev 1.
        if body["stage_id"]?.int == originalStage { body.removeValue(forKey: "stage_id") }
        if spec.fields.contains(where: { $0.kind == .pigments }) { body["pigments"] = .array(pigs.compactMap(\.asJSON)) }
        if spec.fields.contains(where: { $0.kind == .links }) {
            // Only when the server sent links (one without them would lose nothing either way).
            if row == nil || (row?["links"] ?? .null) != .null { body["links"] = .array(links.compactMap(\.asLink)) }
        }
        return .object(body)
    }

    /// The Variants field: this variant's letter, name and chosen mark, and Split / Add another variant.
    @ViewBuilder private var variantSection: some View {
        if let row, row["id"].int != nil {
            VStack(alignment: .leading, spacing: 10) {
                if let v = row["variant"].string {
                    HStack(spacing: 8) {
                        VariantTag(letter: v)
                        TextField("What this variant does differently", text: text("variant_label"))
                    }
                    Toggle("★ The chosen one", isOn: Binding(get: { values["chosen"]?.flag ?? false }, set: { values["chosen"] = .from($0 ? 1 : 0) }))
                        .font(Theme.body.weight(.semibold)).tint(Theme.red)
                } else {
                    Text("One test. Split it when something changes partway: a different tool, amount or timing.")
                        .font(Theme.small).foregroundStyle(Theme.subOnBox)
                }
                Button(row["variant"].string == nil ? "Split into variants (A, B …)" : "Add another variant", systemImage: "arrow.triangle.branch") { splitting = true }
                    .font(Theme.body.weight(.semibold)).buttonStyle(.borderless)
            }
        } else {
            Text("Save the test first, then it can be split into variants.").font(Theme.small).foregroundStyle(Theme.subOnBox)
        }
    }

    /// Saves this test's changes, makes the new variant (a copy of this one's setup), then opens it. Returns an error to show, or nil.
    private func split(_ labelA: String?, _ label: String?, _ sheet: Int?) async -> String? {
        guard let id = row?["id"].int else { return nil }
        guard let body = makeBody() else { return error }
        do {
            try await store.saveRow(spec.resource, id: id, body)
            var b: [String: JSON] = ["label": .from(label), "label_a": .from(labelA)]
            if let sheet { b["support_paper_id"] = .from(sheet) }
            let r = try await store.server.request("darkroom-api.php?res=\(spec.resource)&variant_of=\(id)", method: "POST", body: .object(b))
            await saved()
            dismiss()
            if let nid = r["id"].int { openRow?(nid) }
            return nil
        } catch let e as ServerError { return e.retry ? "Can't reach knotwork.ca — try again with a connection" : e.message }
        catch { return error.localizedDescription }
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


/// A sizing test's photos: the main one first, then the others. Tap to view large; press and hold to
/// caption, make main or remove. Photos go straight to knotwork.ca, so these need a connection.
struct SizeTestPhotos: View {
    let testId: Int
    @Environment(AppStore.self) private var store
    @State private var images: [JSON] = []
    @State private var note: String?
    @State private var busy = false
    @State private var camera = false
    @State private var showLibrary = false
    @State private var library: PhotosPickerItem?
    @State private var viewing: JSON?
    @State private var captioning: JSON?
    @State private var caption = ""
    @State private var removing: JSON?

    private func url(_ path: String?) -> URL? { path.flatMap { URL(string: $0, relativeTo: store.server.base) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 70), spacing: 8)], spacing: 8) {
                ForEach(Array(images.enumerated()), id: \.offset) { _, i in
                    VStack(spacing: 2) {
                        Color.clear.aspectRatio(1, contentMode: .fit)
                            .overlay { AsyncImage(url: url(i["thumb_path"].string ?? i["image_path"].string)) { $0.resizable().scaledToFill() } placeholder: { Theme.box } }
                            .clipShape(.rect(cornerRadius: 5))
                            .overlay(RoundedRectangle(cornerRadius: 5).stroke(i["is_main"].flag ? Theme.inkOnBox : .clear, lineWidth: 2))
                            .onTapGesture { viewing = i }
                            .contextMenu {
                                if !i["is_main"].flag { Button("Make main photo", systemImage: "star") { Task { await change(i, ["is_main": 1]) } } }
                                Button("Caption", systemImage: "text.bubble") { caption = i["caption"].string ?? ""; captioning = i }
                                Button("Remove", systemImage: "trash", role: .destructive) { removing = i }
                            }
                        if let c = i["caption"].string { Text(c).font(.caption2).foregroundStyle(Theme.subOnBox).lineLimit(1) }
                    }
                }
                Menu {
                    if UIImagePickerController.isSourceTypeAvailable(.camera) { Button("Take Photo", systemImage: "camera") { camera = true } }
                    Button("Photo Library", systemImage: "photo") { showLibrary = true }
                } label: {
                    Color.clear.aspectRatio(1, contentMode: .fit)
                        .overlay { if busy { ProgressView().tint(Theme.inkOnBox) } else { Image(systemName: "plus").font(.title3) } }
                        .foregroundStyle(Theme.inkOnBox)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Theme.inkOnBox.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [4])))
                }
                .disabled(busy)
                .accessibilityLabel(images.isEmpty ? "Add the main photo" : "Add another photo")
            }
            if let note { Text(note).font(Theme.small).foregroundStyle(Theme.inkOnBox) }
        }
        .task { await reload() }
        .photosPicker(isPresented: $showLibrary, selection: $library, matching: .images)
        .onChange(of: library) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { await add(img) }
                library = nil
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraView(note: { note = $0 }) { img in camera = false; if let img { Task { await add(img) } } }.ignoresSafeArea()
        }
        .fullScreenCover(item: Binding(get: { viewing.map { Wrapped(row: $0) } }, set: { viewing = $0?.row })) { w in
            ZStack {
                Color.black.ignoresSafeArea()
                AsyncImage(url: url(w.row["image_path"].string)) { $0.resizable().scaledToFit() } placeholder: { ProgressView() }
            }
            .onTapGesture { viewing = nil }
        }
        .alert("Caption", isPresented: Binding(get: { captioning != nil }, set: { if !$0 { captioning = nil } })) {
            TextField("What this photo shows", text: $caption)
            Button("Save") { if let c = captioning { Task { await change(c, ["caption": .from(caption.isEmpty ? nil : caption)]) } } }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Remove this photo?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
                            titleVisibility: .visible, presenting: removing) { i in
            Button("Remove", role: .destructive) { Task { await remove(i) } }
            Button("Keep it", role: .cancel) {}
        } message: { _ in Text("It's deleted from knotwork.ca.") }
    }

    private func reload() async {
        do { images = try await store.list("size_test_image&id=\(testId)"); note = nil }
        catch let e as ServerError { note = e.retry ? "Can't reach knotwork.ca — photos need a connection" : e.message }
        catch { self.note = error.localizedDescription }
    }
    private func call(_ what: String, _ run: () async throws -> Void) async {
        busy = true; defer { busy = false }
        do { try await run(); note = nil; await reload() }
        catch let e as ServerError { note = e.retry ? "Can't reach knotwork.ca — \(what) didn't happen" : e.message }
        catch { note = error.localizedDescription }
    }
    /// The first photo of a test is its main photo; the rest are added alongside it.
    private func add(_ img: UIImage) async {
        guard let jpeg = img.shrunk(to: 1800).jpegData(compressionQuality: 0.9) else { return }
        await call("the photo upload") { _ = try await store.server.upload(jpeg: jpeg, photoId: testId, detail: !images.isEmpty, res: "size_test_image") }
    }
    private func change(_ i: JSON, _ body: [String: JSON]) async {
        guard let iid = i["id"].int else { return }
        await call("the change") { _ = try await store.server.request("darkroom-api.php?res=size_test_image&id=\(testId)&image=\(iid)", method: "PATCH", body: .object(body)) }
    }
    private func remove(_ i: JSON) async {
        guard let iid = i["id"].int else { return }
        await call("the removal") { _ = try await store.server.request("darkroom-api.php?res=size_test_image&id=\(testId)&image=\(iid)", method: "DELETE") }
    }
}


/// A sizing test's coats of size, each with the day and time it went on (knotwork.ca migration 037).
/// Add coat puts in a coat at the current day and time; tap a coat to change its day, time or note,
/// or remove it. Coats go straight to knotwork.ca, so these need a connection. The server keeps the
/// test's Sized, Coats and Cure start in step with them.
struct SizeTestCoats: View {
    let testId: Int
    @Environment(AppStore.self) private var store
    @State private var coats: [JSON] = []
    @State private var note: String?
    @State private var busy = false
    @State private var editing: JSON?

    private static let day: DateFormatter = { let f = DateFormatter(); f.calendar = Calendar(identifier: .gregorian); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"; return f }()
    private static let hm: DateFormatter = { let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "HH:mm"; return f }()
    static func when(_ c: JSON) -> Date? {
        guard let d = c["coated_on"].string, let base = day.date(from: d) else { return nil }
        guard let t = c["coated_time"].string, let tm = hm.date(from: t) else { return base }
        let k = Calendar.current.dateComponents([.hour, .minute], from: tm)
        return Calendar.current.date(bySettingHour: k.hour ?? 0, minute: k.minute ?? 0, second: 0, of: base)
    }
    /// "+15 min", "+2 h 5 min", "+1 day" since the coat before.
    static func gap(_ prev: JSON?, _ c: JSON) -> String? {
        guard let prev, let a = when(prev), let b = when(c) else { return nil }
        if prev["coated_time"].string == nil || c["coated_time"].string == nil {
            let d = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: a), to: Calendar.current.startOfDay(for: b)).day ?? 0
            return d < 0 ? "before the coat above" : d == 0 ? "same day" : "+\(d) day\(d == 1 ? "" : "s")"
        }
        let m = Int(b.timeIntervalSince(a) / 60)
        if m < 0 { return "before the coat above" }
        if m < 60 { return "+\(m) min" }
        if m < 1440 { return "+\(m / 60) h" + (m % 60 > 0 ? " \(m % 60) min" : "") }
        return "+\(m / 1440) d" + ((m % 1440) / 60 > 0 ? " \((m % 1440) / 60) h" : "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(coats.enumerated()), id: \.offset) { n, c in
                Button { editing = c } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("Coat \(c["coat_no"].int ?? n + 1)").font(Theme.body.weight(.bold))
                        VStack(alignment: .leading, spacing: 1) {
                            Text([c["coated_on"].string, c["coated_time"].string ?? "time not recorded", c["ml"].double.map { "\(Amount.format($0)) mL" }].compactMap { $0 }.joined(separator: "  "))
                            if let t = c["note"].string { Text(t).font(Theme.small).foregroundStyle(Theme.subOnBox) }
                        }
                        Spacer()
                        if let g = Self.gap(n > 0 ? coats[n - 1] : nil, c) { Text(g).font(Theme.small).foregroundStyle(Theme.subOnBox) }
                    }
                    .foregroundStyle(Theme.inkOnBox)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Change the day, time or note")
            }
            if coats.isEmpty { Text("No coats recorded yet.").font(Theme.small).foregroundStyle(Theme.subOnBox) }
            if coats.contains(where: { $0["ml"].double != nil }) {
                Text("\(Amount.format(coats.compactMap { $0["ml"].double }.reduce(0, +))) mL on the sheet in all").font(Theme.small).foregroundStyle(Theme.subOnBox)
            }
            Button { Task { await add() } } label: {
                Label(busy ? "Saving…" : "Add coat (now)", systemImage: "plus").font(Theme.small.weight(.bold))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.inkOnBox).disabled(busy)
            if let note { Text(note).font(Theme.small).foregroundStyle(Theme.inkOnBox) }
        }
        .task { await reload() }
        .sheet(item: Binding(get: { editing.map { Wrapped2(row: $0) } }, set: { editing = $0?.row })) { w in
            CoatEditor(coat: w.row) { body in
                editing = nil
                if let body { await change(w.row, body) } else { await remove(w.row) }
            }
        }
    }

    private func reload() async {
        do { coats = try await store.list("size_test_coat&id=\(testId)"); note = nil }
        catch let e as ServerError { note = e.retry ? "Can't reach knotwork.ca — coats need a connection" : e.message }
        catch { self.note = error.localizedDescription }
    }
    private func call(_ what: String, _ run: () async throws -> Void) async {
        busy = true; defer { busy = false }
        do { try await run(); note = nil; await reload() }
        catch let e as ServerError { note = e.retry ? "Can't reach knotwork.ca — \(what) didn't happen" : e.message }
        catch { note = error.localizedDescription }
    }
    private func add() async {
        let now = Date()
        await call("the new coat") {
            _ = try await store.server.request("darkroom-api.php?res=size_test_coat&id=\(testId)", method: "POST",
                                               body: .object(["coated_on": .from(Self.day.string(from: now)), "coated_time": .from(Self.hm.string(from: now))]))
        }
    }
    private func change(_ c: JSON, _ body: [String: JSON]) async {
        guard let cid = c["id"].int else { return }
        await call("the change") { _ = try await store.server.request("darkroom-api.php?res=size_test_coat&id=\(testId)&coat=\(cid)", method: "PATCH", body: .object(body)) }
    }
    private func remove(_ c: JSON) async {
        guard let cid = c["id"].int else { return }
        await call("the removal") { _ = try await store.server.request("darkroom-api.php?res=size_test_coat&id=\(testId)&coat=\(cid)", method: "DELETE") }
    }
}

private struct Wrapped2: Identifiable { let row: JSON; var id: Int { row["id"].int ?? 0 } }

/// One coat's day, time (optional) and note. done(body) saves; done(nil) removes the coat.
private struct CoatEditor: View {
    let coat: JSON
    let done: ([String: JSON]?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var day: Date
    @State private var hasTime: Bool
    @State private var time: Date
    @State private var text: String
    @State private var ml: Double?
    @State private var confirmRemove = false

    init(coat: JSON, done: @escaping ([String: JSON]?) async -> Void) {
        self.coat = coat; self.done = done
        let when = SizeTestCoats.when(coat) ?? Date()
        _day = State(initialValue: when); _time = State(initialValue: when)
        _hasTime = State(initialValue: coat["coated_time"].string != nil)
        _text = State(initialValue: coat["note"].string ?? "")
        _ml = State(initialValue: coat["ml"].double)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Day", selection: $day, displayedComponents: .date)
                Toggle("Time known", isOn: $hasTime)
                if hasTime { DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute) }
                HStack { Text("mL on the sheet"); Spacer(); NumberField(value: $ml).multilineTextAlignment(.trailing).frame(maxWidth: 110) }
                TextField(hint: "Note: direction, tool", text: $text)
                Section {
                    Button("Remove this coat", role: .destructive) { confirmRemove = true }
                }
            }
            .navigationTitle("Coat \(coat["coat_no"].int ?? 0)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.calendar = Calendar(identifier: .gregorian)
                        f.dateFormat = "yyyy-MM-dd"; let d = f.string(from: day)
                        f.dateFormat = "HH:mm"; let t = hasTime ? f.string(from: time) : nil
                        let n = text.trimmingCharacters(in: .whitespaces)
                        Task { await done(["coated_on": .from(d), "coated_time": .from(t), "ml": .from(ml), "note": .from(n.isEmpty ? nil : String(n.prefix(150)))]) }
                    }
                }
            }
            .confirmationDialog("Remove this coat?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { Task { await done(nil) } }
                Button("Keep it", role: .cancel) {}
            } message: { Text("The coats after it move up a number.") }
        }
    }
}


/// A sizing lane's recipe card and what the source compendium says about it, for reference
/// at the bottom of a sizing test. Read from knotwork.ca (needs a connection).
struct SizeLaneNotes: View {
    let laneId: Int?
    @Environment(AppStore.self) private var store
    @State private var lane: JSON?
    @State private var note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let lane {
                Text([lane["code"].string, lane["name"].string].compactMap { $0 }.joined(separator: " · "))
                    .font(Theme.body.weight(.bold)).foregroundStyle(Theme.inkOnBox)
                Text(lane["recipe"].string ?? "No recipe card for this lane.")
                    .font(Theme.small).foregroundStyle(Theme.inkOnBox).textSelection(.enabled)
                if let ref = lane["reference"].string {
                    Text("From the source compendium").font(Theme.small.weight(.bold)).foregroundStyle(Theme.inkOnBox).padding(.top, 4)
                    Text(ref).font(Theme.small).foregroundStyle(Theme.inkOnBox).textSelection(.enabled)
                }
            } else if laneId == nil {
                Text("Pick a lane to see its directions.").font(Theme.small).foregroundStyle(Theme.subOnBox)
            }
            if let note { Text(note).font(Theme.small).foregroundStyle(Theme.subOnBox) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: laneId) { await load() }
    }

    private func load() async {
        guard let laneId else { lane = nil; return }
        do { lane = try await store.list("size_lane").first { $0["id"].int == laneId }; note = lane == nil ? "Lane not found." : nil }
        catch let e as ServerError { note = e.retry ? "Can't reach knotwork.ca — directions need a connection" : e.message }
        catch { note = error.localizedDescription }
    }
}
