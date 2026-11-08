import Foundation
import Network
import Observation
import UIKit

/// A negative, tissue or support paper added on the phone, waiting to be sent.
struct PendingMaterial: Codable, Equatable {
    var tempId: Int             // below 0, used in drafts until the server gives a real id
    var what: SelectWhat?       // nil: one of the owner's own kinds (kindId)
    var kindId: Int?
    var resource: String?       // else from what / kindId: "pigment" for a new pigment
    var body: JSON
    var label: String
}

/// A batch or tissue a finished walk made, once the server has it: home offers
/// the next walk-through with it already chosen.
struct Made: Equatable, Identifiable {
    let makes: String, id: Int, label: String, typeId: Int?
}

/// Everything the app keeps on the phone, and the queue of things to send.
/// Works the same with or without a connection: changes are saved here first
/// and sent when knotwork.ca can be reached.
@MainActor @Observable
final class AppStore {
    private(set) var server = Server(base: Server.defaultBase, key: Keychain.read())
    var snapshot: Snapshot?
    var drafts: [String: PrintDraft] = [:]
    var pendingMaterials: [PendingMaterial] = []
    var pendingDeletes: [Int] = []      // discarded prints still on the server
    var pendingRunDeletes: [Int] = []   // discarded glop / tissue walks still on the server
    var pendingLayerDeletes: [String] = []  // discarded later layers still on the server: "photoId:layer"
    var made: Made?
    /// Phone-only material id → server id, once sent.
    var idMap: [Int: Int] = [:]
    var online = true
    var syncing = false
    var message: String?

    var signedIn: Bool { server.key != nil }
    var pendingCount: Int {
        pendingMaterials.count + pendingDeletes.count + pendingRunDeletes.count + pendingLayerDeletes.count + drafts.values.filter { $0.unsent || $0.pendingImage != nil }.count
    }

    private let monitor = NWPathMonitor()
    private var flushing = false
    private var flushAgain = false
    private var listsChanged = false
    private var refused: String?     // a material the server turned down, to say so once sending ends

    init() {
        load()
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                guard let self else { return }
                let was = self.online
                self.online = path.status == .satisfied
                if self.online && !was { self.flush() }
            }
        }
        monitor.start(queue: .global(qos: .utility))
    }

    // MARK: Sign in

    func signIn(password: String, base: URL) async throws {
        var s = Server(base: base, key: nil)
        let key = try await s.signIn(password: password, deviceName: UIDevice.current.name)
        Keychain.save(key)
        UserDefaults.standard.set(base.absoluteString, forKey: "server")
        s.key = key
        server = s
        await refresh()
    }

    func signOut() async {
        await server.signOut()
        Keychain.delete()
        server.key = nil
    }

    // MARK: Sync

    /// Sends anything waiting, then fetches the latest lists from the server.
    func refresh() async {
        guard signedIn, !syncing else { return }
        syncing = true; defer { syncing = false }
        await flushNow()
        do {
            let raw = try await server.sync()
            snapshot = Snapshot(raw: raw, fetchedAt: .now)
            // Prints still in progress on the server (started on the web page)
            // can be carried on here. A draft on this phone wins over the server's copy.
            for p in snapshot!.inProgress {
                guard let d = PrintDraft(server: p), !pendingDeletes.contains(d.photoId ?? 0) else { continue }
                if drafts.values.contains(where: { $0.photoId == d.photoId || $0.clientId == d.clientId }) { continue }
                drafts[d.clientId] = d
            }
            for r in snapshot!.making {
                guard let d = PrintDraft(run: r), !pendingRunDeletes.contains(d.runId ?? 0) else { continue }
                if drafts.values.contains(where: { $0.runId == d.runId || $0.clientId == d.clientId }) { continue }
                drafts[d.clientId] = d
            }
            // Forget finished prints the server has, and in-progress ones finished elsewhere.
            let serverOpen = Set(snapshot!.inProgress.compactMap { $0["id"].int })
            let runsOpen = Set(snapshot!.making.compactMap { $0["id"].int })
            drafts = drafts.filter { _, d in
                if d.unsent || d.pendingImage != nil { return true }
                if d.finished { return false }
                if d.newLayer == true { return true }   // its print is still finished until the layer is sent
                if d.isMake { return d.runId == nil || runsOpen.contains(d.runId!) }
                return d.photoId == nil || serverOpen.contains(d.photoId!)
            }
            message = nil
            save()
        } catch let e as ServerError {
            if e.signedOut { Keychain.delete(); server.key = nil }
            message = e.retry ? "Offline — using what's on this phone" : e.message
        } catch { message = error.localizedDescription }
    }

    // MARK: Drafts

    /// Throws a print away: off this phone now, off knotwork.ca with the next send.
    func discard(_ clientId: String) {
        guard let d = drafts.removeValue(forKey: clientId) else { return }
        if let name = d.pendingImage { try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(name)) }
        if let id = d.photoId { deletePrint(id, d) }
        if let id = d.runId { pendingRunDeletes.append(id) }
        save()
        flush()
    }

    /// A print's later layer goes on its own; layer 1 takes the whole print.
    private func deletePrint(_ id: Int, _ d: PrintDraft) {
        if d.layer > 1 { pendingLayerDeletes.append("\(id):\(d.layer)") } else { pendingDeletes.append(id) }
    }

    func update(_ d: PrintDraft, send: Bool = false) {
        var d = d
        d.updatedAt = .now
        if send { d.unsent = true }
        drafts[d.clientId] = d
        save()
        if send { flush() }
    }

    func addMaterial(_ what: SelectWhat, name: String, paperId: Int?) -> Material {
        let temp = -Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000 - 1
        let body: JSON = switch what {
        case .negative: .object(["title_id": .string(name), "date_created": .string(Clock.today())])
        case .carbon_tissue: .object(["title_id": .string(name), "date_poured": .string(Clock.today())])
        case .support_paper: .object(["mark": .string(name), "paper_id": .from(paperId)])
        }
        pendingMaterials.append(PendingMaterial(tempId: temp, what: what, body: body, label: name))
        save(); flush()
        return Material(id: temp, label: name, sub: "added on this phone")
    }

    /// One of the owner's own kinds ("Photo Paper"), queued like the others.
    func addMaterial(kind: Int, name: String, maker: String?) -> Material {
        let temp = -Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000 - 1
        let body: JSON = .object(["kind_id": .from(kind), "label": .string(name), "maker": .from(maker)])
        pendingMaterials.append(PendingMaterial(tempId: temp, what: nil, kindId: kind, body: body, label: name))
        save(); flush()
        return Material(id: temp, label: name, sub: "added on this phone")
    }

    /// A pigment added during a glop walk, queued like a material.
    func addPigment(name: String) -> Pigment {
        let temp = -Int(Date().timeIntervalSince1970 * 1000) % 1_000_000_000 - 1
        pendingMaterials.append(PendingMaterial(tempId: temp, what: nil, resource: "pigment", body: .object(["name": .string(name)]), label: name))
        save(); flush()
        return Pigment(id: temp, name: name)
    }

    /// Server pigments plus any added here and not yet sent.
    var pigments: [Pigment] {
        pendingMaterials.filter { $0.resource == "pigment" }.map { Pigment(id: $0.tempId, name: $0.label) } + (snapshot?.pigments ?? [])
    }
    /// Short codes of pigments not sent yet, for suggested IDs.
    var pendingPigmentCodes: [Int: String] {
        Dictionary(uniqueKeysWithValues: pendingMaterials.filter { $0.resource == "pigment" }.map { ($0.tempId, Pigment(id: $0.tempId, name: $0.label).short) })
    }

    /// Server materials of one of the owner's kinds, plus any added here and not yet sent.
    func items(kind: Int) -> [Material] {
        let local = pendingMaterials.filter { $0.kindId == kind && $0.resource == nil }
            .map { Material(id: $0.tempId, label: $0.label, sub: "added on this phone — sends when online") }
        return local.reversed() + (snapshot?.materials(kind) ?? [])
    }

    /// A chemistry batch mixed now, made on the server straight away (a print's
    /// steps point at it, so it isn't queued like a material).
    func addBatch(label: String, typeId: Int, percent: Double?, volume: Double?) async throws -> Int {
        let body: JSON = .object(["label": .from(label.isEmpty ? nil : label), "type_id": .from(typeId),
                                  "percent_solution": .from(percent), "volume_ml": .from(volume),
                                  "date_created": .string(Clock.today()), "mixed_at": .string(Clock.stamp())])
        let r = try await server.request("darkroom-api.php?res=chemistry", method: "POST", body: body)
        guard let id = r["id"].int else { throw ServerError(message: "Server error", status: 500) }
        if let raw = try? await server.sync() { snapshot = Snapshot(raw: raw, fetchedAt: .now); save() }
        return id
    }

    /// Server materials plus any added on this phone and not yet sent.
    func items(_ what: SelectWhat) -> [Material] {
        let local = pendingMaterials.filter { $0.what == what && $0.kindId == nil && $0.resource == nil }
            .map { Material(id: $0.tempId, label: $0.label, sub: "added on this phone — sends when online") }
        let server = (snapshot?.items(what) ?? []).sorted { $0.id > $1.id }
        return local.reversed() + server
    }

    func attachImage(_ jpeg: Data, to clientId: String) {
        guard var d = drafts[clientId] else { return }
        let name = "\(clientId)-\(Int(Date().timeIntervalSince1970)).jpg"
        try? jpeg.write(to: imagesDir.appendingPathComponent(name), options: .atomic)
        if let old = d.pendingImage { try? FileManager.default.removeItem(at: imagesDir.appendingPathComponent(old)) }
        d.pendingImage = name
        d.hasImage = true
        update(d)
        flush()
    }

    // MARK: Sending

    /// Sends what's waiting, one thing at a time, in the order it was made.
    func flush() { Task { await flushNow() } }

    func flushNow() async {
        guard signedIn else { return }
        if flushing { flushAgain = true; return }
        flushing = true; defer { flushing = false }
        repeat {
            flushAgain = false
            do { try await sendAll() }
            catch let e as ServerError {
                if e.signedOut { Keychain.delete(); server.key = nil; message = "Signed out — sign in again to send" }
                else if e.retry { message = "Not sent yet — kept on this phone" }
                else { message = "Not sent: \(e.message)" }
                return
            } catch { return }
        } while flushAgain
        if pendingCount == 0 { message = refused; refused = nil }
        // New materials went up: fetch the lists so they show with their server names.
        if listsChanged, let raw = try? await server.sync() {
            listsChanged = false
            snapshot = Snapshot(raw: raw, fetchedAt: .now); save()
        }
    }

    private func sendAll() async throws {
        try await sendDeletes()
        // 1. Materials added on the phone, so prints can point at them.
        while let m = pendingMaterials.first {
            let r: JSON
            do { r = try await server.request("darkroom-api.php?res=\(m.resource ?? m.what?.resource ?? "material")", method: "POST", body: m.body) }
            catch let e as ServerError where !e.retry && !e.signedOut {
                // Refused for good (a support paper with no base paper, say): let it
                // go so it doesn't hold up everything behind it, and unchoose it.
                pendingMaterials.removeFirst()
                for (k, var d) in drafts {
                    d.layers = d.layers.map { $0.filter { $0.value != m.tempId } }
                    for (rk, r) in d.recs where r.materialId == m.tempId { d.recs[rk]?.materialId = nil }
                    for (rk, r) in d.recs where r.pigments?.contains(where: { $0.pigmentId == m.tempId }) == true {
                        d.recs[rk]?.pigments = r.pigments?.map { var l = $0; if l.pigmentId == m.tempId { l.pigmentId = nil }; return l }
                    }
                    drafts[k] = d
                }
                refused = "\(m.label) not added: \(e.message)"
                save()
                continue
            }
            guard let id = r["id"].int else { throw ServerError(message: "Server error", status: 500) }
            idMap[m.tempId] = id
            pendingMaterials.removeFirst()
            // Point every draft at the real id now that the server has it.
            for (k, var d) in drafts {
                d.layers = d.layers.map { $0.mapValues { $0 == m.tempId ? id : $0 } }
                for (rk, r) in d.recs where r.materialId == m.tempId { d.recs[rk]?.materialId = id }
                for (rk, r) in d.recs where r.pigments?.contains(where: { $0.pigmentId == m.tempId }) == true {
                    d.recs[rk]?.pigments = r.pigments?.map { var l = $0; if l.pigmentId == m.tempId { l.pigmentId = id }; return l }
                }
                drafts[k] = d
            }
            listsChanged = true
            save()
        }
        // 2. Prints, and glop and tissue walks, oldest change first.
        for key in drafts.values.filter(\.unsent).sorted(by: { $0.updatedAt < $1.updatedAt }).map(\.clientId) {
            guard let d = drafts[key], let body = d.payload(snapshot, ids: idMap) else { continue }
            if d.isMake { try await sendRun(key, d, body); continue }
            let stamp = d.updatedAt
            var photoId = d.photoId
            if photoId == nil {
                var create = body.object; create["client_id"] = .string(d.clientId)
                let r = try await server.request("darkroom-api.php?res=photo", method: "POST", body: .object(create))
                photoId = r["id"].int
                // Sent before (signal dropped before the answer): update that print instead.
                if r["duplicate"].flag, let id = photoId {
                    _ = try await server.request("darkroom-api.php?res=photo&id=\(id)", method: "PATCH", body: body)
                }
            } else {
                _ = try await server.request("darkroom-api.php?res=photo&id=\(photoId!)", method: "PATCH", body: body)
            }
            guard var now = drafts[key] else {
                // Discarded while it was being sent: take it off the server too.
                if let photoId { deletePrint(photoId, d); save(); try await sendDeletes() }
                continue
            }
            now.photoId = photoId
            now.newLayer = nil      // on the server now, in progress
            if now.updatedAt == stamp { now.unsent = false }   // not changed while sending
            drafts[key] = now
            save()
        }
        // 3. Photos, once their print is on the server.
        for key in drafts.values.filter({ $0.pendingImage != nil && $0.photoId != nil }).map(\.clientId) {
            guard let d = drafts[key], let name = d.pendingImage, let pid = d.photoId else { continue }
            let url = imagesDir.appendingPathComponent(name)
            if let jpeg = try? Data(contentsOf: url) { _ = try await server.upload(jpeg: jpeg, photoId: pid) }
            try? FileManager.default.removeItem(at: url)
            guard var now = drafts[key] else { continue }
            if now.pendingImage == name { now.pendingImage = nil }
            drafts[key] = now
            save()
        }
        try await sendDeletes()
        // Finished and fully sent: nothing more to keep.
        drafts = drafts.filter { !($0.value.finished && !$0.value.unsent && $0.value.pendingImage == nil) }
        save()
    }

    /// A glop or tissue walk. Finished, the server makes the batch or tissue
    /// and says which; home then offers the next walk-through with it.
    private func sendRun(_ key: String, _ d: PrintDraft, _ body: JSON) async throws {
        let stamp = d.updatedAt
        var r: JSON
        if let id = d.runId {
            r = try await server.request("darkroom-api.php?res=make_run&id=\(id)", method: "PATCH", body: body)
        } else {
            var create = body.object; create["client_id"] = .string(d.clientId)
            r = try await server.request("darkroom-api.php?res=make_run", method: "POST", body: .object(create))
            if r["duplicate"].flag, let id = r["id"].int {
                r = try await server.request("darkroom-api.php?res=make_run&id=\(id)", method: "PATCH", body: body)
                r = .object(r.object.merging(["id": .from(id)]) { a, _ in a })
            }
        }
        let runId = d.runId ?? r["id"].int
        let madeId = r["chemistry_id"].int ?? r["carbon_tissue_id"].int
        guard var now = drafts[key] else {
            if let runId { pendingRunDeletes.append(runId); save(); try await sendDeletes() }
            return
        }
        now.runId = runId
        if let madeId { now.madeId = madeId }
        if now.updatedAt == stamp { now.unsent = false }
        drafts[key] = now
        if now.finished, !now.unsent, let madeId {
            listsChanged = true
            let label = body["label"].string ?? ""
            made = Made(makes: now.makes ?? "chemistry", id: madeId, label: label, typeId: snapshot?.preset(now.presetId)?.chemistryTypeId)
        }
        save()
    }

    private func sendDeletes() async throws {
        while let id = pendingRunDeletes.first {
            do { _ = try await server.request("darkroom-api.php?res=make_run&id=\(id)", method: "DELETE") }
            catch let e as ServerError where !e.retry && !e.signedOut { }   // already gone
            pendingRunDeletes.removeFirst()
            save()
        }
        while let pl = pendingLayerDeletes.first {
            let p = pl.split(separator: ":")
            do { _ = try await server.request("darkroom-api.php?res=photo&id=\(p[0])&layer=\(p.count > 1 ? p[1] : "0")", method: "DELETE") }
            catch let e as ServerError where !e.retry && !e.signedOut { }   // already gone
            pendingLayerDeletes.removeFirst()
            save()
        }
        while let id = pendingDeletes.first {
            do { _ = try await server.request("darkroom-api.php?res=photo&id=\(id)", method: "DELETE") }
            catch let e as ServerError where !e.retry && !e.signedOut { }   // already gone
            pendingDeletes.removeFirst()
            save()
        }
    }

    // MARK: Files

    private struct Saved: Codable {
        var snapshot: Snapshot?
        var drafts: [String: PrintDraft]
        var pendingMaterials: [PendingMaterial]
        var idMap: [Int: Int]
        var pendingDeletes: [Int]?
        var pendingRunDeletes: [Int]?
        var pendingLayerDeletes: [String]?
    }

    private var folder: URL {
        let u = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Darkroom", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
    var imagesDir: URL {
        let u = folder.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    func save() {
        let s = Saved(snapshot: snapshot, drafts: drafts, pendingMaterials: pendingMaterials, idMap: idMap, pendingDeletes: pendingDeletes,
                      pendingRunDeletes: pendingRunDeletes, pendingLayerDeletes: pendingLayerDeletes)
        if let d = try? JSONEncoder().encode(s) {
            try? d.write(to: folder.appendingPathComponent("state.json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        }
    }

    private func load() {
        if let saved = UserDefaults.standard.string(forKey: "server"), let u = URL(string: saved) { server.base = u }
        guard let d = try? Data(contentsOf: folder.appendingPathComponent("state.json")),
              let s = try? JSONDecoder().decode(Saved.self, from: d) else { return }
        snapshot = s.snapshot; drafts = s.drafts; pendingMaterials = s.pendingMaterials; idMap = s.idMap
        pendingDeletes = s.pendingDeletes ?? []; pendingRunDeletes = s.pendingRunDeletes ?? []
        pendingLayerDeletes = s.pendingLayerDeletes ?? []
        for k in drafts.keys { drafts[k]?.upgradeToLayers() }
    }
}
