import AudioToolbox
import Foundation
import Observation
import UIKit
import UserNotifications

/// The walk-through for one print: pages, timers and what each page records.
/// Every change is saved on the phone at once; every Next sends the whole
/// print (or queues it when offline).
@MainActor @Observable
final class WalkModel {
    let store: AppStore
    let clientId: String
    /// The print lives in the store, which also sends it and fills in the
    /// server's id; this is only a fallback once the store has let it go.
    private var last: PrintDraft
    var draft: PrintDraft {
        get { store.drafts[clientId] ?? last }
        set { last = newValue; store.update(newValue); pushWatch() }
    }
    var status: String?
    private var alarmTask: Task<Void, Never>?

    var onClose: (() -> Void)?

    /// The print as it was when opened, for Exit without saving; nil when it
    /// started here, so there is nothing to go back to.
    private var opened: PrintDraft?

    /// Which half of the screen in multi-print; nil with one print. The left
    /// one is shown, and alerts, black on red.
    enum Side { case left, right }
    var side: Side? {
        didSet { if side != oldValue { pushWatch(); scheduleAlarm() } }
    }
    /// "LEFT" or "RIGHT" in multi-print, so an alert says which print it's for.
    var sideName: String? { side.map { $0 == .left ? "LEFT" : "RIGHT" } }

    init(store: AppStore, draft: PrintDraft, side: Side? = nil) {
        self.store = store
        self.clientId = draft.clientId
        self.side = side
        self.last = draft
        if store.drafts[clientId] == nil {
            if draft.recordId != nil && draft.newLayer != true { opened = draft }   // carried on from knotwork.ca
            store.update(draft)
        } else { opened = store.drafts[clientId] }
        if self.draft.page >= pages.count { self.draft.page = pages.count - 1 }
        watchAlarm()
        pushWatch()
    }

    var snap: Snapshot? { store.snapshot }
    var preset: Preset? { snap?.preset(draft.presetId) }
    var pages: [WalkPage] { draft.pages(preset) }
    var page: WalkPage { pages[min(draft.page, pages.count - 1)] }
    var stepPages: [WalkPage] { pages.filter { $0.step != nil } }
    /// "L2" on a print's second layer and after.
    var layerTag: String? { !draft.isMake && draft.layer > 1 ? "L\(draft.layer)" : nil }

    var header: String {
        guard let n = stepPages.firstIndex(of: page) else {
            if draft.isMake { return preset?.name ?? "Walk-through" }
            return draft.title.isEmpty ? "Walk-through" : draft.title
        }
        return "Step \(n + 1)/\(stepPages.count)" + (layerTag.map { " · " + $0 } ?? "")
    }

    // MARK: The current step's record

    var key: String? { page.step.map { PrintDraft.key($0, layer: page.layer) } }

    var rec: StepRecord {
        get { key.flatMap { draft.recs[$0] } ?? fresh() }
        set { if let key { draft.recs[key] = newValue } }
    }

    /// A new record starts from the preset: its time, temperature and batch.
    private func fresh() -> StepRecord {
        var r = StepRecord()
        if let s = page.step {
            r.timer.target = readyTime(s); r.temp = s.defaultTemp; r.chemistryId = draft.sameBatch(s)
            // Add steps start from the recipe; changing them changes only today's.
            if s.isPigment { r.pigments = [PigLine(pigmentId: s.pigmentId, grams: s.defaultAmount)] }
            else if s.isAdd { r.amount = s.defaultAmount }
        }
        return r
    }

    // MARK: Start page

    /// Prints by kind, then the chemistry recipes, then tissue.
    var groups: [WalkGroup] { WalkGroup.all(snap).filter { draft.layer == 1 || $0.id.hasPrefix("p:") } }
    var group: String? { preset?.group }
    var presetsInGroup: [Preset] { (snap?.presets ?? []).filter { $0.group == group } }
    /// The walk-through can't change once something is recorded; a new layer
    /// picks its own until then.
    var locked: Bool { draft.recordId != nil && !(draft.newLayer == true && draft.recs.isEmpty) }

    func pickGroup(_ g: String) {
        let ps = (snap?.presets ?? []).filter { $0.group == g }
        guard let p = ps.first(where: \.isDefault) ?? ps.first else { return }
        pickPreset(p.id)
    }
    func pickPreset(_ id: Int) {
        guard let p = snap?.preset(id) else { return }
        var d = draft
        d.presetId = id; d.makes = p.makesPrint ? nil : p.makes
        if d.layer == 1 { d.typeId = p.photoTypeId }   // a later layer keeps the print's type
        draft = d
    }

    // MARK: Add / measure

    var pigLines: [PigLine] {
        get { rec.pigments ?? [PigLine(pigmentId: page.step?.pigmentId, grams: page.step?.defaultAmount)] }
        set { rec.pigments = newValue }
    }
    /// Keeps the recipe's starting values on the page, so the rows hold still.
    func keepDefaults() {
        guard key != nil else { return }
        var r = rec
        if page.step?.isPigment == true, r.pigments == nil { r.pigments = pigLines }
        rec = r
    }

    func addPigment(name: String) {
        let p = store.addPigment(name: name)
        var lines = pigLines
        if let i = lines.firstIndex(where: { $0.pigmentId == nil }) { lines[i].pigmentId = p.id } else { lines.append(PigLine(pigmentId: p.id)) }
        pigLines = lines
        status = "Added \(name)"
    }

    // MARK: Choosing a batch

    /// Batches of the step's type, newest first: the glop for a tissue.
    func batchList(_ s: Step) -> [Batch] { batches(for: s).sorted { $0.id > $1.id } }

    func pickBatch(_ id: Int) {
        var r = rec
        r.chemistryId = id; r.done = true
        if r.startedAt == nil { r.startedAt = Clock.stamp() }
        rec = r
    }

    // MARK: Choosing a material

    func chosen(_ what: SelectWhat) -> Int? {
        let i = draft.layerIndex(page.layer)
        return draft.layers.indices.contains(i) ? draft.layers[i][what.layerField] : nil
    }

    /// A print walk sets its one layer; in a batch or tissue walk a per-layer
    /// page sets that layer and a whole-walk page every layer.
    func pick(_ what: SelectWhat, _ id: Int?) {
        let targets = !draft.isMake ? [0] : page.layer > 0 ? [page.layer - 1] : Array(draft.layers.indices)
        var d = draft
        for i in targets { d.layers[i][what.layerField] = id }
        draft = d
    }

    /// A choose page with nothing chosen yet: Next waits for it.
    var choiceMissing: Bool {
        guard let s = page.step, s.isSelect else { return false }
        if s.materialKindId != nil { return rec.materialId == nil }
        if s.choosesBatch { return rec.chemistryId == nil }
        return s.selectWhat.map { chosen($0) == nil } ?? false
    }

    /// One of the owner's own kinds of material. On a choose page that's the
    /// page done; on a timed page Next still finishes it.
    func pickMaterial(_ id: Int?) {
        var r = rec
        r.materialId = id
        if page.step?.isSelect == true { r.done = id != nil; if r.startedAt == nil { r.startedAt = Clock.stamp() } }
        rec = r
    }

    func addMaterial(kind: Int, name: String, maker: String?) {
        let m = store.addMaterial(kind: kind, name: name, maker: maker)
        pickMaterial(m.id)
        status = "Added \(name)"
    }

    func addMaterial(_ what: SelectWhat, name: String, paperId: Int?) {
        let m = store.addMaterial(what, name: name, paperId: paperId)
        pick(what, m.id)
        status = "Added \(name)"
    }

    /// The batches of the step's chemistry type, or every batch when it names none.
    func batches(for s: Step) -> [Batch] {
        let all = snap?.batches ?? []
        guard let t = s.chemistryTypeId else { return all }
        return all.filter { $0.typeId == t }
    }

    func addBatch(label: String, typeId: Int, percent: Double?, volume: Double?) async {
        do {
            let id = try await store.addBatch(label: label, typeId: typeId, percent: percent, volume: volume)
            rec.chemistryId = id
            status = "Added " + (label.isEmpty ? "the batch" : label)
        } catch let e as ServerError {
            status = e.retry ? "A new batch needs a connection" : "Not added: \(e.message)"
        } catch { status = "Not added: \(error.localizedDescription)" }
    }

    // MARK: Timer

    var target: Int? { rec.manual ?? page.step.flatMap(readyTime) }

    /// The time a step starts with, so it's tap and go: the preset's, else the
    /// time this step took on the last print that had it.
    func readyTime(_ s: Step) -> Int? {
        if let t = s.defaultSeconds { return t }
        let mine = store.drafts.values.filter { $0.clientId != clientId }.sorted { $0.updatedAt > $1.updatedAt }
        for d in mine {
            if let r = d.recs.first(where: { $0.key.hasPrefix("\(s.id):") && $0.value.done && !$0.value.skipped })?.value,
               let t = r.seconds { return t }
        }
        for p in (snap?.inProgress ?? []) + (snap?.recent ?? []) {
            for st in p["steps"].array where st["process_step_id"].int == s.id && !st["skipped"].flag {
                if let t = st["seconds"].int { return t }
            }
        }
        return nil
    }

    func startPause() {
        var r = rec
        r.timer.target = target
        if r.timer.isRunning { r.timer.pause() }
        else { if r.startedAt == nil { r.startedAt = Clock.stamp() }; r.timer.start() }
        rec = r
        scheduleAlarm()
    }

    func reset() {
        var r = rec
        r.timer.reset(); r.alarmed = false; r.startedAt = nil
        rec = r
        scheduleAlarm()
    }

    /// Typed time. Returns false if it isn't a time.
    @discardableResult func setManual(_ text: String) -> Bool {
        switch Duration.parse(text) {
        case .empty: setManual(seconds: nil)
        case .seconds(let s): setManual(seconds: s)
        case .invalid: return false
        }
        return true
    }

    /// A time from the scroll wheels; nil (or zero) goes back to the step's own.
    func setManual(seconds: Int?) {
        var r = rec
        r.manual = seconds == 0 ? nil : seconds
        r.timer.target = r.manual ?? page.step.flatMap(readyTime)
        r.alarmed = false
        rec = r
        scheduleAlarm()
    }

    /// Rings once when the running countdown passes zero, while the app is open.
    private func watchAlarm() {
        alarmTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let self, let key = self.key, var r = self.draft.recs[key], r.timer.isRunning,
                      !r.alarmed, let left = r.timer.remaining(), left <= 0 else { continue }
                r.alarmed = true
                self.draft.recs[key] = r
                if !StepAlarm.shared.usable { Alarm.ring() }   // else AlarmKit rings it
            }
        }
    }

    /// The same alarm when the phone is locked or the app is in the background:
    /// AlarmKit's, or a notification where that isn't allowed.
    private func scheduleAlarm() {
        let c = UNUserNotificationCenter.current()
        c.removePendingNotificationRequests(withIdentifiers: [notificationId])
        let end = rec.timer.endsAt.flatMap { $0 > .now ? $0 : nil }
        let title = [sideName, page.step.map { "\($0.name) — time" } ?? "Time"].compactMap { $0 }.joined(separator: " · ")
        StepAlarm.shared.set(clientId, end, title: title)
        guard !StepAlarm.shared.usable, let end, let s = page.step else { return }
        let n = UNMutableNotificationContent()
        n.title = title
        n.body = s.tray.map { "Tray \($0)" } ?? "Next step on the phone"
        n.sound = .default
        n.interruptionLevel = .timeSensitive
        let t = UNTimeIntervalNotificationTrigger(timeInterval: end.timeIntervalSinceNow, repeats: false)
        c.add(UNNotificationRequest(identifier: notificationId, content: n, trigger: t))
    }

    private var notificationId: String { "step-timer-\(clientId)" }

    // MARK: Moving between pages

    /// On Next a step counts as done and its time is fixed: the time the
    /// timer actually ran (the set time plus any time over), else the set time.
    func next() {
        if let s = page.step, !s.isSelect {
            var r = rec
            r.timer.pause()
            r.seconds = !s.timed ? nil : r.timer.carried > 0 ? Int(r.timer.carried.rounded()) : (r.manual ?? readyTime(s))
            if r.startedAt == nil { r.startedAt = Clock.stamp() }
            r.skipped = false; r.done = true
            rec = r
        }
        if page == .finish { finish(); return }
        var d = draft
        d.page = min(pages.count - 1, d.page + 1)
        send(d)
        scheduleAlarm()
    }

    func back() {
        draft.page = max(0, draft.page - 1)
        scheduleAlarm()
    }

    func skip() {
        guard let key else { return }
        var d = draft
        d.recs[key] = StepRecord(startedAt: Clock.stamp(), skipped: true, done: true)
        d.page = min(pages.count - 1, d.page + 1)
        send(d)
        scheduleAlarm()
    }

    /// Sends the print as it is now, and stays on this page.
    func saveNow() {
        send(draft)
        status = "Saved"
    }

    /// Saves and leaves; the print stays "in progress" to carry on later.
    func saveAndExit() {
        if (draft.recordId == nil || draft.newLayer == true) && draft.page == 0 && !draft.unsent && draft.recs.isEmpty {   // nothing started yet
            store.drafts[clientId] = nil; store.save()
        } else {
            send(draft)
        }
        close()
    }

    /// Throws the print away without saving: nothing from it is kept, here
    /// or on knotwork.ca.
    func discard() {
        store.discard(clientId)
        close()
    }

    /// Leaves without keeping this visit's changes: a print started here is
    /// thrown away; one opened from earlier goes back to how it was (and is
    /// sent like that, since each page was sent as it went).
    func exitWithoutSaving() {
        guard var d = opened else { return discard() }
        d.photoId = d.photoId ?? draft.photoId
        d.runId = d.runId ?? draft.runId
        if d.recordId == nil { last = d; store.update(d) } else { send(d) }
        close()
    }

    var startedHere: Bool { opened == nil }

    func finish() {
        var d = draft
        if d.isMake, (d.label ?? "").isEmpty { d.label = d.suggestedId(snap, pending: store.pendingPigmentCodes) }
        d.finished = true
        send(d)
        close()
    }

    /// Saves and marks the print for sending (now, or when there's a connection).
    private func send(_ d: PrintDraft) {
        last = d
        store.update(d, send: true)
        pushWatch()
    }

    private func close() {
        alarmTask?.cancel()
        // "step-timer" is from before multi-print.
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationId, "step-timer"])
        StepAlarm.shared.set(clientId, nil, title: "")
        PhoneWatch.shared.send(.idle)
        LiveTimer.shared.end(key: clientId)
        onClose?()
    }

    // MARK: Watch

    func pushWatch() {
        let s = page.step
        // The Watch keeps to the essentials: no tray.
        let meta = (rec.temp ?? s?.defaultTemp).map { "\($0.formatted()) °C" } ?? ""
        var title: String = switch page {
        case .start: draft.makes == "chemistry" ? "New batch" : draft.makes == "tissue" ? "New tissue" : "New print"
        case .finish: "Finish"
        case .step(let st, _): st.name
        }
        // Multi-print: the Watch shows the print last changed, so say which.
        if let side { title = (side == .left ? "L · " : "R · ") + title }
        // A choice still to make on the phone: the Watch's Next waits for it.
        let canNext = !choiceMissing
        PhoneWatch.shared.send(WatchScreen(
            active: true, title: title, step: stepPages.contains(page) ? header.replacingOccurrences(of: "Step ", with: "") : "", detail: meta,
            hasTimer: s?.hasTimer ?? false, timer: rec.timer,
            canNext: canNext, nextLabel: page == .finish ? "Finish" : "Next", pageKey: pageKey, sentAt: .now))
        pushLive(title: title, meta: meta)
    }

    /// The same step and timer on the lock screen.
    private func pushLive(title: String, meta: String) {
        var state = StepActivity.ContentState(step: title, detail: header)
        if let s = page.step, s.hasTimer {
            let t = rec.timer
            state.detail = [header, s.tray.map { "Tray \($0)" }, meta.isEmpty ? nil : meta].compactMap { $0 }.joined(separator: " · ")
            if let start = t.startedAt {
                if let end = t.endsAt { state.endsAt = end } else { state.countFrom = start.addingTimeInterval(-t.carried) }
            } else {
                state.still = t.display().text
            }
        }
        let name = draft.title.isEmpty ? "Print" : draft.title
        LiveTimer.shared.show(key: clientId, print: [sideName, name].compactMap { $0 }.joined(separator: " · "),
                              inverted: side == .left, state)
    }

    var pageKey: String { "\(clientId)#\(draft.page)" }

    func handle(_ cmd: WatchCommand, on pressedOn: String) {
        // Pressed on a page the phone has already left: show the Watch where we are.
        guard pressedOn == pageKey else { pushWatch(); return }
        switch cmd {
        case .next:
            if choiceMissing { status = "Choose on the phone first"; pushWatch(); return }
            next()
        case .pause: if page.step?.hasTimer == true { startPause() }
        case .restart: if page.step?.hasTimer == true { reset(); startPause() }
        }
    }
}

/// Sound and vibration when a countdown runs out.
enum Alarm {
    static func ring() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        for i in 0..<3 {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.6) {
                AudioServicesPlayAlertSound(SystemSoundID(1005))
            }
        }
    }
}
