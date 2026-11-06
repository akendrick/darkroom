import Foundation

/// The server's sync feed (darkroom-api.php?res=sync), kept on the phone so
/// the walk-through works with no connection.
struct Snapshot: Codable, Equatable {
    var raw: JSON
    var fetchedAt: Date

    var photoTypes: [PhotoType] { raw["photo_types"].array.map(PhotoType.init) }
    var stepKinds: [JSON] { raw["step_kinds"].array }
    var presets: [Preset] { raw["presets"].array.map(Preset.init).filter { !$0.archived } }
    var batches: [Batch] { raw["chemistry"].array.map(Batch.init).filter { !$0.archived } }
    var papers: [Paper] { raw["papers"].array.map(Paper.init).filter { !$0.archived } }
    var chemistryTypes: [(id: Int, name: String)] {
        raw["chemistry_types"].array.compactMap { j in j["id"].int.map { (id: $0, name: j["name"].string ?? "#\($0)") } }
    }
    var materialKinds: [MaterialKind] { raw["material_kinds"].array.map(MaterialKind.init).filter { !$0.archived } }
    /// Materials of a kind made by the owner ("Photo Paper").
    func materials(_ kind: Int) -> [Material] {
        raw["materials"].array.filter { $0["kind_id"].int == kind && !$0["archived"].flag }.map(Material.init(generic:))
    }
    func kindName(_ id: Int?) -> String? { materialKinds.first { $0.id == id }?.name }
    var pigments: [Pigment] { raw["pigments"].array.map(Pigment.init).filter { !$0.archived } }
    func pigment(_ id: Int?) -> Pigment? { pigments.first { $0.id == id } }
    /// Glop and tissue walk-throughs still going (started here or on the web).
    var making: [JSON] { raw["making"].array }
    func chemistryTypeName(_ id: Int?) -> String? { chemistryTypes.first { $0.id == id }?.name }
    var inProgress: [JSON] { raw["in_progress"].array }
    var recent: [JSON] { raw["recent"].array }

    func items(_ what: SelectWhat) -> [Material] {
        raw[what.syncKey].array.map { Material(what: what, row: $0) }.filter { !$0.archived }
    }
    func preset(_ id: Int?) -> Preset? { presets.first { $0.id == id } }
    func typeName(_ id: Int?) -> String { photoTypes.first { $0.id == id }?.name ?? "Print" }
}

/// A kind of material the owner made ("Photo Paper"), with its own list.
struct MaterialKind: Identifiable, Equatable, Hashable {
    let id: Int, name: String, archived: Bool
    init(_ j: JSON) { id = j["id"].int ?? 0; name = j["name"].string ?? "Material"; archived = j["archived"].flag }
}

struct PhotoType: Identifiable, Equatable {
    let id: Int, name: String, hasLayers: Bool
    init(_ j: JSON) { id = j["id"].int ?? 0; name = j["name"].string ?? ""; hasLayers = j["has_layers"].flag }
}

/// A walk-through. It makes a print of a photo type, a chemistry batch of a
/// type (glop) or a carbon tissue.
struct Preset: Identifiable, Equatable {
    let id: Int, photoTypeId: Int, name: String, isDefault: Bool, archived: Bool, steps: [Step]
    let makes: String, chemistryTypeId: Int?
    init(_ j: JSON) {
        id = j["id"].int ?? 0; photoTypeId = j["photo_type_id"].int ?? 0; name = j["name"].string ?? ""
        makes = j["makes"].string ?? "print"; chemistryTypeId = j["chemistry_type_id"].int
        isDefault = j["is_default"].flag; archived = j["archived"].flag
        steps = j["steps"].array.map(Step.init).filter { !$0.archived }
    }
    /// Which list it sits in: "p:3" a print type, "c:8" a chemistry type, "t" tissue.
    var group: String { makes == "chemistry" ? "c:\(chemistryTypeId ?? 0)" : makes == "tissue" ? "t" : "p:\(photoTypeId)" }
    var makesPrint: Bool { makes == "print" }
}

/// A row of walk-throughs on the start page and the home screen.
struct WalkGroup: Identifiable, Equatable {
    let id: String, name: String
    /// Prints first, then chemistry recipes, then tissue; only those with a walk-through.
    static func all(_ snap: Snapshot?) -> [WalkGroup] {
        guard let snap else { return [] }
        let ps = snap.presets
        var gs = snap.photoTypes.map { WalkGroup(id: "p:\($0.id)", name: $0.name) }
        for p in ps where p.makes == "chemistry" && !gs.contains(where: { $0.id == p.group }) {
            gs.append(WalkGroup(id: p.group, name: snap.chemistryTypeName(p.chemistryTypeId) ?? "Chemistry"))
        }
        gs.append(WalkGroup(id: "t", name: "Carbon tissue"))
        return gs.filter { g in ps.contains { $0.group == g.id } }
    }
}

/// A pigment, with the short code used in batch IDs ("Ind.I").
struct Pigment: Identifiable, Equatable, Hashable {
    let id: Int, name: String, shortCode: String?, archived: Bool
    init(_ j: JSON) { id = j["id"].int ?? 0; name = j["name"].string ?? "#\(j["id"].int ?? 0)"; shortCode = j["short_code"].string; archived = j["archived"].flag }
    init(id: Int, name: String) { self.id = id; self.name = name; shortCode = nil; archived = false }
    /// Its own code, else "India Ink" → "Ind.I", "Lampblack" → "Lamp".
    var short: String {
        if let c = shortCode, !c.isEmpty { return c }
        let w = name.split(whereSeparator: { $0 == " " || $0 == "-" }).map(String.init)
        guard let first = w.first else { return "" }
        if w.count < 2 { return String(first.prefix(4)).capitalized }
        return String(first.prefix(3)).capitalized + "." + w.dropFirst().compactMap { $0.first.map { String($0).uppercased() } }.joined()
    }
}

struct Step: Identifiable, Equatable, Hashable {
    let id: Int, name: String, kind: String, selectWhat: SelectWhat?, perLayer: Bool, asksTemp: Bool
    /// Chooses one of this kind of material (the owner's own kinds).
    let materialKindId: Int?
    /// Off: no timer, just "do this, then Next".
    let timed: Bool
    let tray: Int?, chemistryTypeId: Int?, defaultSeconds: Int?, minSeconds: Int?, maxSeconds: Int?
    let defaultTemp: Double?, optional: Bool, recordsPh: Bool, lightsOkAfter: Bool
    let notes: String?, sameAsStepId: Int?, archived: Bool
    /// The server's select_what as sent: also "chemistry" (a batch) and "pigment".
    let selectRaw: String?
    /// Add / measure steps: the recipe's amount, its unit, the usual pigment.
    let defaultAmount: Double?, unit: String?, pigmentId: Int?

    init(_ j: JSON) {
        id = j["id"].int ?? 0; name = j["name"].string ?? "Step"; kind = j["kind"].string ?? "bath"
        selectWhat = j["select_what"].string.flatMap(SelectWhat.init(rawValue:))
        materialKindId = j["material_kind_id"].int
        timed = j["timed"] == .null ? true : j["timed"].flag
        perLayer = j["per_layer"].flag; asksTemp = j["asks_temp"].flag; tray = j["tray"].int
        chemistryTypeId = j["chemistry_type_id"].int; defaultSeconds = j["default_seconds"].int
        minSeconds = j["min_seconds"].int; maxSeconds = j["max_seconds"].int; defaultTemp = j["default_temp"].double
        optional = j["optional"].flag; recordsPh = j["records_ph"].flag; lightsOkAfter = j["lights_ok_after"].flag
        notes = j["notes"].string; sameAsStepId = j["same_as_step_id"].int; archived = j["archived"].flag
        selectRaw = j["select_what"].string
        defaultAmount = j["default_amount"].double; unit = j["unit"].string; pigmentId = j["pigment_id"].int
    }

    var isSelect: Bool { kind == "select" }
    var isExposure: Bool { kind == "exposure" }
    /// A page with a timer: not a choice, and not a "do this, then Next" step.
    var hasTimer: Bool { !isSelect && timed }
    /// An amount to measure, changeable on the day.
    var isAdd: Bool { kind == "add" }
    /// An add step listing pigments and grams.
    var isPigment: Bool { isAdd && selectRaw == "pigment" }
    /// Chooses a chemistry batch: the glop for a tissue.
    var choosesBatch: Bool { isSelect && selectRaw == "chemistry" }
    var unitShown: String { unit ?? (isPigment ? "g" : "") }
}

/// What a "Select a material" step chooses, and the print layer field it fills.
enum SelectWhat: String, Codable, CaseIterable {
    case negative, carbon_tissue, support_paper

    var layerField: String { rawValue + "_id" }
    var syncKey: String {
        switch self { case .negative: "negatives"; case .carbon_tissue: "carbon_tissues"; case .support_paper: "support_papers" }
    }
    var noun: String {
        switch self { case .negative: "negative"; case .carbon_tissue: "carbon tissue"; case .support_paper: "support paper" }
    }
    var resource: String { rawValue }
}

/// A negative, tissue sheet or support paper, as listed for choosing.
struct Material: Identifiable, Equatable {
    let id: Int, label: String, sub: String?, archived: Bool

    init(id: Int, label: String, sub: String?) { self.id = id; self.label = label; self.sub = sub; archived = false }

    /// One of the owner's own kinds: its name, then maker and notes.
    init(generic j: JSON) {
        id = j["id"].int ?? 0; archived = j["archived"].flag; label = j["label"].string ?? "#\(id)"
        let s = [j["maker"].string, j["notes"].string].compactMap { $0 }.joined(separator: " · ")
        sub = s.isEmpty ? nil : s
    }

    init(what: SelectWhat, row j: JSON) {
        id = j["id"].int ?? 0; archived = j["archived"].flag
        // Same labels as the web page: "Title.26.11", or "#12 26.11".
        func dated(_ title: String?, _ date: String?) -> String {
            let ym = date.map { String($0.dropFirst(2).prefix(5)).replacingOccurrences(of: "-", with: ".") } ?? ""
            return title.map { "\($0).\(ym)" } ?? "#\(j["id"].int ?? 0) \(ym)"
        }
        switch what {
        case .negative:
            label = dated(j["title_id"].string, j["date_created"].string); sub = j["settings_notes"].string
        case .carbon_tissue:
            label = dated(j["title_id"].string, j["date_poured"].string)
            let s = [j["size"].string, j["chem_label"].string].compactMap { $0 }.joined(separator: " · ")
            sub = s.isEmpty ? nil : s
        case .support_paper:
            let paper = j["paper_label"].string ?? j["manufacturer"].string ?? ""
            label = "\(j["mark"].string ?? "#\(id)") (\(paper))"; sub = j["notes"].string
        }
    }
}

struct Paper: Identifiable, Equatable {
    let id: Int, name: String, archived: Bool
    init(_ j: JSON) {
        id = j["id"].int ?? 0; archived = j["archived"].flag
        let n = [j["manufacturer"].string, j["label"].string].compactMap { $0 }.joined(separator: " ")
        name = n.isEmpty ? "#\(id)" : n
    }
}

struct Batch: Identifiable, Equatable {
    let id: Int, typeId: Int?, label: String, archived: Bool
    /// Its own label ("1105-Ind.I"), its pigments, and "12 g India Ink + 4 g Carbon Black".
    let ownLabel: String?, pigmentIds: [Int], pigmentsText: String?
    init(_ j: JSON) {
        id = j["id"].int ?? 0; typeId = j["type_id"].int; archived = j["archived"].flag
        ownLabel = j["label"].string
        let pg = j["pigments"].array
        pigmentIds = pg.compactMap { $0["pigment_id"].int }
        let t = pg.map { p -> String in
            let amt = p["grams"].double.map { "\(Amount.format($0)) g " } ?? p["ml"].double.map { "\(Amount.format($0)) mL " } ?? ""
            return amt + (p["pigment_name"].string ?? "")
        }.joined(separator: " + ")
        pigmentsText = t.isEmpty ? nil : t
        let type = j["type_name"].string ?? "Chemistry"
        label = j["label"].string.map { "\($0) (\(type))" } ?? "\(type) \(j["date_created"].string ?? "")"
    }
}

enum ExposureMethod: String, CaseIterable, Codable {
    case contact, enlarger, in_camera
    var label: String {
        switch self { case .contact: "Contact (UV / sun)"; case .enlarger: "Enlarger"; case .in_camera: "In camera" }
    }
}

enum Amount {
    /// 100.000 → "100", 2.5 → "2.5".
    static func format(_ v: Double) -> String { v.formatted(.number.precision(.fractionLength(0...3)).grouping(.never)) }
}

enum Clock {
    /// Local "YYYY-MM-DD HH:MM:SS", as the web page records step start times.
    static func stamp(_ d: Date = .now) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }
    static func today(_ d: Date = .now) -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }
}
