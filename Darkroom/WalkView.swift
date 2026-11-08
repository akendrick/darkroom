import PhotosUI
import SwiftUI
import Photos
import ImageIO
import UniformTypeIdentifiers

struct WalkView: View {
    @Bindable var model: WalkModel
    @Environment(AppStore.self) private var store
    @Environment(\.multiPrint) private var multi
    @Environment(Walks.self) private var walks

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
                if model.choiceMissing { model.status = "Choose one first"; return }
                model.next()
            })
            Text(model.status ?? store.message ?? " ").font(Theme.small).foregroundStyle(Theme.dim)
                .lineLimit(2).padding(.horizontal, 16).padding(.top, 4)
            footer
        }
        .background(Theme.bg.ignoresSafeArea())
        .foregroundStyle(Theme.red)
        .onChange(of: model.draft.page) { model.status = nil }
    }

    private var topBar: some View {
        HStack(spacing: 8) {
            HomeBulb { walks.home() }
            Text(model.header.uppercased()).font(Theme.display(26)).foregroundStyle(Theme.red)
                .lineLimit(1).truncationMode(.tail)
            Spacer()
            if !model.draft.isMake { PhotoButton(model: model) }   // a photo belongs to a print
            WalkMenu(model: model)
        }
        .padding(.horizontal, 16).padding(.top, 8)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if model.draft.page > 0 { Button("← Back") { model.back() }.buttonStyle(WalkButtonStyle()) }
            if model.page.step?.optional == true { Button("Skip") { model.skip() }.buttonStyle(WalkButtonStyle()) }
            Spacer(minLength: 24)
            Button(model.page == .finish ? "FINISH ✓" : "NEXT →") { model.next() }.buttonStyle(NextButtonStyle(compact: true, long: multi))
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
    private var heading: String {
        let d = model.draft
        if d.isMake { return d.label ?? (d.makes == "tissue" ? "New tissue" : "New batch") }
        if d.layer > 1 { return (d.title.isEmpty ? "Print #\(d.photoId ?? 0)" : d.title) + " · layer \(d.layer)" }
        return d.photoId.map { "Print #\($0)" } ?? "New print"
    }
    private var note: String {
        if model.draft.isMake { return "Pick what you are making, then Next. You name it on the last page." }
        if model.draft.layer > 1 { return model.locked ? "Carry on with this layer." : "Pick the walk-through for this layer, then Next. It can be a different one from the layers before." }
        return "Pick what you are making, then Next."
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Title(text: heading)
            Note(text: note)
            WalkTreeView(tree: model.walkTree, openOn: model.draft.presetId) { p in
                let on = model.draft.presetId == p.id
                Button(p.name + (p.isDefault ? " ★" : "")) { model.pickPreset(p.id) }
                    .buttonStyle(TreeRowStyle(fill: on ? Theme.walkOn : Theme.walkBar, text: .black))
                    .disabled(model.locked)
            }
            if !model.draft.isMake && model.draft.layer == 1 {
                Field(label: "Title") {
                    TextField(model.draft.defaultTitle(model.snap), text: $model.draft.title)
                }
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

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Title(text: step.name)
            Note(text: step.notes)
            if let kind = step.materialKindId {
                let noun = (model.snap?.kindName(kind) ?? "material").lowercased()
                Button(adding ? "Cancel" : "+ New \(noun)") { adding.toggle() }
                    .buttonStyle(WalkButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
                if adding { NewKindMaterialForm(model: model, kind: kind) { adding = false } }
                let cur = model.rec.materialId
                ForEach(model.store.items(kind: kind)) { m in
                    Button { model.pickMaterial(m.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(m.label).font(Theme.body.weight(.semibold))
                            if let sub = m.sub { Text(sub).font(Theme.small).foregroundStyle(Theme.dim) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(WalkButtonStyle(on: m.id == cur))
                }
            } else if step.choosesBatch {
                // The glop for a tissue: newest first, with its pigments.
                let cur = model.rec.chemistryId
                let list = model.batchList(step)
                if list.isEmpty { Note(text: "No batches yet. Save & exit, make one, then carry on here.") }
                ForEach(list) { b in
                    Button { model.pickBatch(b.id) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(b.label).font(Theme.body.weight(.semibold))
                            if let sub = b.pigmentsText { Text(sub).font(Theme.small).foregroundStyle(Theme.dim) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(WalkButtonStyle(on: b.id == cur))
                }
            } else if let what = step.selectWhat {
                Button(adding ? "Cancel" : "+ New \(what.noun)") { adding.toggle() }
                    .buttonStyle(WalkButtonStyle()).frame(maxWidth: .infinity, alignment: .leading)
                if adding { NewMaterialForm(model: model, what: what) { adding = false } }
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
}

/// A new negative, tissue sheet or support paper, chosen for this print at once.
struct NewMaterialForm: View {
    @Bindable var model: WalkModel
    let what: SelectWhat
    let done: () -> Void
    @State private var name = ""
    @State private var paperId: Int?

    var body: some View {
        VStack(spacing: 10) {
            Field(label: what == .support_paper ? "Mark" : "Title") {
                TextField("", text: $name).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            if what == .support_paper {
                Field(label: "Base paper") {
                    Picker("Base paper", selection: $paperId) {
                        Text("Choose…").tag(Int?.none)
                        ForEach(model.snap?.papers ?? []) { Text($0.name).tag(Optional($0.id)) }
                    }.pickerStyle(.menu).labelsHidden()
                }
            }
            Button("Add & choose") {
                let n = name.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { model.status = "Type a name first"; return }
                // The server keeps no support paper without its base paper.
                if what == .support_paper && paperId == nil { model.status = "Choose the base paper first"; return }
                model.addMaterial(what, name: n, paperId: paperId)
                name = ""; done()
            }
            .buttonStyle(WalkButtonStyle()).frame(maxWidth: .infinity)
        }
    }
}

/// A new one of the owner's own kinds ("Photo Paper"), chosen for this print at once.
struct NewKindMaterialForm: View {
    @Bindable var model: WalkModel
    let kind: Int
    let done: () -> Void
    @State private var name = ""
    @State private var maker = ""

    var body: some View {
        VStack(spacing: 10) {
            Field(label: "Name") { TextField("", text: $name) }
            Field(label: "Maker") { TextField("optional", text: $maker) }
            Button("Add & choose") {
                let n = name.trimmingCharacters(in: .whitespaces)
                guard !n.isEmpty else { model.status = "Type a name first"; return }
                let mk = maker.trimmingCharacters(in: .whitespaces)
                model.addMaterial(kind: kind, name: n, maker: mk.isEmpty ? nil : mk)
                name = ""; maker = ""; done()
            }
            .buttonStyle(WalkButtonStyle()).frame(maxWidth: .infinity)
        }
    }
}

/// A new chemistry batch, mixed now. Needs a connection: the batch is made
/// on knotwork.ca and chosen for this step when it's there.
struct NewBatchForm: View {
    @Bindable var model: WalkModel
    let typeId: Int?
    let done: () -> Void
    @State private var label = ""
    @State private var type: Int?
    @State private var percent: Double?
    @State private var volume: Double?
    @State private var busy = false

    var body: some View {
        VStack(spacing: 10) {
            Field(label: "Label") { TextField("", text: $label) }
            if typeId == nil {
                Field(label: "Type") {
                    Picker("Type", selection: $type) {
                        Text("Choose…").tag(Int?.none)
                        ForEach(model.snap?.chemistryTypes ?? [], id: \.id) { Text($0.name).tag(Optional($0.id)) }
                    }.pickerStyle(.menu).labelsHidden()
                }
            }
            HStack(spacing: 10) {
                Field(label: "% solution") { NumberField(value: $percent) }
                Field(label: "Volume ml") { NumberField(value: $volume) }
            }
            Button(busy ? "Adding…" : "Add & choose") {
                guard let t = typeId ?? type else { model.status = "Choose the type first"; return }
                busy = true
                Task {
                    await model.addBatch(label: label.trimmingCharacters(in: .whitespaces), typeId: t, percent: percent, volume: volume)
                    busy = false; done()
                }
            }
            .buttonStyle(WalkButtonStyle()).frame(maxWidth: .infinity)
            .disabled(busy)
        }
    }
}

/// Add / measure: today's amount, big, from the recipe until changed.
struct AmountBlock: View {
    @Bindable var model: WalkModel
    let step: Step
    var body: some View {
        VStack(spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                NumberField(value: Binding(get: { model.rec.amount }, set: { model.rec.amount = $0 }))
                    .font(Theme.display(64)).multilineTextAlignment(.center)
                    .padding(.horizontal, 12).padding(.vertical, 4)
                    .background(Theme.box, in: .rect(cornerRadius: 12)).foregroundStyle(.black)
                Text(step.unitShown).font(Theme.display(40))
            }
            if let a = step.defaultAmount {
                Text("Recipe: \(Amount.format(a)) \(step.unitShown)").font(Theme.small).foregroundStyle(Theme.dim)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

/// A pigment step: pigments and grams for today. Add another, or a new
/// pigment; the recipe stays as it is.
struct PigmentBlock: View {
    @Bindable var model: WalkModel
    let step: Step
    @State private var adding = false
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(model.pigLines.enumerated()), id: \.element.id) { i, line in
                HStack(spacing: 8) {
                    Picker("Pigment", selection: Binding(get: { line.pigmentId }, set: { v in var l = model.pigLines; l[i].pigmentId = v; model.pigLines = l })) {
                        Text("Pigment…").tag(Int?.none)
                        ForEach(model.store.pigments) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .pickerStyle(.menu).labelsHidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6).padding(.horizontal, 6)
                    .background(Theme.box, in: .rect(cornerRadius: 10)).tint(.black)
                    NumberField(value: Binding(get: { line.grams }, set: { v in var l = model.pigLines; l[i].grams = v; model.pigLines = l }))
                        .frame(width: 80).multilineTextAlignment(.center)
                        .padding(10).background(Theme.box, in: .rect(cornerRadius: 10)).foregroundStyle(.black)
                    Text(step.unitShown).font(Theme.body.weight(.bold))
                    if model.pigLines.count > 1 {
                        Button { var l = model.pigLines; l.remove(at: i); model.pigLines = l } label: { Image(systemName: "xmark") }
                            .buttonStyle(WalkButtonStyle()).accessibilityLabel("Remove pigment")
                    }
                }
            }
            HStack(spacing: 8) {
                Button("+ Another pigment") { model.pigLines += [PigLine()] }.buttonStyle(WalkButtonStyle())
                Button(adding ? "Cancel" : "+ New pigment") { adding.toggle() }.buttonStyle(WalkButtonStyle())
            }
            if adding {
                Field(label: "New pigment") { TextField("", text: $name) }
                Button("Add & choose") {
                    let n = name.trimmingCharacters(in: .whitespaces)
                    guard !n.isEmpty else { model.status = "Type a name first"; return }
                    model.addPigment(name: n); name = ""; adding = false
                }
                .buttonStyle(WalkButtonStyle()).frame(maxWidth: .infinity)
            }
            let usual = [step.defaultAmount.map { "\(Amount.format($0)) \(step.unitShown)" }, model.snap?.pigment(step.pigmentId)?.name].compactMap { $0 }
            if !usual.isEmpty { Text("Recipe: " + usual.joined(separator: " ")).font(Theme.small).foregroundStyle(Theme.dim) }
        }
    }
}

/// An Important step: a banner that flashes, then stays lit, so it isn't missed.
struct ImportantBanner: View {
    @State private var opened = Date.now
    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { ctx in
            let t = ctx.date.timeIntervalSince(opened)
            let lit = t > 3 || Int(t * 4) % 2 == 0
            Text("IMPORTANT").font(Theme.display(46)).tracking(4)
                .foregroundStyle(lit ? Theme.onRed : Theme.red)
                .frame(maxWidth: .infinity, minHeight: 90)
                .background(lit ? Theme.red : Theme.bg, in: .rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.red, lineWidth: 4))
        }
        .sensoryFeedback(.warning, trigger: opened)
        .accessibilityLabel("Important")
    }
}

struct StepPage: View {
    @Bindable var model: WalkModel
    let step: Step
    @State private var editTemp = false
    @State private var adjustTime = false
    @State private var newBatch = false
    @State private var newMaterial = false
    @State private var newKindMaterial = false
    @State private var ph = ""

    init(model: WalkModel, step: Step) {
        self.model = model; self.step = step
        let r = model.rec
        _ph = State(initialValue: r.ph.map { $0.formatted() } ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if step.isImportant { ImportantBanner() }
            Title(text: step.name)
            Note(text: step.notes)
            if step.isPigment { PigmentBlock(model: model, step: step).onAppear { model.keepDefaults() } }
            else if step.isAdd { AmountBlock(model: model, step: step).onAppear { model.keepDefaults() } }
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

            // The time is the timer: tap it to start or pause. A step with no
            // timer is the instruction, then a big Done that acts as Next.
            if step.timed { timer } else if !step.isAdd { doneButton }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 12) {
                if step.recordsPh {
                    Field(label: "pH") {
                        TextField("", text: $ph).keyboardType(.decimalPad)
                            .onChange(of: ph) { _, v in model.rec.ph = Double(v.replacingOccurrences(of: ",", with: ".")) }
                    }
                }
                if step.isDry {
                    Field(label: "Room humidity %") {
                        NumberField(value: Binding(get: { model.rec.humidity }, set: { model.rec.humidity = $0 }))
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

            // Chemistry: a step that names a type lists those batches; any
            // other bath lists them all. A new batch can be mixed from here.
            if step.chemistryTypeId != nil || step.kind == "bath" {
                let batches = model.batches(for: step)
                HStack(alignment: .bottom, spacing: 8) {
                    Field(label: "Batch") {
                        Picker("Batch", selection: Binding(get: { model.rec.chemistryId }, set: { model.rec.chemistryId = $0 })) {
                            Text("—").tag(Int?.none)
                            ForEach(batches) { Text($0.label).tag(Optional($0.id)) }
                        }.pickerStyle(.menu).labelsHidden()
                    }
                    Button(newBatch ? "Cancel" : "+ New") { newBatch.toggle() }.buttonStyle(WalkButtonStyle())
                }
                if newBatch { NewBatchForm(model: model, typeId: step.chemistryTypeId) { newBatch = false } }
            }
            if let kind = step.materialKindId {
                let name = model.snap?.kindName(kind) ?? "Material"
                HStack(alignment: .bottom, spacing: 8) {
                    Field(label: name) {
                        Picker(name, selection: Binding(get: { model.rec.materialId }, set: { model.pickMaterial($0) })) {
                            Text("—").tag(Int?.none)
                            ForEach(model.store.items(kind: kind)) { Text($0.label).tag(Optional($0.id)) }
                        }.pickerStyle(.menu).labelsHidden()
                    }
                    Button(newKindMaterial ? "Cancel" : "+ New") { newKindMaterial.toggle() }.buttonStyle(WalkButtonStyle())
                }
                if newKindMaterial { NewKindMaterialForm(model: model, kind: kind) { newKindMaterial = false } }
            }
            if let what = step.selectWhat {
                HStack(alignment: .bottom, spacing: 8) {
                    Field(label: what.noun.capitalized) {
                        Picker(what.noun, selection: Binding(get: { model.chosen(what) }, set: { model.pick(what, $0) })) {
                            Text("—").tag(Int?.none)
                            ForEach(model.store.items(what)) { Text($0.label).tag(Optional($0.id)) }
                        }.pickerStyle(.menu).labelsHidden()
                    }
                    Button(newMaterial ? "Cancel" : "+ New") { newMaterial.toggle() }.buttonStyle(WalkButtonStyle())
                }
                if newMaterial { NewMaterialForm(model: model, what: what) { newMaterial = false } }
            }
            Field(label: "Note") {
                TextField("optional", text: Binding(get: { model.rec.notes ?? "" },
                                                    set: { model.rec.notes = $0.isEmpty ? nil : $0 }))
            }
            if step.lightsOkAfter { Text("Room lights can go on after this step").font(Theme.small) }
        }
    }

    /// The countdown, its buttons and the time wheels.
    private var doneButton: some View {
        Button { model.next() } label: {
            Text("DONE")
                .font(.system(size: 220, weight: .heavy).width(.compressed))
                .lineLimit(1).minimumScaleFactor(0.3)
                .frame(maxWidth: .infinity, minHeight: 170)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var timer: some View {
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
        .padding(.bottom, 44)       // room for the clock and restart buttons under the time
        .overlay(alignment: .bottomLeading) {
            // The set time, on wheels, only when asked for.
            Button { withAnimation { adjustTime.toggle() } } label: {
                Image(systemName: adjustTime ? "clock.fill" : "clock").font(.system(size: 34, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.red)
            .accessibilityLabel(adjustTime ? "Hide time setting" : "Set the time")
        }
        .overlay(alignment: .bottomTrailing) {
            // Back to zero and counting again, as on the Watch.
            Button { model.reset(); model.startPause() } label: {
                Image(systemName: "arrow.counterclockwise.circle").font(.system(size: 38, weight: .semibold))
            }
            .buttonStyle(.plain).foregroundStyle(Theme.red)
            .accessibilityLabel("Restart timer")
        }
        if step.minSeconds != nil || step.maxSeconds != nil {
            Text("range \(step.minSeconds.map(Duration.format) ?? "")–\(step.maxSeconds.map(Duration.format) ?? "")")
                .font(Theme.small).foregroundStyle(Theme.dim).frame(maxWidth: .infinity)
        }

        if adjustTime {
            Field(label: "Time") {
                TimeWheels(seconds: model.target ?? 0) { model.setManual(seconds: $0) }
                    .padding(.horizontal, -12).padding(.vertical, -10)
            }
        }
    }

}

/// The last page of a glop or tissue walk: name it, and it is made.
struct RunFinishPage: View {
    @Bindable var model: WalkModel
    var body: some View {
        let chem = model.draft.makes == "chemistry"
        VStack(alignment: .leading, spacing: 14) {
            Title(text: chem ? "Name the batch" : "Name the tissue")
            VStack(spacing: 8) {
                ForEach(model.stepPages, id: \.self) { pg in
                    HStack(alignment: .top) {
                        Text(pg.step!.name)
                        Spacer()
                        Text(summary(pg.step!)).foregroundStyle(Theme.dim).multilineTextAlignment(.trailing)
                    }
                    .font(Theme.small)
                }
            }
            Field(label: chem ? "Batch label" : "Tissue ID") {
                TextField("", text: Binding(get: { model.draft.label ?? model.draft.suggestedId(model.snap, pending: model.store.pendingPigmentCodes) },
                                            set: { model.draft.label = $0 }))
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            HStack(spacing: 10) {
                Field(label: chem ? "Made" : "Poured") { TextField("YYYY-MM-DD", text: $model.draft.date).keyboardType(.numbersAndPunctuation) }
                if chem { Field(label: "Volume mL") { NumberField(value: $model.draft.volume) } }
                else { Field(label: "Size") { TextField("16x26", text: Binding(get: { model.draft.size ?? "" }, set: { model.draft.size = $0 })) } }
            }
            if !chem {
                Field(label: "Amount poured") {
                    TextField("", text: Binding(get: { model.draft.amountPoured ?? model.draft.poured(model.snap) ?? "" }, set: { model.draft.amountPoured = $0 }))
                }
            }
            Field(label: "Notes") { TextField("How did it go?", text: $model.draft.notes, axis: .vertical).lineLimit(3...6) }
            Text("Finish saves it to \(chem ? "Chemistry" : "Materials → Carbon tissue"), ready to choose in the next walk-through. The recipe stays as it is.")
                .font(Theme.small).foregroundStyle(Theme.dim)
        }
    }

    private func summary(_ s: Step) -> String {
        guard let r = model.draft.recs[PrintDraft.key(s, layer: 0)], r.done else { return "—" }
        if r.skipped { return "skipped" }
        if s.choosesBatch { return model.snap?.batches.first { $0.id == r.chemistryId }?.label ?? "—" }
        if s.isPigment {
            let t = (r.pigments ?? []).filter { $0.pigmentId != nil }.map { l in
                (l.grams.map { "\(Amount.format($0)) g " } ?? "") + (model.store.pigments.first { $0.id == l.pigmentId }?.name ?? "")
            }
            return t.isEmpty ? "—" : t.joined(separator: " + ")
        }
        var bits = [r.amount.map { "\(Amount.format($0)) \(s.unitShown)" }, r.seconds.map(Duration.format), r.temp.map { "\($0.formatted()) °C" }].compactMap { $0 }
        if s.isAdd, let a = r.amount, let d = s.defaultAmount, a != d { bits[0] += " (recipe \(Amount.format(d)))" }
        return bits.isEmpty ? "✓" : bits.joined(separator: " · ")
    }
}

struct FinishPage: View {
    @Bindable var model: WalkModel
    var body: some View {
        if model.draft.isMake { RunFinishPage(model: model) } else { printFinish }
    }

    private var printFinish: some View {
        VStack(alignment: .leading, spacing: 14) {
            Title(text: model.draft.layer > 1 ? "Layer \(model.draft.layer) done" : "Done")
            VStack(spacing: 8) {
                ForEach(model.stepPages.filter { !($0.step?.isSelect ?? true) }, id: \.self) { pg in
                    let r = model.draft.recs[PrintDraft.key(pg.step!, layer: pg.layer)]
                    HStack {
                        Text(pg.step!.name)
                        Spacer()
                        Text(summary(r)).foregroundStyle(Theme.dim)
                    }
                    .font(Theme.small)
                }
            }
            Field(label: "Title") { TextField(model.draft.defaultTitle(model.snap), text: $model.draft.title) }
            Field(label: "Edition") {
                TextField("A or 2/10 — shown after the title", text: Binding(get: { model.draft.edition ?? "" },
                                                                           set: { model.draft.edition = String($0.prefix(20)) }))
                    .textInputAutocapitalization(.characters).autocorrectionDisabled()
            }
            Field(label: model.draft.layer > 1 ? "Notes on this layer" : "Notes") {
                TextField("How did it go?", text: $model.draft.notes, axis: .vertical).lineLimit(3...6)
            }
            Note(text: "Once it's finished, Add a layer on the print walks it again for layer \(model.draft.layer + 1).")
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

/// Save, exit, discard, multi-print, and the other sections of the app.
struct WalkMenu: View {
    @Bindable var model: WalkModel
    @Environment(Walks.self) private var walks
    @State private var editing = false
    @State private var settings = false
    @State private var confirmDiscard = false
    @State private var confirmExit = false
    var body: some View {
        Menu {
            Button("Save", systemImage: "square.and.arrow.down") { model.saveNow() }
            Button("Save & exit", systemImage: "xmark") { model.saveAndExit() }
            Button("Exit without saving", systemImage: "arrow.uturn.backward") { confirmExit = true }
            // A recipe changes under Chemistry / Materials, not on the day.
            if !model.draft.isMake { Button("Edit walk-through steps", systemImage: "list.number") { editing = true } }
            Button("Settings", systemImage: "gearshape") { settings = true }
            Divider()
            // Another print alongside this one, the phone turned sideways.
            if !walks.multi {
                Button("Multi-print", systemImage: "rectangle.split.2x1") { walks.split() }
            } else if walks.open.count == 1 {
                Button("One print", systemImage: "rectangle") { walks.single() }
            }
            Divider()
            Button(model.draft.isMake ? "Discard" : model.draft.layer > 1 ? "Discard layer \(model.draft.layer)" : "Discard print",
                   systemImage: "trash", role: .destructive) { confirmDiscard = true }
        } label: {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.red)
                .frame(width: 48, height: 48)
        }
        .accessibilityLabel("Menu")
        .confirmationDialog("Exit without saving?", isPresented: $confirmExit, titleVisibility: .visible) {
            Button("Exit without saving", role: .destructive) { model.exitWithoutSaving() }
            Button("Keep going", role: .cancel) {}
        } message: {
            Text(model.startedHere
                 ? "Nothing from this walk-through is kept."
                 : "It goes back to how it was when you opened it.")
        }
        .confirmationDialog(model.draft.isMake ? "Discard this walk-through?" : model.draft.layer > 1 ? "Discard this layer?" : "Discard this print?",
                            isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { model.discard() }
            Button("Keep it", role: .cancel) {}
        } message: {
            Text(model.draft.layer > 1 && !model.draft.isMake
                 ? "Layer \(model.draft.layer)'s steps and times are deleted. The print and its other layers stay."
                 : model.draft.recordId == nil
                 ? "Its steps, times and photo are deleted from this phone. This can't be undone."
                 : "Its steps, times and photo are deleted from this phone and from knotwork.ca. This can't be undone.")
        }
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
            CameraView(note: { model.status = $0 }) { img in camera = false; if let img { save(img) } }.ignoresSafeArea()
        }
    }

    private func save(_ img: UIImage) {
        guard let jpeg = img.shrunk(to: 1800).jpegData(compressionQuality: 0.9) else { return }
        model.store.attachImage(jpeg, to: model.clientId)
        model.status = model.store.online ? "Photo saved to this print" : "Photo kept on this phone — sends when online"
    }
}

struct CameraView: UIViewControllerRepresentable {
    /// Told if the full-size copy could not go in Photos.
    var note: (@MainActor (String) -> Void)? = nil
    let done: (UIImage?) -> Void
    func makeUIViewController(context: Context) -> UIImagePickerController {
        let p = UIImagePickerController(); p.sourceType = .camera; p.delegate = context.coordinator; return p
    }
    func updateUIViewController(_ vc: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(note: note, done: done) }
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let note: (@MainActor (String) -> Void)?
        let done: (UIImage?) -> Void
        init(note: (@MainActor (String) -> Void)?, done: @escaping (UIImage?) -> Void) { self.note = note; self.done = done }
        func imagePickerController(_ p: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            let img = info[.originalImage] as? UIImage
            if let img { PhotoKeeper.saveHEIC(img, metadata: info[.mediaMetadata] as? [AnyHashable: Any], note: note) }
            done(img)
        }
        func imagePickerControllerDidCancel(_ p: UIImagePickerController) { done(nil) }
    }
}

/// A photo taken in the app also goes into Photos full size, as HEIC, beside
/// the 1800 px JPEG sent with the print.
enum PhotoKeeper {
    static func saveHEIC(_ img: UIImage, metadata: [AnyHashable: Any]?, note: (@MainActor (String) -> Void)?) {
        nonisolated(unsafe) let meta = metadata
        Task.detached(priority: .utility) {
            guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
                await note?("HEIC not kept: allow Photos for Darkroom in Settings"); return
            }
            guard let data = heic(img, metadata: meta) else { await note?("HEIC copy could not be made"); return }
            do {
                try await PHPhotoLibrary.shared().performChanges {
                    let r = PHAssetCreationRequest.forAsset()
                    r.creationDate = .now
                    r.addResource(with: .photo, data: data, options: nil)
                }
            } catch { await note?("HEIC not kept: \(error.localizedDescription)") }
        }
    }

    /// Keeps the camera's EXIF and rotation when there are any.
    private static func heic(_ img: UIImage, metadata: [AnyHashable: Any]?) -> Data? {
        guard let metadata, let cg = img.cgImage else { return img.heicData() }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.heic.identifier as CFString, 1, nil) else { return nil }
        var props = metadata
        props[kCGImageDestinationLossyCompressionQuality] = 0.9
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
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
