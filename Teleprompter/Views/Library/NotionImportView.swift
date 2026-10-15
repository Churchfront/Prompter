import SwiftUI
import TeleprompterCore

/// Imports course lesson scripts from Notion into the library.
struct NotionImportView: View {
    let store: ScriptStore
    var onFinished: (String) -> Void = { _ in }

    @Environment(\.dismiss) private var dismiss
    @State private var connected = NotionClient.isConnected
    @State private var path: [NotionPageSummary] = []

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if connected {
                    NotionPagePicker(onDisconnect: {
                        NotionClient.disconnect()
                        connected = false
                    })
                } else {
                    NotionConnectView(onConnected: { connected = true })
                }
            }
            .navigationDestination(for: NotionPageSummary.self) { page in
                NotionLessonPicker(page: page, store: store) { message in
                    onFinished(message)
                    dismiss()
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

// MARK: - Connect

private struct NotionConnectView: View {
    let onConnected: () -> Void
    @Environment(\.openURL) private var openURL
    @State private var token = ""
    @State private var working = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Signal.Space.s4) {
                Text("Notion").signal(.eyebrow).foregroundStyle(Signal.accent)
                Text("Connect your course docs").signal(.heading).foregroundStyle(Signal.ink)
                Text("Prompter reads lesson scripts from Notion pages you choose. It never edits Notion. Setup takes about two minutes and happens once per device.")
                    .signal(.bodyLarge).foregroundStyle(Signal.inkMuted)

                step(1, "Create an integration", "Open notion.so/my-integrations, choose New integration, name it Prompter, pick your workspace, and save. Read content is the only capability it needs.")
                Button("Open My Integrations") {
                    if let url = URL(string: "https://www.notion.so/my-integrations") { openURL(url) }
                }
                .buttonStyle(.signalSecondary)
                step(2, "Share your courses with it", "In Notion, open Course Development, choose ••• > Connections, and add Prompter. Every course page under it is included.")
                step(3, "Paste the secret", "Back in the integration settings, copy the Internal Integration Secret and paste it here. It is stored in this device's Keychain.")

                SecureField("Internal Integration Secret", text: $token)
                    .textContentType(.password)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .font(Font(SignalFont.uiFont(.mono)))
                    .padding(Signal.Space.s3)
                    .background(RoundedRectangle(cornerRadius: Signal.Radius.sm).fill(Signal.surfaceRaised))
                    .overlay(RoundedRectangle(cornerRadius: Signal.Radius.sm).strokeBorder(Signal.lineStrong))

                if let error {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .signal(.body).foregroundStyle(Signal.danger)
                }

                Button {
                    Task { await connect() }
                } label: {
                    if working { ProgressView().tint(Signal.onAction) } else { Text("Connect") }
                }
                .buttonStyle(.signalPrimary)
                .disabled(token.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            .padding(Signal.Space.s6)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .background(Signal.bg.ignoresSafeArea())
        .navigationTitle("Import from Notion")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Signal.Space.s3) {
            Text("\(number)").signal(.mono).foregroundStyle(Signal.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).signal(.subheading).foregroundStyle(Signal.ink)
                Text(detail).signal(.body).foregroundStyle(Signal.inkMuted)
            }
        }
    }

    private func connect() async {
        working = true
        error = nil
        do {
            _ = try await NotionClient.shared.connect(token: token)
            token = ""
            onConnected()
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }
}

// MARK: - Pick a page

private struct NotionPagePicker: View {
    let onDisconnect: () -> Void
    @State private var query = "Course Build Doc"
    @State private var pages: [NotionPageSummary] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .signal(.body).foregroundStyle(Signal.danger)
                    .listRowBackground(Signal.surface)
            }
            Section {
                ForEach(pages) { page in
                    NavigationLink(value: page) {
                        HStack(spacing: Signal.Space.s3) {
                            Text(page.icon ?? "📄")
                            VStack(alignment: .leading, spacing: 2) {
                                Text(page.title).signal(.subheading).foregroundStyle(Signal.ink).lineLimit(2)
                                if let edited = page.lastEdited {
                                    Text("Edited \(edited.formatted(.relative(presentation: .named)))")
                                        .signal(.bodySmall).foregroundStyle(Signal.inkSubtle)
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .listRowBackground(Signal.surface)
                }
            } header: {
                Text(loading ? "Searching" : "\(pages.count) pages").signal(.eyebrow).foregroundStyle(Signal.inkSubtle)
            } footer: {
                Text("Only pages shared with your Prompter integration appear here.")
            }
            Section {
                Button("Disconnect Notion", role: .destructive, action: onDisconnect)
                    .listRowBackground(Signal.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Signal.bg.ignoresSafeArea())
        .overlay { if loading && pages.isEmpty { ProgressView() } }
        .searchable(text: $query, prompt: "Search Notion")
        .onSubmit(of: .search) { Task { await search() } }
        .task { await search() }
        .refreshable { await search() }
        .navigationTitle("Choose a course")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func search() async {
        loading = true
        error = nil
        do {
            pages = try await NotionClient.shared.searchPages(query)
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Pick lessons

private struct NotionLessonPicker: View {
    let page: NotionPageSummary
    let store: ScriptStore
    let onImported: (String) -> Void

    @State private var lessons: [NotionLesson] = []
    @State private var selected: Set<String> = []
    @State private var loading = true
    @State private var error: String?

    private var course: String { NotionScriptExtractor.shortCourseName(page.title) }

    var body: some View {
        List {
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .signal(.body).foregroundStyle(Signal.danger)
                    .listRowBackground(Signal.surface)
            }
            if !loading && lessons.isEmpty && error == nil {
                Text("No scripts found. Prompter looks for toggles titled \"Script\" under each lesson heading.")
                    .signal(.body).foregroundStyle(Signal.inkMuted)
                    .listRowBackground(Signal.surface)
            }
            Section {
                ForEach(lessons) { lesson in
                    Button {
                        if selected.contains(lesson.key) { selected.remove(lesson.key) } else { selected.insert(lesson.key) }
                    } label: {
                        HStack(spacing: Signal.Space.s3) {
                            Image(systemName: selected.contains(lesson.key) ? "checkmark.square.fill" : "square")
                                .foregroundStyle(selected.contains(lesson.key) ? Signal.accent : Signal.inkSubtle)
                                .font(.system(size: 20))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(lesson.lessonTitle).signal(.subheading).foregroundStyle(Signal.ink)
                                HStack(spacing: Signal.Space.s2) {
                                    Text("\(lesson.wordCount) words")
                                    Text("·")
                                    Text(lesson.scriptLabel).lineLimit(1)
                                }
                                .signal(.bodySmall).foregroundStyle(Signal.inkSubtle)
                            }
                            Spacer()
                            if store.script(forSourceKey: lesson.key) != nil {
                                StatusBadge(text: "Update", systemImage: "arrow.triangle.2.circlepath", tone: .accent)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(Signal.surface)
                    .accessibilityAddTraits(selected.contains(lesson.key) ? .isSelected : [])
                }
            } header: {
                Text(loading ? "Reading \(course)" : "\(lessons.count) lesson scripts in \(course)")
                    .signal(.eyebrow).foregroundStyle(Signal.inkSubtle)
            } footer: {
                Text("Bracketed directions such as [ON CAMERA] show as small cues and Voice Follow skips them. Importing a lesson again updates it in place.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Signal.bg.ignoresSafeArea())
        .overlay { if loading { ProgressView("Reading Notion") } }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button(selected.count == lessons.count ? "Select none" : "Select all") {
                    selected = selected.count == lessons.count ? [] : Set(lessons.map(\.key))
                }
                .buttonStyle(.signalQuiet)
                .disabled(lessons.isEmpty)
                Spacer()
                Button("Import \(selected.count)") { importSelected() }
                    .buttonStyle(.signalPrimary)
                    .disabled(selected.isEmpty)
            }
            .padding(Signal.Space.s4)
            .background(Signal.surface.ignoresSafeArea(edges: .bottom))
            .overlay(alignment: .top) { Rectangle().fill(Signal.line).frame(height: 1) }
        }
        .task { await load() }
        .navigationTitle(course)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() async {
        do {
            lessons = try await NotionImporter.lessons(for: page)
            selected = Set(lessons.map(\.key))
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
    }

    private func importSelected() {
        let chosen = lessons.filter { selected.contains($0.key) }
        let result = NotionImporter.save(chosen, from: page, into: store)
        var parts: [String] = []
        if result.created > 0 { parts.append("Imported \(result.created) \(result.created == 1 ? "script" : "scripts")") }
        if result.updated > 0 { parts.append("updated \(result.updated)") }
        onImported(parts.joined(separator: ", ") + " from \(course).")
    }
}
