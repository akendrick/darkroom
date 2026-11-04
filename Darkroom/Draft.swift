import Foundation

/// What was recorded on one step page.
struct StepRecord: Codable, Equatable {
    var timer = StepTimer()
    var manual: Int?            // typed time, seconds
    var temp: Double?
    var ph: Double?
    var chemistryId: Int?
    var notes: String?
    var startedAt: String?      // local "YYYY-MM-DD HH:MM:SS"
    var seconds: Int?           // fixed on Next
    var skipped = false
    var done = false            // set by Next or Skip only
    var alarmed = false
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

    var id: String { clientId }

    static func key(_ step: Step, layer: Int) -> String { "\(step.id):\(layer)" }
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

    func defaultTitle(_ snap: Snapshot?) -> String { "\(snap?.typeName(typeId) ?? "Print") \(date)" }

    /// The print as darkroom-api.php takes it. `ids` turns phone-only material
    /// ids into server ones; nil while one is still unsent.
    func payload(_ snap: Snapshot?, ids: [Int: Int]) -> JSON? {
        var steps: [JSON] = []
        for page in pages(snap?.preset(presetId)) {
            guard case .step(let s, let layer) = page, !s.isSelect,
                  let r = recs[Self.key(s, layer: layer)], r.done else { continue }
            steps.append(.object([
                "process_step_id": .from(s.id), "layer_no": .from(layer), "name": .string(s.name),
                "kind": .string(s.kind), "tray": .from(s.tray), "chemistry_id": .from(r.chemistryId),
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
            r.chemistryId = s["chemistry_id"].int; r.notes = s["notes"].string; r.startedAt = s["started_at"].string
            r.skipped = s["skipped"].flag; r.done = true
            recs["\(sid):\(s["layer_no"].int ?? 0)"] = r
        }
    }

    init(typeId: Int, presetId: Int) { self.typeId = typeId; self.presetId = presetId }
}
