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
    /// Which of the start buttons is open; none shows them as a 2x2 grid.
    @State private var openPart = ""
    @State private var scroll = ScrollPosition(edge: .top)
    /// The title has gone up, so the bulb floats in its corner to bring it back.
    @State private var scrolledPast = false
    @Namespace private var partSpace
    @State private var path = NavigationPath()
    @State private var addingProcess = false
    @State private var addingBatch = false
    @State private var addingKind = false
    @State private var chemistryOptions = false

    private var open: [PrintDraft] {
        store.drafts.values.filter { !$0.finished }.sorted { $0.updatedAt > $1.updatedAt }
    }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView { content.padding(20) }
                .scrollPosition($scroll)
                .overlay(alignment: .topLeading) {
                    if scrolledPast {
                        HomeBulb { withAnimation(.snappy) { scroll.scrollTo(edge: .top) } }
                            .background(Theme.bg, in: .circle)
                            .padding(.leading, 12)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.2), value: scrolledPast)
                .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y + $0.contentInsets.top > 96 } action: { _, v in scrolledPast = v }
                .background(Theme.bg)
                .refreshable { await store.refresh() }
                .toolbar(.hidden, for: .navigationBar)
                .navigationDestination(for: ProcessRoute.self) { r in
                    if let n = r.section { SectionPager(id: r.id, index: n) } else { ProcessView(id: r.id) }
                }
                .navigationDestination(for: ListSpec.self) { RowsView(spec: $0) }
        }
        .environment(\.goHome) { path = NavigationPath(); editing = false; settings = false; chemistryOptions = false }
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
        // A batch or tissue just made: carry straight on with it.
        .alert(madeTitle, isPresented: Binding(get: { store.made != nil && !walks.isOpen }, set: { if !$0 { store.made = nil } })) {
            if let m = store.made, let p = walks.next(after: m) {
                Button("Go on: \(p.name)") { store.made = nil; walks.start(preset: p, made: m) }
            }
            Button("Not now", role: .cancel) { store.made = nil }
        } message: {
            Text(store.made.map { m in walks.next(after: m).map { "Go on to \($0.name) with \(m.label) now?" } ?? "" } ?? "")
        }
        .sheet(isPresented: $settings) { SettingsView() }
        .sheet(isPresented: $chemistryOptions) { ChemistrySettings() }
        .sheet(isPresented: $addingKind) { RowForm(spec: .materialKinds, row: nil) {} }
        .confirmationDialog("Sign out of this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { Task { await store.signOut() } }
        } message: {
            Text(store.pendingCount > 0 ? "\(store.pendingCount) change(s) haven't been sent yet and would stay on this phone." : "")
        }
    }

    /// Favourites and walks in progress, the start buttons, then the prints.
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

            if openPart.isEmpty {
                VStack(spacing: 12) {
                    ForEach([0, 2], id: \.self) { n in
                        HStack(spacing: 12) {
                            tile(Self.parts[n]); tile(Self.parts[n + 1])
                        }
                    }
                }
            } else if let p = Self.parts.first(where: { $0.key == openPart }) {
                HStack(spacing: 8) {
                    ForEach(Self.parts.filter { $0.key != openPart }, id: \.key) { tile($0, small: true) }
                }
                part(p.key, p.title)
                partContent(p.key)
            }

            PrintsGrid(reload: store.snapshot?.fetchedAt).padding(.top, 8)
        }
    }

    private static let parts = [(key: "walk", title: "DEVELOP"), (key: "proc", title: "PROCESSES"), (key: "chem", title: "CHEMISTRY"), (key: "mat", title: "MATERIALS")]

    @ViewBuilder private func partContent(_ key: String) -> some View {
        switch key {
        case "walk":
            if !favourites.isEmpty { favouriteRows }
            if !open.isEmpty { inProgress }
            if favourites.isEmpty && open.isEmpty {
                Text("No favourites or walks in progress.").font(Theme.small).foregroundStyle(Theme.dim).padding(.leading, 8)
            }
        case "proc":
            ProcessesList(adding: $addingProcess).padding(.leading, 8)
        case "chem":
            InlineRows(spec: .of("chemistry"), adding: $addingBatch).padding(.leading, 8)
        default:
            lists((store.snapshot?.materialKinds ?? []).map(ListSpec.materials)
                  + ["paper", "support_paper", "carbon_tissue", "negative", "pigment", "negative_types"].map(ListSpec.of)
                  + [.materialKinds])
        }
    }

    private func tile(_ p: (key: String, title: String), small: Bool = false) -> some View {
        Button { withAnimation(.snappy) { openPart = p.key; if small { scroll.scrollTo(edge: .top) } } } label: {
            Theme.red
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    VStack(spacing: small ? 3 : 10) {
                        partIcon(p.key, size: small ? 62 : 96)
                        Text(p.title).font(Theme.display(small ? 16 : 26)).tracking(small ? 1 : 2).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(Theme.onRed)
                    .padding(small ? 4 : 8)
                }
                .clipShape(.rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .matchedGeometryEffect(id: p.key, in: partSpace)
    }

    private var favourites: [Preset] { (store.snapshot?.presets ?? []).filter(\.favourite) }

    /// Starred walks: one tap to begin.
    private var favouriteRows: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("FAVOURITES").font(Theme.label).tracking(2).foregroundStyle(Theme.bright)
            ForEach(favourites) { p in
                Button { walks.start(preset: p) } label: {
                    Label(p.name, systemImage: "figure.run").minimumScaleFactor(0.7).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(NextButtonStyle(compact: true))
            }
        }
        .padding(.leading, 8)
    }

    /// Walks still going, which can take days: always in view at the top.
    private var inProgress: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("IN PROGRESS").font(Theme.label).tracking(2).foregroundStyle(Theme.bright)
            ForEach(open) { d in
                Button { walks.resume(d) } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.name(d)).font(Theme.body.weight(.semibold))
                        Text(store.progress(d)).font(Theme.small).foregroundStyle(Theme.dim)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(WalkButtonStyle(on: true))
            }
        }
        .padding(.leading, 8)
    }

    private func part(_ key: String, _ title: String) -> some View {
        Button { withAnimation(.snappy) { openPart = openPart == key ? "" : key } } label: {
            HStack(spacing: 12) {
                partIcon(key, size: 28)
                Text(title).font(Theme.display(26)).tracking(2)
                Spacer(minLength: key == "chem" ? 84 : 44)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NextButtonStyle(compact: true))
        .overlay(alignment: .trailing) { partActions(key).padding(.trailing, 6) }
        .matchedGeometryEffect(id: key, in: partSpace)
    }

    /// The bar's + (add to this part) and, on Chemistry, its options.
    @ViewBuilder private func partActions(_ key: String) -> some View {
        HStack(spacing: 0) {
            if key == "chem" {
                barIcon("gearshape.fill", "Chemistry options") { chemistryOptions = true }
            }
            switch key {
            case "proc": barIcon("plus", "New process") { addingProcess = true }
            case "chem": barIcon("plus", "New chemistry batch") { addingBatch = true }
            case "mat": barIcon("plus", "New kind of material") { addingKind = true }
            default: EmptyView()
            }
        }
    }

    private func barIcon(_ name: String, _ label: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Image(systemName: name).font(.system(size: name == "plus" ? 30 : 24, weight: .heavy))
                .foregroundStyle(Theme.onRed).frame(width: 44, height: 50).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func partIcon(_ key: String, size: CGFloat) -> some View {
        Group {
            switch key {
            case "walk": FilmIcon().fill(.foreground, style: FillStyle(eoFill: true))
            case "proc": ProcessIcon().fill(.foreground)
            case "chem": Image(systemName: "flask.fill").font(.system(size: size * 0.82, weight: .bold))
            default: EnlargerIcon().fill(.foreground)
            }
        }
        .frame(width: size, height: size)
    }

    private var madeTitle: String {
        store.made.map { $0.makes == "tissue" ? "Tissue \($0.label) saved" : "Batch \($0.label) saved" } ?? ""
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


/// A photographic enlarger: column and base, carriage, lamp head, lens, easel.
struct EnlargerIcon: Shape {
    func path(in r: CGRect) -> Path {
        let u = min(r.width, r.height) / 24
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: r.minX + x * u, y: r.minY + y * u, width: w * u, height: h * u) }
        var p = Path()
        p.addRoundedRect(in: box(4, 1, 2, 20), cornerSize: CGSize(width: u, height: u))
        p.addRoundedRect(in: box(1, 21, 21, 2.2), cornerSize: CGSize(width: u, height: u))
        p.addRect(box(2.5, 6.5, 5, 7))
        p.addLines([CGPoint(x: 9, y: 6), CGPoint(x: 18, y: 6), CGPoint(x: 22, y: 9), CGPoint(x: 22, y: 14), CGPoint(x: 9, y: 14)]
            .map { CGPoint(x: r.minX + $0.x * u, y: r.minY + $0.y * u) })
        p.closeSubpath()
        p.addRect(box(13, 15, 5, 1.5))
        p.addRect(box(14, 17.3, 3, 1.3))
        p.addRect(box(10, 19.2, 12, 0.9))
        return p
    }
}

/// A printer bent over a tray, with prints drying on a line.
struct ProcessIcon: Shape {
    func path(in r: CGRect) -> Path {
        let u = min(r.width, r.height) / 24
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * u, y: r.minY + y * u) }
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(origin: pt(x, y), size: CGSize(width: w * u, height: h * u)) }
        var p = Path()
        p.addRect(box(0.5, 2, 23, 0.9))
        for x in [1.5, 5.5, 9.5] as [CGFloat] { p.addRect(box(x, 2.9, 3.2, 3.8)) }
        p.addEllipse(in: box(13.5, 5.5, 4, 4))
        var figure = Path()
        figure.addLines([pt(7.5, 22.8), pt(9.5, 14), pt(13.5, 11), pt(18, 14)])
        p.addPath(figure.strokedPath(StrokeStyle(lineWidth: 2.4 * u, lineCap: .round, lineJoin: .round)))
        p.addLines([pt(17.5, 9.5), pt(21, 9), pt(22, 13), pt(18.8, 13.6)])
        p.closeSubpath()
        p.addRect(box(16.5, 15.5, 7, 2.6))
        p.addRect(box(15.5, 19, 8.5, 1.1))
        return p
    }
}

/// Two strips of film pegged on a line to dry.
struct FilmIcon: Shape {
    func path(in r: CGRect) -> Path {
        let u = min(r.width, r.height) / 24
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect { CGRect(x: r.minX + x * u, y: r.minY + y * u, width: w * u, height: h * u) }
        var p = Path()
        for s in [(x: 1, w: 3.9), (x: 8.1, w: 7.8), (x: 19.1, w: 3.9)] as [(x: CGFloat, w: CGFloat)] { p.addRect(box(s.x, 2.4, s.w, 0.9)) }
        for (x, bottom) in [(1.5, 18.5), (12.5, 23)] as [(CGFloat, CGFloat)] {
            p.addRect(box(x + 4, 0.8, 2, 4.6))
            p.addRoundedRect(in: box(x + 3.4, 5.4, 3.2, 2.6), cornerSize: CGSize(width: 0.5 * u, height: 0.5 * u))
            p.addRoundedRect(in: box(x, 8, 10, bottom - 8), cornerSize: CGSize(width: 0.5 * u, height: 0.5 * u))
            var y: CGFloat = 8.8
            while y + 1 < bottom - 0.5 {
                p.addRect(box(x + 0.8, y, 1.2, 0.95))
                p.addRect(box(x + 8, y, 1.2, 0.95))
                y += 1.75
            }
        }
        return p
    }
}
