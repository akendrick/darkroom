import AppIntents

/// "Siri, Darkroom next": Next, the timer's start / pause and restart, the
/// temperature and the choice on a choose page by voice, for wet or gloved
/// hands. Next and the timer do what the Watch's buttons do. All act on the
/// walk-through that is open (in multi-print, the print last changed). Siri
/// needs the app's name in every phrase, so a bare "Siri, next" can't work.
@MainActor
enum Voice {
    /// Set by the app to its walk-throughs.
    static weak var walks: Walks?
    /// The print last changed, so a voice command in multi-print goes to it.
    static var lastClientId: String?

    static let noWalk = "No walk-through is open."

    /// The walk-through a voice command is for, and "Left: " / "Right: " to start the answer with.
    static func target() -> (WalkModel, String)? {
        guard let w = walks, let m = w.open.first(where: { $0.clientId == lastClientId }) ?? w.right ?? w.left else { return nil }
        return (m, m.sideName.map { "\($0.capitalized): " } ?? "")
    }

    static func run(_ cmd: WatchCommand) -> String {
        guard let (m, side) = target() else { return noWalk }
        switch cmd {
        case .next:
            if m.choiceMissing { return side + "Choose on the phone first." }
            let finishing = m.page == .finish
            m.handle(.next, on: m.pageKey)
            if finishing { return side + "Finished." }
            return side + (m.page.step?.name ?? (m.page == .finish ? "Finish" : "Next page"))
        case .pause, .restart:
            guard m.page.step?.hasTimer == true else { return side + "This step has no timer." }
            m.handle(cmd, on: m.pageKey)
            let running = m.rec.timer.isRunning
            return side + (cmd == .restart ? "Timer restarted." : running ? "Timer started." : "Timer paused.")
        }
    }
}

// MARK: Temperature

extension WalkModel {
    /// The temperature box shows on this page.
    var takesTemp: Bool { page.step.map { $0.asksTemp || $0.defaultTemp != nil } ?? false }
}

struct SetTemperatureIntent: AppIntent {
    static let title: LocalizedStringResource = "Set the temperature"
    static let description = IntentDescription("Sets the step's temperature in °C, to the nearest half degree.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Temperature (°C)", inclusiveRange: (0, 60)) var degrees: Double?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let (m, side) = Voice.target() else { return .result(dialog: "\(Voice.noWalk)") }
        guard m.takesTemp else { return .result(dialog: "\(side)This step has no temperature.") }
        guard let degrees else { throw $degrees.needsValueError("What temperature, in degrees?") }
        let t = (degrees * 2).rounded() / 2
        m.rec.temp = t
        return .result(dialog: "\(side)\(t.formatted()) degrees.")
    }
}

// MARK: Choosing

/// One thing to choose on a choose page: a negative, paper, tissue, batch, or
/// one of the owner's own kinds of material.
struct VoiceOption: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Option"
    static let defaultQuery = VoiceOptionQuery()
    let id: Int
    let name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// The choices on the open page, newest first as on the phone. A spoken
/// number ("two", "second") picks by place in that list.
struct VoiceOptionQuery: EntityStringQuery {
    @MainActor func entities(for ids: [Int]) async throws -> [VoiceOption] {
        let all = Voice.options()
        return ids.compactMap { id in all.first { $0.id == id } }
    }
    @MainActor func suggestedEntities() async throws -> [VoiceOption] { Voice.options() }
    @MainActor func entities(matching text: String) async throws -> [VoiceOption] {
        let all = Voice.options()
        if let n = Voice.place(text), all.indices.contains(n - 1) { return [all[n - 1]] }
        let words = Voice.simple(text)
        let exact = all.filter { Voice.simple($0.name) == words }
        if !exact.isEmpty { return exact }
        return all.filter { Voice.simple($0.name).contains(words) || words.contains(Voice.simple($0.name)) }
    }
}

extension Voice {
    /// What the open page offers to choose; empty when it isn't a choose page.
    static func options() -> [VoiceOption] {
        guard let (m, _) = target(), let s = m.page.step, s.isSelect else { return [] }
        if let kind = s.materialKindId { return m.store.items(kind: kind).map { VoiceOption(id: $0.id, name: $0.label) } }
        if s.choosesBatch { return m.batchList(s).map { VoiceOption(id: $0.id, name: $0.label) } }
        if let what = s.selectWhat { return m.store.items(what).map { VoiceOption(id: $0.id, name: $0.label) } }
        return []
    }

    static func choose(_ id: Int) {
        guard let (m, _) = target(), let s = m.page.step else { return }
        if s.materialKindId != nil { m.pickMaterial(id) }
        else if s.choosesBatch { m.pickBatch(id) }
        else if let what = s.selectWhat { m.pick(what, id) }
    }

    /// "Which one? 1, Glop A. 2, Glop B…" — at most five, so it stays short.
    static func menu(_ all: [VoiceOption]) -> String {
        let shown = all.prefix(5).enumerated().map { "\($0.offset + 1), \($0.element.name)" }.joined(separator: ". ")
        return "Which one? " + shown + (all.count > 5 ? ". Or say its name." : ".")
    }

    /// Lower case, letters and digits only, single spaces.
    static func simple(_ s: String) -> String {
        String(s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : " " }).split(separator: " ").joined(separator: " ")
    }

    /// "2", "two", "second", "number two" → 2.
    static func place(_ text: String) -> Int? {
        let words = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten"]
        let nth = ["first", "second", "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth"]
        var t = simple(text)
        for lead in ["number ", "the "] where t.hasPrefix(lead) { t.removeFirst(lead.count) }
        if let n = Int(t) { return n }
        if let i = words.firstIndex(of: t) { return i + 1 }
        if let i = nth.firstIndex(of: t) { return i + 1 }
        return nil
    }
}

struct SelectOptionIntent: AppIntent {
    static let title: LocalizedStringResource = "Choose"
    static let description = IntentDescription("Chooses one of the options on the open choose page.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Option") var option: VoiceOption?

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        guard let (m, side) = Voice.target() else { return .result(dialog: "\(Voice.noWalk)") }
        let all = Voice.options()
        if all.isEmpty {
            return .result(dialog: "\(side)\(m.page.step?.isSelect == true ? "There's nothing to choose yet. Add one on the phone." : "Nothing to choose on this page.")")
        }
        guard let option else { throw $option.needsValueError("\(side)\(Voice.menu(all))") }
        Voice.choose(option.id)
        return .result(dialog: "\(side)\(option.name). Say Darkroom next to go on.")
    }
}

// MARK: Next and the timer

struct NextStepIntent: AppIntent {
    static let title: LocalizedStringResource = "Next step"
    static let description = IntentDescription("Moves the open walk-through on to its next step.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Voice.run(.next))")
    }
}

struct StartPauseTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Start or pause the timer"
    static let description = IntentDescription("Starts the step's timer, or pauses it if it is running.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Voice.run(.pause))")
    }
}

struct RestartTimerIntent: AppIntent {
    static let title: LocalizedStringResource = "Restart the timer"
    static let description = IntentDescription("Sets the step's timer back to the start and runs it.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @MainActor func perform() async throws -> some IntentResult & ProvidesDialog {
        .result(dialog: "\(Voice.run(.restart))")
    }
}

struct DarkroomShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NextStepIntent(), phrases: [
            "\(.applicationName) next",
            "Next in \(.applicationName)",
            "Next step in \(.applicationName)",
            "\(.applicationName) next step",
        ], shortTitle: "Next step", systemImageName: "arrow.right.circle")
        AppShortcut(intent: StartPauseTimerIntent(), phrases: [
            "\(.applicationName) start",
            "\(.applicationName) pause",
            "\(.applicationName) go",
            "Start the \(.applicationName) timer",
            "Pause the \(.applicationName) timer",
        ], shortTitle: "Start / pause timer", systemImageName: "playpause")
        AppShortcut(intent: RestartTimerIntent(), phrases: [
            "\(.applicationName) restart",
            "Restart the \(.applicationName) timer",
        ], shortTitle: "Restart timer", systemImageName: "arrow.counterclockwise")
        AppShortcut(intent: SetTemperatureIntent(), phrases: [
            "\(.applicationName) temperature",
            "\(.applicationName) temp",
            "Set the \(.applicationName) temperature",
        ], shortTitle: "Temperature", systemImageName: "thermometer.medium")
        AppShortcut(intent: SelectOptionIntent(), phrases: [
            "\(.applicationName) select",
            "\(.applicationName) choose",
            "Choose in \(.applicationName)",
        ], shortTitle: "Choose", systemImageName: "checklist")
    }
}
