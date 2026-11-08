import PhotosUI
import SwiftUI

/// Changing a print after it's made, from the Prints gallery: its photo, title,
/// date, notes, materials and each step's time, temperature and note. Sent
/// straight to knotwork.ca, so it needs a connection, as the gallery does.
struct PrintEditor: View {
    let print: JSON
    let saved: () async -> Void
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    @State private var title: String
    @State private var edition: String
    @State private var date: String
    @State private var notes: String
    @State private var inGallery: Bool
    @State private var layers: [[String: Int]]
    @State private var steps: [StepRow]
    @State private var newPhoto: UIImage?
    @State private var camera = false
    @State private var showLibrary = false
    @State private var library: PhotosPickerItem?
    @State private var busy = false
    @State private var error: String?

    /// One recorded step; the time and temperature as typed.
    struct StepRow: Identifiable {
        let id: Int
        var raw: JSON
        var time: String
        var temp: String
        var note: String
        var skipped: Bool
    }

    init(print: JSON, saved: @escaping () async -> Void) {
        self.print = print; self.saved = saved
        _title = State(initialValue: print["title"].string ?? "")
        _edition = State(initialValue: print["edition"].string ?? "")
        _date = State(initialValue: print["date_exposed"].string ?? "")
        _notes = State(initialValue: print["notes"].string ?? "")
        _inGallery = State(initialValue: print["show_in_gallery"].flag)
        let ls = print["layers"].array.map { l in
            var d: [String: Int] = [:]
            for f in SelectWhat.allCases.map(\.layerField) { if let v = l[f].int { d[f] = v } }
            return d
        }
        _layers = State(initialValue: ls.isEmpty ? [[:]] : ls)
        _steps = State(initialValue: print["steps"].array.enumerated().map { i, s in
            StepRow(id: i, raw: s, time: s["seconds"].int.map(Duration.format) ?? "",
                    temp: s["temp"].double.map { $0.formatted() } ?? "", note: s["notes"].string ?? "",
                    skipped: s["skipped"].flag)
        })
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    photo
                    Field(label: "Title") { TextField("", text: $title) }
                    Field(label: "Edition") {
                        TextField("A or 2/10 — shown after the title", text: $edition)
                            .textInputAutocapitalization(.characters).autocorrectionDisabled()
                    }
                    Field(label: "Date exposed") {
                        TextField("YYYY-MM-DD", text: $date).keyboardType(.numbersAndPunctuation)
                    }
                    Field(label: "Notes") { TextField("", text: $notes, axis: .vertical).lineLimit(2...6) }
                    Toggle("Show in the gallery", isOn: $inGallery).font(Theme.body.weight(.bold)).tint(Theme.red)
                        .foregroundStyle(Theme.red)

                    ForEach(layers.indices, id: \.self) { i in
                        Text(layers.count > 1 ? "LAYER \(i + 1)" : "MATERIALS").font(Theme.label).foregroundStyle(Theme.bright)
                            .padding(.top, 6)
                        ForEach(SelectWhat.allCases, id: \.self) { what in
                            Field(label: what.noun.capitalized) {
                                Picker(what.noun, selection: Binding(get: { layers[i][what.layerField] },
                                                                     set: { layers[i][what.layerField] = $0 })) {
                                    Text("—").tag(Int?.none)
                                    // Only what's on the server: a print can't point at one still on the phone.
                                    ForEach(store.items(what).filter { $0.id > 0 }) { Text($0.label).tag(Optional($0.id)) }
                                }.pickerStyle(.menu).labelsHidden()
                            }
                        }
                    }

                    if !steps.isEmpty {
                        Text("STEPS").font(Theme.label).foregroundStyle(Theme.bright).padding(.top, 6)
                        ForEach($steps) { $s in stepRow($s) }
                    }
                    if let error { Text(error).font(Theme.small).foregroundStyle(Theme.red) }
                }
                .padding(18)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .navigationTitle("Edit print")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else { Button("Save") { Task { await save() } }.fontWeight(.bold) }
                }
            }
            .photosPicker(isPresented: $showLibrary, selection: $library, matching: .images)
            .onChange(of: library) { _, item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data) { newPhoto = img }
                    library = nil
                }
            }
            .fullScreenCover(isPresented: $camera) {
                CameraView(note: { error = $0 }) { img in camera = false; if let img { newPhoto = img } }.ignoresSafeArea()
            }
        }
        .tint(Theme.red)
    }

    private var photo: some View {
        HStack(spacing: 12) {
            Group {
                if let newPhoto {
                    Image(uiImage: newPhoto).resizable().scaledToFill()
                } else if let p = print["thumb_path"].string ?? print["image_path"].string,
                          let url = URL(string: p, relativeTo: store.server.base) {
                    AsyncImage(url: url) { $0.resizable().scaledToFill() } placeholder: { Theme.box }
                } else {
                    Theme.box.overlay { Image(systemName: "photo").foregroundStyle(.black.opacity(0.5)) }
                }
            }
            .frame(width: 96, height: 96).clipShape(.rect(cornerRadius: 8))
            Menu {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("Take Photo", systemImage: "camera") { camera = true }
                }
                Button("Photo Library", systemImage: "photo") { showLibrary = true }
                if newPhoto != nil { Button("Keep the old photo", systemImage: "arrow.uturn.backward") { newPhoto = nil } }
            } label: {
                Text(newPhoto == nil ? "Change photo" : "New photo — sent on Save")
            }
            .buttonStyle(WalkButtonStyle())
        }
    }

    private func stepRow(_ s: Binding<StepRow>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(s.wrappedValue.raw["name"].string ?? "Step").font(Theme.body.weight(.bold)).foregroundStyle(Theme.red)
                if let l = s.wrappedValue.raw["layer_no"].int, l > 0, layers.count > 1 {
                    Text("L\(l)").font(Theme.small).foregroundStyle(Theme.dim)
                }
                Spacer()
                Toggle("Skipped", isOn: s.skipped).labelsHidden().tint(Theme.red)
                Text("skipped").font(Theme.small).foregroundStyle(Theme.dim)
            }
            if !s.wrappedValue.skipped {
                HStack(spacing: 10) {
                    Field(label: "Time") { TextField("m:ss", text: s.time).keyboardType(.numbersAndPunctuation) }
                    Field(label: "°C") { TextField("", text: s.temp).keyboardType(.decimalPad) }
                }
                Field(label: "Note") { TextField("", text: s.note) }
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Theme.line, lineWidth: 1))
    }

    private func save() async {
        guard let id = print["id"].int else { return }
        error = nil
        // The step list is sent whole: the server replaces it.
        var out: [JSON] = []
        for s in steps {
            var o = s.raw.object.filter { Self.stepKeys.contains($0.key) }
            switch Duration.parse(s.time) {
            case .empty: o["seconds"] = .null
            case .seconds(let n): o["seconds"] = .from(n)
            case .invalid: error = "\(s.raw["name"].string ?? "A step"): “\(s.time)” isn't a time (try 1:30)"; return
            }
            let t = s.temp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
            if !t.isEmpty && Double(t) == nil { error = "\(s.raw["name"].string ?? "A step"): “\(s.temp)” isn't a temperature"; return }
            o["temp"] = .from(Double(t))
            o["notes"] = .from(s.note.isEmpty ? nil : s.note)
            o["skipped"] = .from(s.skipped ? 1 : 0)
            out.append(.object(o))
        }
        let d = date.trimmingCharacters(in: .whitespaces)
        if !d.isEmpty && d.wholeMatch(of: /\d{4}-\d{2}-\d{2}/) == nil { error = "The date is YYYY-MM-DD, like \(Clock.today())"; return }
        let body: JSON = .object([
            "title": .from(title.isEmpty ? nil : title),
            "edition": .from(edition.trimmingCharacters(in: .whitespaces).isEmpty ? nil : String(edition.trimmingCharacters(in: .whitespaces).prefix(20))),
            "date_exposed": .from(d.isEmpty ? nil : d),
            "notes": .from(notes.isEmpty ? nil : notes), "show_in_gallery": .from(inGallery ? 1 : 0),
            "layers": .array(layers.map { l in .object(l.mapValues { .from($0) }) }),
            "steps": .array(out),
        ])
        busy = true; defer { busy = false }
        do {
            _ = try await store.server.request("darkroom-api.php?res=photo&id=\(id)", method: "PATCH", body: body)
            if let img = newPhoto, let jpeg = img.shrunk(to: 1800).jpegData(compressionQuality: 0.9) {
                _ = try await store.server.upload(jpeg: jpeg, photoId: id)
            }
            await saved()
            dismiss()
        } catch let e as ServerError {
            error = e.retry ? "Can't reach knotwork.ca — nothing was changed" : "Not saved: \(e.message)"
        } catch { self.error = error.localizedDescription }
    }

    /// What the server keeps for a step (darkroom-api.php photo_children).
    private static let stepKeys: Set<String> = ["process_step_id", "layer_no", "name", "kind", "tray", "chemistry_id",
        "started_at", "seconds", "temp", "ph", "skipped", "light_source", "light_watts", "light_distance_cm", "notes"]
}
