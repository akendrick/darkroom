import SwiftUI

/// Darkroom mode, and where to go to change the app's lists.
struct SettingsView: View {
    @Environment(AppStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Bindable private var look = Look.shared
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Toggle(isOn: $look.darkroom) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Darkroom mode").font(Theme.body.weight(.bold))
                            Text("Red on black, safe under the safelight").font(Theme.small).foregroundStyle(.black.opacity(0.6))
                        }
                    }
                    .tint(Theme.red)
                }
                .listRowBackground(Theme.box)
                Section {
                    NavigationLink("Edit walk-throughs") { EditWalksView(embedded: true) }
                    NavigationLink("Chemistry, papers & materials") { ListsView() }
                } header: { Text("LISTS").font(Theme.label).foregroundStyle(Theme.bright) }
                .listRowBackground(Theme.box)
                Section {
                    LabeledContent("Server", value: store.server.base.host() ?? "")
                    Button("Sign out of this iPhone", role: .destructive) { confirmSignOut = true }
                        .foregroundStyle(look.darkroom ? Color.black : Theme.red).fontWeight(.bold)
                } header: { Text("ACCOUNT").font(Theme.label).foregroundStyle(Theme.bright) }
                .listRowBackground(Theme.box)
            }
            .font(Theme.body)
            .foregroundStyle(.black)
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .confirmationDialog("Sign out of this iPhone?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { Task { await store.signOut(); dismiss() } }
            } message: {
                Text(store.pendingCount > 0 ? "\(store.pendingCount) change(s) haven't been sent yet and would stay on this phone." : "")
            }
        }
        .tint(Theme.red)
    }
}
