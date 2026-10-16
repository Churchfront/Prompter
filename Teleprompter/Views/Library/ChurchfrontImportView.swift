import SwiftUI

/// Downloads scripts from the Churchfront portal (Curriculum Studio and
/// Content Studio). Optional: only Churchfront staff can sign in.
struct ChurchfrontImportView: View {
    let store: ScriptStore
    /// Called after a download with a message and the script to open.
    var onFinished: (String, UUID?) -> Void = { _, _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var signedIn = ChurchfrontClient.isSignedIn

    var body: some View {
        NavigationStack {
            Group {
                if signedIn {
                    PortalScriptList(store: store, onSignOut: {
                        ChurchfrontClient.signOut()
                        signedIn = false
                    }, onSignedOut: { signedIn = false }, onDownloaded: { message, id in
                        onFinished(message, id)
                        dismiss()
                    })
                } else {
                    ChurchfrontSignInView(onSignedIn: { signedIn = true })
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
        .tint(Signal.accent)
        #if targetEnvironment(macCatalyst)
        .frame(minWidth: 520, minHeight: 560)
        #endif
    }
}

// MARK: - Sign in

private struct ChurchfrontSignInView: View {
    let onSignedIn: () -> Void
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Signal.Space.s4) {
                Text("Churchfront").signal(.eyebrow).foregroundStyle(Signal.accent)
                Text("Download scripts from the portal").signal(.heading).foregroundStyle(Signal.ink)
                Text("Churchfront staff can bring course and content scripts from Curriculum Studio and Content Studio straight onto this device. Sign in once with your Churchfront account. CuePrompter only reads scripts and never changes anything in the portal.")
                    .signal(.bodyLarge).foregroundStyle(Signal.inkMuted)
                Text("Not on the Churchfront team? Everything else in CuePrompter works without signing in: type a script, paste one, or import a text file.")
                    .signal(.body).foregroundStyle(Signal.inkSubtle)

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .signal(.body).foregroundStyle(Signal.danger)
                }

                Button {
                    Task { await signIn() }
                } label: {
                    if working { ProgressView().tint(Signal.onAction) } else { Text("Sign in with Churchfront") }
                }
                .buttonStyle(.signalPrimary)
                .disabled(working)
            }
            .padding(Signal.Space.s6)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .background(Signal.bg.ignoresSafeArea())
        .navigationTitle("From Churchfront")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func signIn() async {
        working = true
        error = nil
        do {
            try await ChurchfrontClient.shared.signIn()
            onSignedIn()
        } catch ChurchfrontError.cancelled {
            // The person closed the sheet: nothing to report.
        } catch {
            if case ChurchfrontError.notStaff = error { ChurchfrontClient.signOut() }
            self.error = error.localizedDescription
        }
        working = false
    }
}

// MARK: - Pick a script

private struct PortalScriptList: View {
    let store: ScriptStore
    let onSignOut: () -> Void
    let onSignedOut: () -> Void
    let onDownloaded: (String, UUID?) -> Void

    @State private var scripts: [PortalScript] = []
    @State private var loading = true
    @State private var downloading: String?
    @State private var query = ""
    @State private var error: String?

    private var filtered: [PortalScript] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return scripts }
        return scripts.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.course.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .signal(.body).foregroundStyle(Signal.danger)
                    .listRowBackground(Signal.surface)
            }
            let ready = filtered.filter(\.isReadyToFilm)
            let rest = filtered.filter { !$0.isReadyToFilm }
            if !ready.isEmpty {
                Section { ForEach(ready) { row($0) } } header: { Text("Ready to film") }
            }
            if !rest.isEmpty {
                Section { ForEach(rest) { row($0) } } header: { Text(ready.isEmpty ? "Scripts" : "Other scripts") }
            }
            if !loading && filtered.isEmpty && error == nil {
                Text(query.isEmpty ? "No scripts in the portal yet." : "No scripts match \"\(query)\".")
                    .signal(.body).foregroundStyle(Signal.inkMuted)
                    .listRowBackground(Signal.surface)
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Signal.bg)
        .overlay { if loading && scripts.isEmpty { ProgressView() } }
        .searchable(text: $query, prompt: "Search scripts")
        .refreshable { await load() }
        .task { await load() }
        .navigationTitle("From Churchfront")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button { Task { await load() } } label: { Label("Reload", systemImage: "arrow.clockwise") }
                    Button(role: .destructive, action: onSignOut) { Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right") }
                } label: { Image(systemName: "ellipsis.circle") }
                .accessibilityLabel("More")
            }
        }
    }

    private func row(_ script: PortalScript) -> some View {
        let local = store.script(forSourceKey: ChurchfrontImporter.sourceKey(script.key))
        return Button {
            Task { await download(script) }
        } label: {
            HStack(spacing: Signal.Space.s3) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(script.title).signal(.subheading).foregroundStyle(Signal.ink).multilineTextAlignment(.leading)
                    HStack(spacing: Signal.Space.s2) {
                        Text(script.source == "content" ? "Content Studio" : "Curriculum")
                        Text("·")
                        Text("\(script.words) words")
                        if !script.isReadyToFilm { Text("·"); Text(script.phaseLabel) }
                    }
                    .signal(.bodySmall).foregroundStyle(Signal.inkSubtle)
                }
                Spacer()
                if downloading == script.key {
                    ProgressView()
                } else {
                    Label(local == nil ? "Download" : "Update",
                          systemImage: local == nil ? "arrow.down.circle" : "arrow.triangle.2.circlepath")
                        .labelStyle(.iconOnly)
                        .foregroundStyle(Signal.accent)
                        .accessibilityLabel(local == nil ? "Download" : "Update from the portal")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(downloading != nil)
        .listRowBackground(Signal.surface)
    }

    private func load() async {
        loading = true
        error = nil
        do {
            scripts = try await ChurchfrontClient.shared.scripts()
        } catch ChurchfrontError.notSignedIn {
            onSignedOut()
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func download(_ script: PortalScript) async {
        downloading = script.key
        defer { downloading = nil }
        do {
            let result = try await ChurchfrontImporter.download(script.key, into: store)
            onDownloaded(result.created ? "Downloaded \(result.script.displayTitle)." : "Updated \(result.script.displayTitle) from the portal.",
                         result.script.id)
        } catch ChurchfrontError.notSignedIn {
            onSignedOut()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
