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
    @State private var walk: WalkModel?
    @State private var confirmSignOut = false
    @State private var editing = false
    @State private var settings = false

    private var open: [PrintDraft] {
        store.drafts.values.filter { !$0.finished }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack {
            ScrollView { content.padding(20) }
                .background(Theme.bg)
                .refreshable { await store.refresh() }
                .toolbar(.hidden, for: .navigationBar)
        }
        .tint(Theme.red)
        #if DEBUG
        // Test runs: open a walk-through at its first timed step, with the first
        // negative and tissue chosen. Debug builds only.
        .task(id: store.snapshot?.fetchedAt) {
            guard ProcessInfo.processInfo.environment["DARKROOM_TEST_WALK"] != nil, walk == nil, store.snapshot != nil else { return }
            start()
            guard let m = walk else { return }
            for what in SelectWhat.allCases { if let first = store.items(what).first { m.draft.layers[0][what.layerField] = first.id } }
            if let i = m.pages.firstIndex(where: { $0.step.map { !$0.isSelect } ?? false }) { m.draft.page = i }
        }
        #endif
        .fullScreenCover(item: $walk) { m in WalkView(model: m) }
        .sheet(isPresented: $editing) { EditWalksView() }
        .sheet(isPresented: $settings) { SettingsView() }
        .confirmationDialog("Sign out of this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await store.signOut() } }
        } message: {
            Text(store.pendingCount > 0 ? "\(store.pendingCount) change(s) haven't been sent yet and would stay on this phone." : "")
        }
    }

    /// Start, then the prints, then any still in progress.
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

            Button("▶ Start walk-through") { start() }
                .buttonStyle(NextButtonStyle())
                .disabled(store.snapshot?.presets.isEmpty ?? true)

            PrintsGrid(reload: store.snapshot?.fetchedAt).padding(.top, 8)

            if !open.isEmpty {
                Text("IN PROGRESS").font(Theme.label).tracking(2).foregroundStyle(Theme.dim).padding(.top, 8)
                VStack(spacing: 10) {
                    ForEach(open) { d in
                        Button { resume(d) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text([d.title.isEmpty ? d.defaultTitle(store.snapshot) : d.title, d.edition ?? ""].filter { !$0.isEmpty }.joined(separator: " ")).font(Theme.body.weight(.semibold))
                                Text(progress(d)).font(Theme.small).foregroundStyle(Theme.dim)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(WalkButtonStyle())
                    }
                }
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

    private func progress(_ d: PrintDraft) -> String {
        let pages = d.pages(store.snapshot?.preset(d.presetId))
        let steps = pages.filter { $0.step != nil }
        let done = steps.filter { d.isDone($0) }.count
        let send = d.unsent || d.pendingImage != nil ? " · not sent yet" : ""
        return "\(done) of \(steps.count) steps\(d.photoId.map { " · print #\($0)" } ?? "")\(send)"
    }

    /// Starts with the preset the last print used, else the default one.
    private func start() {
        guard let snap = store.snapshot else { return }
        let lastPreset = snap.recent.first?["preset_id"].int ?? snap.inProgress.first?["preset_id"].int
        guard let p = snap.preset(lastPreset) ?? snap.presets.first(where: \.isDefault) ?? snap.presets.first else { return }
        let d = PrintDraft(typeId: p.photoTypeId, presetId: p.id)
        store.update(d)
        show(d)
    }

    /// Carries on at the first page not done yet.
    private func resume(_ d: PrintDraft) {
        var d = d
        let pages = d.pages(store.snapshot?.preset(d.presetId))
        if d.page == 0, let i = pages.indices.dropFirst().first(where: { !d.isDone(pages[$0]) }) { d.page = i }
        show(d)
    }

    private func show(_ d: PrintDraft) {
        let m = WalkModel(store: store, draft: d)
        m.onClose = { walk = nil }
        PhoneWatch.shared.onCommand = { [weak m] cmd, page in m?.handle(cmd, on: page) }
        walk = m
    }
}

extension WalkModel: Identifiable { nonisolated var id: ObjectIdentifier { ObjectIdentifier(self) } }
