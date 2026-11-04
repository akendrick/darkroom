import PhotosUI
import SwiftUI

struct WalkView: View {
    @Bindable var model: WalkModel
    @Environment(AppStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ScrollView {
                Group {
                    switch model.page {
                    case .start: StartPage(model: model)
                    case .finish: FinishPage(model: model)
                    case .step(let s, let layer):
                        if s.isSelect { SelectPage(model: model, step: s) }
                        else { StepPage(model: model, step: s).id("\(s.id):\(layer)") }
                    }
                }
                .padding(.horizontal, 18).padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollDismissesKeyboard(.interactively)
            // Swipe left for Next and right for Back, the same as the buttons
            // (a swipe never finishes the print).
            .simultaneousGesture(DragGesture(minimumDistance: 40).onEnded { v in
                let w = v.translation.width
                guard abs(w) > 90, abs(v.translation.height) < abs(w) * 0.5 else { return }
                if w > 0 { if model.draft.page > 0 { model.back() }; return }
                guard model.page != .finish else { return }
                if let s = model.page.step, s.isSelect, let what = s.selectWhat, model.chosen(what) == nil {
                    model.status = "Choose one first"; return
                }
                model.next()
            })
            Text(model.status ?? store.message ?? " ").font(Theme.small).foregroundStyle(Theme.dim)
                .lineLimit(2).padding(.horizontal, 16).padding(.top, 4)
            footer
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.red)
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }       // screen stays on
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .onChange(of: model.draft.page) { model.status = nil }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            Text(model.header.uppercased()).font(Theme.display(26)).foregroundStyle(Theme.red)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            PhotoButton(model: model)
            WalkMenu(model: model)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.draft.page > 0 { Button("← Back") { model.back() }.buttonStyle(WalkButtonStyle()) }
            if model.page.step?.optional == true { Button("Skip") { model.skip() }.buttonStyle(WalkButtonStyle()) }
            Button(model.page == .finish ? "FINISH ✓" : "NEXT →") { model.next() }.buttonStyle(NextButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
    }
}

// MARK: Pages

private struct Title: View {
    let text: String
    var body: some View { Text(text.uppercased()).font(Theme.display(48)).lineLimit(2).minimumScaleFactor(0.5) }
}

private struct Note: View {
    let text: String?
    var body: some View { if let text { Text(text).font(Theme.small).foregroundStyle(Theme.dim) } }
}

struct StartPage: View {
    @Bindable var model: WalkModel
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Title(text: model.draft.photoId.map { "Print #\($0)" } ?? "New print")
            Note(text: "Pick the process, then Next.")
            FlowRow(model.types, selected: model.draft.typeId, label: \.name) { model.pickType($0.id) }
                .disabled(model.locked)
            FlowRow(model.presetsForType, selected: model.draft.presetId, label: { $0.name + ($0.isDefault ? " ★" : "") }) { model.pickPreset($0.id) }
                .disabled(model.locked)
            Field(label: "Title") {
                TextField(model.draft.defaultTitle(model.snap), text: $model.draft.title)
            }
        }
    }
}

/// Buttons in rows; the chosen one is filled.
struct FlowRow<T: Identifiable>: View {
    let items: [T], selected: T.ID?, label: (T) -> String, action: (T) -> Void
    init(_ items: [T], selected: T.ID?, label: @escaping (T) -> String, action: @escaping (T) -> Void) {
        self.items = items; self.selected = selected; self.label = label; self.action = action
    }
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(items) { i in
                Button(label(i)) { action(i) }
                    .buttonStyle(WalkButtonStyle(on: i.id == selected))
                    .frame(maxWidth: .infinity)
            }
        }
    }
}

struct SelectPage: View {
    @Bindable var model: WalkModel
    let step: Step
    @State private var adding = false
    @State private var name = ""
    @State private var paperId: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Title(text: step.name)
            Note(text: step.notes)
            if let what = step.selectWhat {
                Button(adding ? "Cancel" : "+ New \(what.noun)") { adding.toggle() }
                    .buttonStyle(WalkButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
                if adding { newForm(what) }
                let cur = model.chosen(what)
                ForEach(model.store.items(what)) { m in
                    Button { model.pick(what, m.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.label).font(Theme.body.weight(.semibold))
                            if let sub = m.sub { Text(sub).font(Theme.small).foregroundStyle(Theme.dim) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(WalkButtonStyle(on: m.id == cur))
                }
            } else {
                Note(text: "Choosing this isn't in the app yet. Press Next.")
            }
        }
    }

    @ViewBuilder private func newForm(_ what: SelectWhat) -> some View {
        VStack(spacing: 10) {
            Field(label: what == .support_paper ? "Mark" : "Title") {
                TextField("", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if what == .support_paper {
                Field(label: "Base paper") {
                    Picker("Base paper", selection: $paperId) {
                        Text("—").tag(Int?.none)
                        ForEach(model.snap?.papers ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }.pickerStyle(.menu).labelsHidden()
                }
            }
            Button("Add & choose") {
                let n = name.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { model.status = "Type a name first"; return }
                model.addMaterial(what, name: n, paperId: paperId)
                name = ""; adding = false
            }
            .buttonStyle(WalkButtonStyle()).frame(maxWidth: .infinity)
        }
    }
}

struct StepPage: View {
    @Bindable var model: WalkModel
    let step: Step
    @State private var editTemp = false
    @State private var ph = ""

    init(model: WalkModel, step: Step) {
        self.model = model; self.step = step
        let r = model.rec
        _ph = State(initialValue: r.ph.map { $0.formatted() } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Title(text: step.name)
            Note(text: step.notes)
            HStack(alignment: .firstTextBaseline) {
                if let t = step.tray { Text("TRAY \(t)").font(Theme.display(30)) }
                Spacer()
                // The temperature, big; tap to change it.
                if step.asksTemp || step.defaultTemp != nil {
                    Button { editTemp = true } label: {
                        Text(model.rec.temp.map { "\($0.formatted()) °C" } ?? "— °C")
                            .font(Theme.display(54)).monospacedDigit()
                            .padding(.horizontal, 12).padding(.vertical, 2)
                            .background(Theme.fill, in: .rect(cornerRadius: 10))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Temperature, tap to change")
                }
            }
            .sheet(isPresented: $editTemp) {
                TempWheel(temp: Binding(get: { model.rec.temp }, set: { model.rec.temp = $0 }), start: step.defaultTemp)
                    .presentationDetents([.height(300)])
            }

            // The time is the timer: tap it to start or pause.
            TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
                let r = model.rec.timer
                let d = r.display(at: ctx.date)
                Text(d.text)
                    .font(.system(size: 220, weight: .heavy).width(.compressed)).monospacedDigit()
                    .lineLimit(1).minimumScaleFactor(0.3)
                    .opacity(d.over && Int(ctx.date.timeIntervalSince1970 * 2) % 2 == 0 ? 0.35 : 1)
                    .frame(maxWidth: .infinity, minHeight: 170)
                    .contentShape(Rectangle())
                    .onTapGesture { model.startPause() }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(r.isRunning ? "Pause timer" : "Start timer")
                    .overlay(alignment: .bottom) {
                        // Over time: what will be saved is the whole time run.
                        if d.over {
                            Text("TOTAL \(Duration.format(Int(r.elapsed(at: ctx.date))))")
                                .font(Theme.display(30)).foregroundStyle(Theme.red).offset(y: 18)
                        }
                    }
            }
            .overlay(alignment: .bottomTrailing) {
                // Back to zero and counting again, as on the Watch.
                Button { model.reset(); model.startPause() } label: {
                    Image(systemName: "arrow.counterclockwise.circle").font(.system(size: 38, weight: .semibold))
                }
                .buttonStyle(.plain).foregroundStyle(Theme.red)
                .accessibilityLabel("Restart timer")
                .offset(y: 24)
            }
            if step.minSeconds != nil || step.maxSeconds != nil {
                Text("range \(step.minSeconds.map(Duration.format) ?? "")–\(step.maxSeconds.map(Duration.format) ?? "")")
                    .font(Theme.small).foregroundStyle(Theme.dim).frame(maxWidth: .infinity)
            }

            Field(label: "Time") {
                TimeWheels(seconds: model.target ?? 0) { model.setManual(seconds: $0) }
                    .padding(.horizontal, -12).padding(.vertical, -10)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 12) {
                if step.recordsPh {
                    Field(label: "pH") {
                        TextField("", text: $ph).keyboardType(.decimalPad)
                            .onChange(of: ph) { _, v in model.rec.ph = Double(v.replacingOccurrences(of: ",", with: ".")) }
                    }
                }
                if step.isExposure {
                    Field(label: "Method") {
                        Picker("Method", selection: $model.draft.method) {
                            Text("—").tag(ExposureMethod?.none)
                            ForEach(ExposureMethod.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                        }.pickerStyle(.menu).labelsHidden()
                    }
                }
            }

            let batches = model.batches(for: step)
            if !batches.isEmpty {
                Field(label: "Batch") {
                    Picker("Batch", selection: Binding(get: { model.rec.chemistryId }, set: { model.rec.chemistryId = $0 })) {
                        Text("—").tag(Int?.none)
                        ForEach(batches) { Text($0.label).tag(Optional($0.id)) }
                    }.pickerStyle(.menu).labelsHidden()
                }
            }
            if let what = step.selectWhat {
                Field(label: what.noun.capitalized) {
                    Picker(what.noun, selection: Binding(get: { model.chosen(what) }, set: { model.pick(what, $0) })) {
                        Text("—").tag(Int?.none)
                        ForEach(model.store.items(what)) { Text($0.label).tag(Optional($0.id)) }
                    }.pickerStyle(.menu).labelsHidden()
                }
            }
            Field(label: "Note") {
                TextField("optional", text: Binding(get: { model.rec.notes ?? "" },
                                                    set: { model.rec.notes = $0.isEmpty ? nil : $0 }))
            }
            if step.lightsOkAfter { Text("Room lights can go on after this step").font(Theme.small) }
        }
    }
}

struct FinishPage: View {
    @Bindable var model: WalkModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Title(text: "Done")
            VStack(spacing: 8) {
                ForEach(model.stepPages.filter { !($0.step?.isSelect ?? true) }, id: \.self) { pg in
                    let r = model.draft.recs[PrintDraft.key(pg.step!, layer: pg.layer)]
                    HStack {
                        Text(pg.step!.name + (pg.layer > 0 && model.multiLayer ? " · L\(pg.layer)" : ""))
                        Spacer()
                        Text(summary(r)).foregroundStyle(Theme.dim)
                    }
                    .font(Theme.small)
                }
            }
            Field(label: "Title") { TextField(model.draft.defaultTitle(model.snap), text: $model.draft.title) }
            Field(label: "Notes") { TextField("How did it go?", text: $model.draft.notes, axis: .vertical).lineLimit(3...6) }
        }
    }

    private func summary(_ r: StepRecord?) -> String {
        guard let r, r.done else { return "—" }
        if r.skipped { return "skipped" }
        let s = [r.seconds.map(Duration.format), r.temp.map { "\($0.formatted()) °C" }].compactMap { $0 }
        return s.isEmpty ? "✓" : s.joined(separator: " · ")
    }
}

/// Temperature on a scroll wheel, in half degrees.
struct TempWheel: View {
    @Binding var temp: Double?
    let start: Double?
    @Environment(\.dismiss) private var dismiss
    private let values = Array(stride(from: 0.0, through: 60.0, by: 0.5))

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("TEMPERATURE").font(Theme.label.weight(.bold)).tracking(1.5).foregroundStyle(Theme.bright)
                Spacer()
                Button("Done") { dismiss() }.font(Theme.body.weight(.bold)).foregroundStyle(Theme.red)
            }
            Picker("°C", selection: Binding(get: { temp ?? start ?? 20 }, set: { temp = $0 })) {
                ForEach(values, id: \.self) { Text("\($0.formatted()) °C").font(Theme.display(34)).foregroundStyle(.black).tag($0) }
            }
            .pickerStyle(.wheel).labelsHidden()
            .background(Theme.box, in: .rect(cornerRadius: 10))
        }
        .padding(18)
        .presentationBackground(Theme.bg)
        .onAppear { if temp == nil { temp = start ?? 20 } }
    }
}

// MARK: Menu

/// Save, exit and, later, settings and the other sections of the app.
struct WalkMenu: View {
    @Bindable var model: WalkModel
    @State private var editing = false
    @State private var settings = false
    var body: some View {
        Menu {
            Button("Save", systemImage: "square.and.arrow.down") { model.saveNow() }
            Button("Save & exit", systemImage: "xmark") { model.saveAndExit() }
            Button("Edit walk-through steps", systemImage: "list.number") { editing = true }
            Button("Settings", systemImage: "gearshape") { settings = true }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.red)
                .frame(width: 48, height: 48)
        }
        .accessibilityLabel("Menu")
        .sheet(isPresented: $editing) { EditWalksView(startOn: model.draft.presetId) }
        .sheet(isPresented: $settings) { SettingsView() }
    }
}

// MARK: Photo

/// Take a photo of the print or choose one; shrunk to 1800 px (the server
/// keeps no more) and sent with the print, or when there's a connection.
struct PhotoButton: View {
    @Bindable var model: WalkModel
    @State private var camera = false
    @State private var library: PhotosPickerItem?
    @State private var showLibrary = false

    var body: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("Take Photo", systemImage: "camera") { camera = true }
            }
            Button("Photo Library", systemImage: "photo") { showLibrary = true }
        } label: {
            Image(systemName: model.draft.hasImage ? "camera.fill" : "camera")
                .font(.system(size: 26, weight: .semibold)).foregroundStyle(Theme.red)
                .frame(width: 48, height: 48)
                .overlay(alignment: .topTrailing) {
                    if model.draft.hasImage { Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).offset(x: -2, y: 4) }
                }
        }
        .accessibilityLabel(model.draft.hasImage ? "Photo taken. Change photo" : "Add photo")
        .photosPicker(isPresented: $showLibrary, selection: $library, matching: .images)
        .onChange(of: library) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { save(img) }
                library = nil
            }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraView { img in camera = false; if let img { save(img) } }.ignoresSafeArea()
        }
    }

    private func save(_ img: UIImage) {
        guard let jpeg = img.shrunk(to: 1800).jpegData(compressionQuality: 0.9) else { return }
        model.store.attachImage(jpeg, to: model.clientId)
        model.status = model.store.online ? "Photo saved to this print" : "Photo kept on this phone — sends when online"
    }
}

struct CameraView: UIViewControllerRepresentable {
    let done: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController(); p.sourceType = .camera; p.delegate = context.coordinator; return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(done: done) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let done: (UIImage?) -> Void
        init(done: @escaping (UIImage?) -> Void) { self.done = done }
        func imagePickerController(_ p: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            done(info[.originalImage] as? UIImage)
        }
        func imagePickerControllerDidCancel(_ p: UIImagePickerController) { done(nil) }
    }
}

extension UIImage {
    /// Longest side at most `max` points, drawn upright (camera photos carry a rotation).
    func shrunk(to max: CGFloat) -> UIImage {
        let k = min(1, max / Swift.max(size.width, size.height))
        let s = CGSize(width: (size.width * k).rounded(), height: (size.height * k).rounded())
        let f = UIGraphicsImageRendererFormat(); f.scale = 1
        return UIGraphicsImageRenderer(size: s, format: f).image { _ in draw(in: CGRect(origin: .zero, size: s)) }
    }
}
