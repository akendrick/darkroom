import Foundation

/// One pigment and its grams on a pigment step.
struct PigLine: Codable, Equatable, Identifiable {
    var id = UUID()
    var pigmentId: Int?         // below 0 = added on the phone, not sent yet
    var grams: Double?
}

/// What was recorded on one step page.
struct StepRecord: Codable, Equatable {
    var timer = StepTimer()
    var manual: Int?            // typed time, seconds
    var temp: Double?
    var ph: Double?
    var chemistryId: Int?
    var materialId: Int?        // one of the owner's own kinds; below 0 = added on the phone, not sent yet
    var notes: String?
    var startedAt: String?      // local "YYYY-MM-DD HH:MM:SS"
    var seconds: Int?           // fixed on Next
    var skipped = false
    var done = false            // set by Next or Skip only
    var alarmed = false
    var amount: Double?         // add steps: as measured today
    var pigments: [PigLine]?    // pigment steps
}

/// One print being walked through. Kept on the phone and sent whole on every
/// Next, exactly as the web page does, so the server always holds the latest.
struct PrintDraft: Codable, Identifiable, Equatable {
    var clientId: String = UUID().uuidString.lowercased()   // photo.client_id is 36 characters, as on the web
    var photoId: Int?
    var typeId: Int
    var presetId: Int
    var title = ""
    var edition: String?        // free text, after the title: "A", "2/10"
    var date = Clock.today()
    var method: ExposureMethod?
    var notes = ""
    /// One entry per print layer: "negative_id" → id. Ids below 0 are materials
    /// added on the phone that the server hasn't been told about yet.
    var layers: [[String: Int]] = [[:]]
    var recs: [String: StepRecord] = [:]
    var page = 0
    var finished = false
    var hasImage = false

    // Sending
    var unsent = false          // changed since the server last had it
    var pendingImage: String?   // file name in the images folder, waiting for upload
    var updatedAt = Date()

    // A walk that makes a chemistry batch or a tissue instead (a make_run).
    var makes: String?          // nil or "print": a print
    var runId: Int?
    var label: String?          // the batch label or tissue ID, set on the last page
    var volume: Double?
    var size: String?
    var amountPoured: String?
    var madeId: Int?            // the batch or tissue it made, once sent

    var id: String { clientId }

    static func key(_ step: Step, layer: Int) -> String { "\(step.id):\(layer)" }

    var isMake: Bool { (makes ?? "print") != "print" }
    /// The print's or the run's id on the server.
    var recordId: Int? { isMake ? runId : photoId }
}

/// A walk-through page.
enum WalkPage: Equatable, Hashable {
    case start
    case step(Step, layer: Int)     // layer 0 = the whole print
    case finish

    var step: Step? { if case .step(let s, _) = self { return s }; return nil }
    var layer: Int { if case .step(_, let l) = self { return l }; return 0 }
}

extension PrintDraft {
    /// Start, each per-layer step for each layer, the remaining steps, finish.
    /// One layer per walk-through: multi-colour layers are added at the press
    /// stage. A print that already has more keeps them all.
    func pages(_ preset: Preset?) -> [WalkPage] {
        let steps = preset?.steps ?? []
        var p: [WalkPage] = [.start]
        for n in 1...max(1, layers.count) { p += steps.filter(\.perLayer).map { .step($0, layer: n) } }
        p += steps.filter { !$0.perLayer }.map { .step($0, layer: 0) }
        return p + [.finish]
    }

    func isDone(_ page: WalkPage) -> Bool {
        guard case .step(let s, let layer) = page else { return page == .start }
        if s.isSelect, s.materialKindId != nil { return recs[Self.key(s, layer: layer)]?.materialId != nil }
        if s.choosesBatch { return recs[Self.key(s, layer: layer)]?.chemistryId != nil }
        if s.isSelect {
            guard let f = s.selectWhat?.layerField else { return true }
            return layers[max(layer, 1) - 1][f] != nil
        }
        return recs[Self.key(s, layer: layer)]?.done ?? false
    }

    /// "Same batch as" a step earlier in this print.
    func sameBatch(_ s: Step) -> Int? {
        guard let other = s.sameAsStepId else { return nil }
        return recs.first { $0.key.hasPrefix("\(other):") }?.value.chemistryId
    }

    func defaultTitle(_ snap: Snapshot?) -> String {
        if isMake { return label ?? snap?.preset(presetId)?.name ?? "Walk-through" }
        return "\(snap?.typeName(typeId) ?? "Print") \(date)"
    }

    /// Suggested ID MMDD-pigment ("1105-Ind.I"); a tissue takes its glop's
    /// pigments. -2, -3 … when taken. Always changeable on the last page.
    func suggestedId(_ snap: Snapshot?, pending: [Int: String] = [:]) -> String {
        let md = date.dropFirst(5).replacingOccurrences(of: "-", with: "")
        var pigs: [Int] = []
        var glop: Batch?
        let steps = snap?.preset(presetId)?.steps ?? []
        if makes == "chemistry" {
            for s in steps where s.isPigment { pigs += (recs[Self.key(s, layer: 0)]?.pigments ?? []).compactMap(\.pigmentId) }
        } else if let s = steps.first(where: \.choosesBatch), let id = recs[Self.key(s, layer: 0)]?.chemistryId {
            glop = snap?.batches.first { $0.id == id }; pigs = glop?.pigmentIds ?? []
        }
        var seen = Set<Int>()
        let codes = pigs.filter { seen.insert($0).inserted }.compactMap { id in pending[id] ?? snap?.pigment(id)?.short }.filter { !$0.isEmpty }
        let base = md + (codes.isEmpty ? (glop?.ownLabel.map { "-" + $0 } ?? "") : "-" + codes.joined(separator: "+"))
        let taken: Set<String> = makes == "chemistry"
            ? Set((snap?.batches ?? []).filter { $0.id != madeId }.compactMap(\.ownLabel))
            : Set((snap?.raw["carbon_tissues"].array ?? []).filter { $0["id"].int != madeId }.compactMap { $0["title_id"].string })
        var id = base, n = 2
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    /// The amount on a tissue's pour step: "45 mL".
    func poured(_ snap: Snapshot?) -> String? {
        for s in snap?.preset(presetId)?.steps ?? [] where s.isAdd && !s.isPigment {
            if let r = recs[Self.key(s, layer: 0)], r.done, !r.skipped, let a = r.amount { return Amount.format(a) + (s.unit.map { " " + $0 } ?? "") }
        }
        return nil
    }

    /// A glop or tissue walk as darkroom-api.php's make_run takes it.
    func runPayload(_ snap: Snapshot?, ids: [Int: Int]) -> JSON? {
        var steps: [JSON] = [], pigments: [JSON] = []
        for page in pages(snap?.preset(presetId)) {
            guard case .step(let s, let layer) = page, let r = recs[Self.key(s, layer: layer)], r.done else { continue }
            var amount = r.amount
            if s.isPigment {
                let lines = (r.pigments ?? []).filter { $0.pigmentId != nil }
                for l in lines {
                    var pid = l.pigmentId!
                    if pid < 0 { guard let real = ids[pid] else { return nil }; pid = real }
                    pigments.append(.object(["process_step_id": .from(s.id), "pigment_id": .from(pid), "grams": .from(l.grams)]))
                }
                amount = lines.contains { $0.grams != nil } ? lines.reduce(0) { $0 + ($1.grams ?? 0) } : nil
            }
            var material = r.materialId
            if let m = material, m < 0 { guard let real = ids[m] else { return nil }; material = real }
            steps.append(.object([
                "process_step_id": .from(s.id), "name": .string(s.name), "kind": .string(s.kind),
                "chemistry_id": .from(r.chemistryId), "material_id": .from(material),
                "amount": r.skipped ? .null : .from(amount), "unit": .from(s.isAdd ? s.unitShown : nil),
                "started_at": .from(r.startedAt), "seconds": r.skipped ? .null : .from(r.seconds),
                "temp": .from(r.temp), "skipped": .from(r.skipped ? 1 : 0), "notes": .from(r.notes),
            ]))
        }
        let name = (label ?? "").isEmpty ? suggestedId(snap) : label!
        return .object([
            "preset_id": .from(presetId), "status": .string(finished ? "done" : "in_progress"),
            "label": .string(name), "made_on": .string(date), "volume_ml": .from(volume),
            "size": .from(size.flatMap { $0.isEmpty ? nil : $0 }),
            "amount_poured": .from((amountPoured ?? "").isEmpty ? poured(snap) : amountPoured),
            "notes": .from(notes.isEmpty ? nil : notes), "steps": .array(steps), "pigments": .array(pigments),
        ])
    }

    /// The print as darkroom-api.php takes it. `ids` turns phone-only material
    /// ids into server ones; nil while one is still unsent.
    func payload(_ snap: Snapshot?, ids: [Int: Int]) -> JSON? {
        if isMake { return runPayload(snap, ids: ids) }
        var steps: [JSON] = []
        for page in pages(snap?.preset(presetId)) {
            // A choice of the owner's own kind of material is kept on its step.
            guard case .step(let s, let layer) = page, !s.isSelect || s.materialKindId != nil || s.choosesBatch,
                  let r = recs[Self.key(s, layer: layer)], r.done else { continue }
            var material = r.materialId
            if let m = material, m < 0 { guard let real = ids[m] else { return nil }; material = real }
            steps.append(.object([
                "process_step_id": .from(s.id), "layer_no": .from(layer), "name": .string(s.name),
                "kind": .string(s.kind), "tray": .from(s.tray), "chemistry_id": .from(r.chemistryId), "material_id": .from(material),
                "started_at": .from(r.startedAt), "seconds": r.skipped ? .null : .from(r.seconds),
                "temp": .from(r.temp), "ph": .from(r.ph), "skipped": .from(r.skipped ? 1 : 0), "notes": .from(r.notes),
            ]))
        }
        var outLayers: [JSON] = []
        for l in layers {
            var o: [String: JSON] = [:]
            for (f, v) in l {
                if v < 0 { guard let real = ids[v] else { return nil }; o[f] = .from(real) } else { o[f] = .from(v) }
            }
            outLayers.append(.object(o))
        }
        // The print's exposure is the first layer's; every layer's is in its steps.
        let exposure = steps.first { $0["kind"].string == "exposure" && !$0["skipped"].flag && $0["seconds"].int != nil }
        return .object([
            "title": .string(title.isEmpty ? defaultTitle(snap) : title),
            "edition": .from(edition.flatMap { $0.isEmpty ? nil : $0 }),
            "photo_type_id": .from(typeId), "preset_id": .from(presetId),
            "status": .string(finished ? "done" : "in_progress"), "date_exposed": .string(date),
            "exposure_seconds": exposure?["seconds"] ?? .null, "exposure_method": .from(method?.rawValue),
            "notes": .from(notes.isEmpty ? nil : notes), "layers": .array(outLayers), "steps": .array(steps),
        ])
    }

    /// A print started elsewhere (the web page), to carry on with here.
    init?(server p: JSON) {
        guard let id = p["id"].int, let type = p["photo_type_id"].int, let preset = p["preset_id"].int else { return nil }
        photoId = id; typeId = type; presetId = preset
        clientId = p["client_id"].string ?? "photo-\(id)"
        title = p["title"].string ?? ""; edition = p["edition"].string; date = p["date_exposed"].string ?? Clock.today()
        method = p["exposure_method"].string.flatMap(ExposureMethod.init(rawValue:))
        notes = p["notes"].string ?? ""; hasImage = p["image_path"].string != nil
        let ls = p["layers"].array.map { l -> [String: Int] in
            var o: [String: Int] = [:]
            for f in SelectWhat.allCases.map(\.layerField) { if let v = l[f].int { o[f] = v } }
            return o
        }
        layers = ls.isEmpty ? [[:]] : ls
        for s in p["steps"].array {
            guard let sid = s["process_step_id"].int else { continue }
            var r = StepRecord()
            r.seconds = s["seconds"].int; r.manual = r.seconds; r.temp = s["temp"].double; r.ph = s["ph"].double
            r.chemistryId = s["chemistry_id"].int; r.materialId = s["material_id"].int; r.notes = s["notes"].string; r.startedAt = s["started_at"].string
            r.skipped = s["skipped"].flag; r.done = true
            recs["\(sid):\(s["layer_no"].int ?? 0)"] = r
        }
    }

    /// A glop or tissue walk started elsewhere, to carry on with here.
    init?(run j: JSON) {
        guard let id = j["id"].int, let preset = j["preset_id"].int else { return nil }
        runId = id; presetId = preset; typeId = 0; makes = j["makes"].string ?? "chemistry"
        clientId = j["client_id"].string ?? "run-\(id)"
        label = j["label"].string; date = j["made_on"].string ?? Clock.today(); notes = j["notes"].string ?? ""
        volume = j["volume_ml"].double; size = j["size"].string; amountPoured = j["amount_poured"].string
        for s in j["steps"].array {
            guard let sid = s["process_step_id"].int else { continue }
            var r = StepRecord()
            r.seconds = s["seconds"].int; r.manual = r.seconds; r.temp = s["temp"].double; r.amount = s["amount"].double
            r.chemistryId = s["chemistry_id"].int; r.materialId = s["material_id"].int; r.notes = s["notes"].string
            r.startedAt = s["started_at"].string; r.skipped = s["skipped"].flag; r.done = true
            recs["\(sid):0"] = r
        }
        for p in j["pigments"].array {
            guard let sid = p["process_step_id"].int else { continue }
            var r = recs["\(sid):0"] ?? StepRecord(done: true)
            r.pigments = (r.pigments ?? []) + [PigLine(pigmentId: p["pigment_id"].int, grams: p["grams"].double)]
            recs["\(sid):0"] = r
        }
    }

    init(typeId: Int, presetId: Int) { self.typeId = typeId; self.presetId = presetId }

    /// A new walk on this walk-through: a print, or a batch or tissue.
    init(preset p: Preset) {
        typeId = p.photoTypeId; presetId = p.id
        if !p.makesPrint { makes = p.makes }
    }
}
