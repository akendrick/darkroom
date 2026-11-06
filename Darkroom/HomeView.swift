import SwiftUI

struct SignInView: View {
    @Environment(AppStore.self) private var store
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?
    #if DEBUG
    @State private var local = false
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Spacer()
            Text("DARKROOM").font(Theme.display(64)).foregroundStyle(Theme.red)
            Text("Sign in once on this iPhone. It stays signed in until you sign out or the password changes.")
                .font(Theme.small).foregroundStyle(Theme.dim)
            Field(label: "Password") {
                SecureField("", text: $password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .onSubmit(signIn)
            }
            #if DEBUG
            Toggle("Local test server (localhost:8642)", isOn: $local).font(Theme.small).foregroundStyle(Theme.dim).tint(Theme.red)
            #endif
            if let error { Text(error).font(Theme.small).foregroundStyle(Theme.red) }
            Button(busy ? "Signing in…" : "Sign in", action: signIn)
                .buttonStyle(NextButtonStyle())
                .disabled(busy || password.isEmpty)
            Spacer()
        }
        .padding(24)
        #if DEBUG
        // Test runs: sign in to the local server with the password from a file
        // on the Mac, so it is never typed or shown. Debug builds only.
        .onAppear {
            guard let path = ProcessInfo.processInfo.environment["DARKROOM_TEST_PASSWORD_FILE"],
                  let pw = try? String(contentsOfFile: path, encoding: .utf8) else { return }
            password = pw.trimmingCharacters(in: .whitespacesAndNewlines); local = true; signIn()
        }
        #endif
    }

    private func signIn() {
        guard !password.isEmpty, !busy else { return }
        busy = true; error = nil
        var base = Server.defaultBase
        #if DEBUG
        if local { base = URL(string: "http://localhost:8642/")! }
        #endif
        Task {
            do { try await store.signIn(password: password, base: base); password = "" }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }
}

struct HomeView: View {
    @Environment(AppStore.self) private var store
    @Environment(Walks.self) private var walks
    @State private var confirmSignOut = false
    @State private var editing = false
    @State private var settings = false
    /// Which of the two start buttons is open; kept between launches.
    @AppStorage("homeOpen") private var openPart = "walk"
    @State private var openType: String?
    @State private var editOn: RecipeId?
    @State private var path = NavigationPath()

    private var open: [PrintDraft] {
        store.drafts.values.filter { !$0.finished }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView { content.padding(20) }
                .background(Theme.bg)
                .refreshable { await store.refresh() }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: ProcessRoute.self) { r in
                    if let n = r.section { SectionPager(id: r.id, index: n) } else { ProcessView(id: r.id) }
                }
                .navigationDestination(for: ListSpec.self) { RowsView(spec: $0) }
        }
        .environment(\.goHome) { path = NavigationPath(); editing = false; settings = false }
        .tint(Theme.red)
        #if DEBUG
        // Test runs: open a walk-through at its first timed step, with the first
        // negative and tissue chosen; with DARKROOM_TEST_MULTI, two side by side.
        // Debug builds only.
        .task(id: store.snapshot?.fetchedAt) {
            let env = ProcessInfo.processInfo.environment
            guard env["DARKROOM_TEST_WALK"] != nil, !walks.isOpen, store.snapshot != nil else { return }
            walks.start()
            if env["DARKROOM_TEST_MULTI"] != nil { walks.split(); walks.start(left: true) }
            for m in walks.open {
                for what in SelectWhat.allCases { if let first = store.items(what).first { m.draft.layers[0][what.layerField] = first.id } }
                if let i = m.pages.firstIndex(where: { $0.step.map { !$0.isSelect } ?? false }) { m.draft.page = i }
            }
        }
        #endif
        .fullScreenCover(isPresented: Binding(get: { walks.isOpen }, set: { _ in })) { WalkHost() }
        .sheet(isPresented: $editing) { EditWalksView() }
        .sheet(item: $editOn) { EditWalksView(startOn: $0.id) }
        // A batch or tissue just made: carry straight on with it.
        .alert(madeTitle, isPresented: Binding(get: { store.made != nil && !walks.isOpen }, set: { if !$0 { store.made = nil } })) {
            if let m = store.made, let p = walks.next(after: m) {
                Button(m.makes == "tissue" ? "Make a print" : "Pour a tissue") { store.made = nil; walks.start(preset: p, made: m) }
            }
            Button("Not now", role: .cancel) { store.made = nil }
        } message: {
            Text(store.made.map { $0.makes == "tissue" ? "Make a print with \($0.label) now?" : "Pour a tissue from \($0.label) now?" } ?? "")
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .confirmationDialog("Sign out of this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await store.signOut() } }
        } message: {
            Text(store.pendingCount > 0 ? "\(store.pendingCount) change(s) haven't been sent yet and would stay on this phone." : "")
        }
    }

    /// The two start buttons, then the prints, then any still in progress.
    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("DARKROOM").font(Theme.display(44)).foregroundStyle(Theme.red)
                Spacer()
                Menu {
                    Button("Refresh lists", systemImage: "arrow.clockwise") { Task { await store.refresh() } }
                    Button("Edit walk-throughs", systemImage: "list.number") { editing = true }
                    Button("Settings", systemImage: "gearshape") { settings = true }
                    Button("Sign out", systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) { confirmSignOut = true }
                } label: {
                    Image(systemName: "line.3.horizontal").font(.system(size: 28, weight: .bold)).foregroundStyle(Theme.red)
                        .frame(width: 48, height: 48)
                }
                .accessibilityLabel("Menu")
            }
            statusLine

            part("walk", "WALKTHROUGH")
            if openPart == "walk" { walkthroughs }
            part("proc", "PROCESSES")
            if openPart == "proc" { ProcessesList().padding(.leading, 8) }
            part("chem", "CHEMISTRY")
            if openPart == "chem" { makeButtons("chemistry"); lists([.of("chemistry"), .of("chemistry_types")]) }
            part("mat", "MATERIALS")
            if openPart == "mat" {
                makeButtons("tissue")
                lists((store.snapshot?.materialKinds ?? []).map(ListSpec.materials)
                      + ["paper", "support_paper", "carbon_tissue", "negative", "pigment", "negative_types"].map(ListSpec.of)
                      + [.materialKinds])
            }

            PrintsGrid(reload: store.snapshot?.fetchedAt).padding(.top, 8)

            if !open.isEmpty {
                Text("IN PROGRESS").font(Theme.label).tracking(2).foregroundStyle(Theme.dim).padding(.top, 8)
                VStack(spacing: 10) {
                    ForEach(open) { d in
                        Button { walks.resume(d) } label: {
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
        }
    }

    private func part(_ key: String, _ title: String) -> some View {
        Button { withAnimation(.snappy) { openPart = openPart == key ? "" : key } } label: {
            HStack {
                Text(title)
                Spacer()
                Image(systemName: openPart == key ? "chevron.down" : "chevron.right").font(.system(size: 24, weight: .heavy))
            }
            .padding(.horizontal, 20)
        }
        .buttonStyle(NextButtonStyle())
    }

    private var madeTitle: String {
        store.made.map { $0.makes == "tissue" ? "Tissue \($0.label) saved" : "Batch \($0.label) saved" } ?? ""
    }

    /// ▶ each glop or tissue walk-through, and Edit recipe: the recipe is
    /// changed here; a walk only records what was done that day.
    private func makeButtons(_ makes: String) -> some View {
        VStack(spacing: 8) {
            ForEach((store.snapshot?.presets ?? []).filter { $0.makes == makes }) { p in
                HStack(spacing: 8) {
                    Button { walks.start(preset: p) } label: {
                        Text("▶ " + (makes == "chemistry" ? "Make \(p.name)" : p.name)).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(NextButtonStyle(compact: true))
                    Button("Edit recipe") { editOn = RecipeId(id: p.id) }.buttonStyle(WalkButtonStyle())
                }
            }
        }
        .padding(.leading, 8)
    }

    /// Lists to open and edit; each one is also chosen from in the walk-throughs.
    private func lists(_ specs: [ListSpec]) -> some View {
        VStack(spacing: 10) {
            ForEach(specs) { spec in
                NavigationLink(value: spec) {
                    HStack {
                        Text(spec.id == "material_kind" ? "+ Kinds of material" : spec.title).font(Theme.body.weight(.bold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.body.weight(.bold))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(WalkButtonStyle())
            }
        }
        .padding(.leading, 8)
    }

    /// Each kind of print with its walk-throughs: tap one, then Begin.
    private var walkthroughs: some View {
        VStack(spacing: 10) {
            ForEach(WalkGroup.all(store.snapshot)) { t in
                let ps = (store.snapshot?.presets ?? []).filter { $0.group == t.id }
                    .sorted { $0.isDefault && !$1.isDefault }
                if !ps.isEmpty {
                    Button { withAnimation(.snappy) { openType = openType == t.id ? nil : t.id } } label: {
                        HStack {
                            Text(t.name).font(Theme.body.weight(.bold))
                            Spacer()
                            Image(systemName: openType == t.id ? "chevron.down" : "chevron.right").font(.body.weight(.bold))
                        }
                    }
                    .buttonStyle(WalkButtonStyle(on: openType == t.id))
                    if openType == t.id {
                        VStack(spacing: 8) {
                            ForEach(ps) { p in
                                Button { walks.start(preset: p) } label: {
                                    VStack(spacing: 2) {
                                        Text("▶ Begin walkthrough")
                                        if ps.count > 1 { Text(p.name).font(Theme.small) }
                                    }
                                    .frame(maxWidth: .infinity)
                                }
                                .buttonStyle(NextButtonStyle(compact: true))
                            }
                        }
                        .padding(.leading, 16)
                    }
                }
            }
        }
        .padding(.leading, 8)
        .onAppear {
            // Open on the kind the last print was.
            if openType == nil, let snap = store.snapshot {
                let last = snap.recent.first?["preset_id"].int ?? snap.inProgress.first?["preset_id"].int
                openType = snap.preset(last)?.group ?? snap.presets.first(where: \.isDefault)?.group
            }
        }
    }

    private var statusLine: some View {
        let parts = [
            store.message,
            store.pendingCount > 0 ? "\(store.pendingCount) waiting to send" : nil,
            store.snapshot.map { "Lists from \($0.fetchedAt.formatted(date: .omitted, time: .shortened))" },
        ].compactMap { $0 }
        return Text(parts.isEmpty ? (store.syncing ? "Syncing…" : " ") : parts.joined(separator: " · "))
            .font(Theme.small).foregroundStyle(Theme.dim)
    }
}

/// A walk-through to open in the editor.
private struct RecipeId: Identifiable { let id: Int }
