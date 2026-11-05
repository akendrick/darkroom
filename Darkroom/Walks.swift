import SwiftUI

/// The walk-throughs open on the phone: one, or two in multi-print — side
/// by side with the phone sideways, one above the other with it upright.
/// With one print it's on the right.
@MainActor @Observable
final class Walks {
    let store: AppStore
    var right: WalkModel?
    var left: WalkModel?
    var multi = false {
        didSet { if multi != oldValue { Orientation.set(multi ? .allButUpsideDown : .portrait) } }
    }

    var isOpen: Bool { multi || right != nil || left != nil }
    var open: [WalkModel] { [left, right].compactMap { $0 } }

    init(store: AppStore) {
        self.store = store
        // A Watch press goes to the print it was made on.
        PhoneWatch.shared.onCommand = { [weak self] cmd, page in
            guard let self else { return }
            if let m = self.open.first(where: { page.hasPrefix($0.clientId + "#") }) { m.handle(cmd, on: page) }
            else { (self.right ?? self.left)?.pushWatch() }
        }
    }

    /// Starts with the preset the last print used, else the default one.
    func start(left: Bool = false) {
        guard let snap = store.snapshot else { return }
        let lastPreset = snap.recent.first?["preset_id"].int ?? snap.inProgress.first?["preset_id"].int
        guard let p = snap.preset(lastPreset) ?? snap.presets.first(where: \.isDefault) ?? snap.presets.first else { return }
        let d = PrintDraft(typeId: p.photoTypeId, presetId: p.id)
        store.update(d)
        show(d, left: left)
    }

    /// Carries on at the first page not done yet.
    func resume(_ d: PrintDraft, left: Bool = false) {
        var d = d
        let pages = d.pages(store.snapshot?.preset(d.presetId))
        if d.page == 0, let i = pages.indices.dropFirst().first(where: { !d.isDone(pages[$0]) }) { d.page = i }
        show(d, left: left)
    }

    private func show(_ d: PrintDraft, left onLeft: Bool) {
        let m = WalkModel(store: store, draft: d, side: multi ? (onLeft ? .left : .right) : nil)
        m.onClose = { [weak self, weak m] in self?.closed(m) }
        if onLeft { left = m } else { right = m }
    }

    private func closed(_ m: WalkModel?) {
        if left === m { left = nil }
        if right === m { right = nil }
        if open.isEmpty { multi = false }
        else { open.first?.pushWatch() }      // the Watch follows the print still going
    }

    /// Two halves, following the phone: this print on the right (or below),
    /// another can start on the left (or above).
    func split() {
        multi = true
        right?.side = .right
        left?.side = .left
    }

    /// Back to one print, full screen and upright (only with one half empty).
    func single() {
        guard open.count <= 1 else { return }
        let m = left ?? right
        left = nil; right = m
        multi = false
        m?.side = nil
    }
}

/// Which way the phone's screen may turn: upright, or either way in multi-print.
enum Orientation {
    static var mask: UIInterfaceOrientationMask = .portrait

    @MainActor static func set(_ m: UIInterfaceOrientationMask) {
        mask = m
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for w in scene.windows {
                var vc = w.rootViewController
                while let c = vc { c.setNeedsUpdateOfSupportedInterfaceOrientations(); vc = c.presentedViewController }
            }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: m)) { _ in }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Orientation.mask
    }
}

/// The open walk-through, or the two halves of multi-print: the left (or
/// top) one black on red, the other as usual.
struct WalkHost: View {
    @Environment(Walks.self) private var walks

    var body: some View {
        Group {
            if walks.multi {
                GeometryReader { g in
                    let wide = g.size.width > g.size.height
                    let split = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
                    split {
                        half(walks.left, left: true).inverted()
                        Rectangle().fill(Theme.red).frame(width: wide ? 2 : nil, height: wide ? nil : 2).ignoresSafeArea()
                        half(walks.right, left: false)
                    }
                }
            } else if let m = walks.right ?? walks.left {
                WalkView(model: m).id(ObjectIdentifier(m))
            }
        }
        .background(Theme.bg.ignoresSafeArea())
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }       // screen stays on
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    /// A walk-through drawn a little smaller to fit half the screen, or the
    /// start page when that half is free.
    private func half(_ m: WalkModel?, left: Bool) -> some View {
        Scaled(0.6) {
            if let m { WalkView(model: m).id(ObjectIdentifier(m)) } else { SecondStart(left: left) }
        }
        .environment(\.multiPrint, true)
        .overlay { if let m { Overdue(model: m) } }
        .background(Theme.bg.ignoresSafeArea())
    }
}

/// Lays the content out bigger and shrinks it, so a page made for the whole
/// screen fits a part of it as it is.
private struct Scaled<Content: View>: View {
    let scale: CGFloat
    @ViewBuilder let content: Content
    init(_ scale: CGFloat, @ViewBuilder content: () -> Content) { self.scale = scale; self.content = content() }

    var body: some View {
        GeometryReader { g in
            content
                .frame(width: g.size.width / scale, height: g.size.height / scale)
                .scaleEffect(scale)
                .frame(width: g.size.width, height: g.size.height)
        }
    }
}

/// A flashing frame round the half whose time is up, so it's plain which
/// print wants you.
private struct Overdue: View {
    let model: WalkModel
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let over = model.page.step.map { !$0.isSelect } == true && model.rec.timer.display(at: ctx.date).over
            Rectangle().strokeBorder(Theme.red, lineWidth: 8)
                .opacity(over && Int(ctx.date.timeIntervalSince1970 * 2) % 2 == 0 ? 1 : 0)
                .ignoresSafeArea()
        }
        .allowsHitTesting(false)
    }
}

/// The free half in multi-print: start another print or carry one on.
private struct SecondStart: View {
    let left: Bool
    @Environment(Walks.self) private var walks
    @Environment(AppStore.self) private var store

    private var waiting: [PrintDraft] {
        let open = Set(walks.open.map(\.clientId))
        return store.drafts.values.filter { !$0.finished && !open.contains($0.clientId) }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("ANOTHER PRINT").font(Theme.display(44)).lineLimit(1).minimumScaleFactor(0.6)
                    Spacer()
                    // Back to the one print still going, full screen.
                    Button("One print") { walks.single() }
                        .buttonStyle(WalkButtonStyle())
                        .disabled(walks.open.count > 1)
                }
                Button("▶ Start walk-through") { walks.start(left: left) }
                    .buttonStyle(NextButtonStyle())
                    .disabled(store.snapshot?.presets.isEmpty ?? true)
                if !waiting.isEmpty {
                    Text("IN PROGRESS").font(Theme.label).tracking(2).foregroundStyle(Theme.dim).padding(.top, 8)
                    ForEach(waiting) { d in
                        Button { walks.resume(d, left: left) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(store.name(d)).font(Theme.body.weight(.semibold))
                                Text(store.progress(d)).font(Theme.small).foregroundStyle(Theme.dim)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(WalkButtonStyle())
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(Theme.red)
    }
}

extension AppStore {
    /// A print in progress: its title and edition, or the title it will get.
    func name(_ d: PrintDraft) -> String {
        [d.title.isEmpty ? d.defaultTitle(snapshot) : d.title, d.edition ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// "3 of 7 steps · print #12 · not sent yet"
    func progress(_ d: PrintDraft) -> String {
        let pages = d.pages(snapshot?.preset(d.presetId))
        let steps = pages.filter { $0.step != nil }
        let done = steps.filter { d.isDone($0) }.count
        let send = d.unsent || d.pendingImage != nil ? " · not sent yet" : ""
        return "\(done) of \(steps.count) steps\(d.photoId.map { " · print #\($0)" } ?? "")\(send)"
    }
}

extension EnvironmentValues {
    /// In a half of multi-print, drawn smaller: NEXT is made longer to hit.
    @Entry var multiPrint = false
}

extension View {
    /// The look turned over: black on red in darkroom mode (light on dark
    /// otherwise), for the left print in multi-print.
    func inverted() -> some View { modifier(Invert()) }
}

private struct Invert: ViewModifier {
    func body(content: Content) -> some View {
        if Theme.darkroom { content.colorInvert().colorMultiply(Theme.red) }
        else { content.colorInvert().hueRotation(.degrees(180)) }
    }
}
