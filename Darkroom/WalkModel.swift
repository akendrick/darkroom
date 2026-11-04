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

    init(store: AppStore, draft: PrintDraft) {
        self.store = store
        self.clientId = draft.clientId
        self.last = draft
        if store.drafts[clientId] == nil { store.update(draft) }
        if self.draft.page >= pages.count { self.draft.page = pages.count - 1 }
        watchAlarm()
        pushWatch()
    }

    var snap: Snapshot? { store.snapshot }
    var preset: Preset? { snap?.preset(draft.presetId) }
    var pages: [WalkPage] { draft.pages(preset) }
    var page: WalkPage { pages[min(draft.page, pages.count - 1)] }
    var stepPages: [WalkPage] { pages.filter { $0.step != nil } }
    var multiLayer: Bool { draft.layers.count > 1 }

    var header: String {
        guard let n = stepPages.firstIndex(of: page) else { return draft.title.isEmpty ? "Walk-through" : draft.title }
        return "Step \(n + 1)/\(stepPages.count)" + (page.layer > 0 && multiLayer ? " · L\(page.layer)" : "")
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
        if let s = page.step { r.timer.target = readyTime(s); r.temp = s.defaultTemp; r.chemistryId = draft.sameBatch(s) }
        return r
    }

    // MARK: Start page

    var types: [PhotoType] {
        let ps = snap?.presets ?? []
        return (snap?.photoTypes ?? []).filter { t in ps.contains { $0.photoTypeId == t.id } }
    }
    var presetsForType: [Preset] { (snap?.presets ?? []).filter { $0.photoTypeId == draft.typeId } }
    var locked: Bool { draft.photoId != nil }

    func pickType(_ id: Int) {
        let ps = (snap?.presets ?? []).filter { $0.photoTypeId == id }
        guard let p = ps.first(where: \.isDefault) ?? ps.first else { return }
        draft.typeId = id; draft.presetId = p.id
    }
    func pickPreset(_ id: Int) { draft.presetId = id }

    // MARK: Choosing a material

    func chosen(_ what: SelectWhat) -> Int? { draft.layers[max(page.layer, 1) - 1][what.layerField] }

    /// A per-layer page sets that layer; a whole-print page sets every layer.
    func pick(_ what: SelectWhat, _ id: Int?) {
        let targets = page.layer > 0 ? [page.layer - 1] : Array(draft.layers.indices)
        var d = draft
        for i in targets { d.layers[i][what.layerField] = id }
        draft = d
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
        c.removePendingNotificationRequests(withIdentifiers: ["step-timer"])
        let end = rec.timer.endsAt.flatMap { $0 > .now ? $0 : nil }
        StepAlarm.shared.set(end, title: page.step.map { "\($0.name) — time" } ?? "Time")
        guard !StepAlarm.shared.usable, let end, let s = page.step else { return }
        let n = UNMutableNotificationContent()
        n.title = "\(s.name) — time"
        n.body = s.tray.map { "Tray \($0)" } ?? "Next step on the phone"
        n.sound = .default
        n.interruptionLevel = .timeSensitive
        let t = UNTimeIntervalNotificationTrigger(timeInterval: end.timeIntervalSinceNow, repeats: false)
        c.add(UNNotificationRequest(identifier: "step-timer", content: n, trigger: t))
    }

    // MARK: Moving between pages

    /// On Next a step counts as done and its time is fixed: the time the
    /// timer actually ran (the set time plus any time over), else the set time.
    func next() {
        if let s = page.step, !s.isSelect {
            var r = rec
            r.timer.pause()
            r.seconds = r.timer.carried > 0 ? Int(r.timer.carried.rounded()) : (r.manual ?? readyTime(s))
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
        if draft.photoId == nil && draft.page == 0 && !draft.unsent {   // nothing started yet
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

    func finish() {
        var d = draft
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
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: ["step-timer"])
        StepAlarm.shared.set(nil, title: "")
        PhoneWatch.shared.send(.idle)
        LiveTimer.shared.end()
        onClose?()
    }

    // MARK: Watch

    func pushWatch() {
        let s = page.step
        // The Watch keeps to the essentials: no tray.
        let meta = (rec.temp ?? s?.defaultTemp).map { "\($0.formatted()) °C" } ?? ""
        let title: String = switch page {
        case .start: "New print"
        case .finish: "Finish"
        case .step(let st, _): st.name
        }
        // A choice still to make on the phone: the Watch's Next waits for it.
        let canNext = !(s?.isSelect == true && s?.selectWhat.map { chosen($0) == nil } == true)
        PhoneWatch.shared.send(WatchScreen(
            active: true, title: title, step: stepPages.contains(page) ? header.replacingOccurrences(of: "Step ", with: "") : "", detail: meta,
            hasTimer: s.map { !$0.isSelect } ?? false, timer: rec.timer,
            canNext: canNext, nextLabel: page == .finish ? "Finish" : "Next", pageKey: pageKey, sentAt: .now))
        pushLive(title: title, meta: meta)
    }

    /// The same step and timer on the lock screen.
    private func pushLive(title: String, meta: String) {
        var state = StepActivity.ContentState(step: title, detail: header)
        if let s = page.step, !s.isSelect {
            let t = rec.timer
            state.detail = [header, s.tray.map { "Tray \($0)" }, meta.isEmpty ? nil : meta].compactMap { $0 }.joined(separator: " · ")
            if let start = t.startedAt {
                if let end = t.endsAt { state.endsAt = end } else { state.countFrom = start.addingTimeInterval(-t.carried) }
            } else {
                state.still = t.display().text
            }
        }
        LiveTimer.shared.show(print: draft.title.isEmpty ? "Print" : draft.title, state)
    }

    var pageKey: String { "\(clientId)#\(draft.page)" }

    func handle(_ cmd: WatchCommand, on pressedOn: String) {
        // Pressed on a page the phone has already left: show the Watch where we are.
        guard pressedOn == pageKey else { pushWatch(); return }
        switch cmd {
        case .next:
            if let s = page.step, s.isSelect, let w = s.selectWhat, chosen(w) == nil { status = "Choose on the phone first"; pushWatch(); return }
            next()
        case .pause: if page.step.map({ !$0.isSelect }) ?? false { startPause() }
        case .restart: if page.step.map({ !$0.isSelect }) ?? false { reset(); startPause() }
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
