import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(ScriptStore.self) private var store
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(RemoteHub.self) private var remoteHub
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    @State private var path: [UUID] = []
    @State private var searchText = ""
    @State private var presenting: Script?
    @State private var renaming: Script?
    @State private var renameText = ""
    @State private var deleting: Script?
    @State private var importing = false
    @State private var showSettings = false
    @State private var showNotion = false
    @State private var showRemote = false
    @State private var notice: String?

    private var filtered: [Script] {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return store.scripts }
        return store.scripts.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            content
                .background(Signal.bg.ignoresSafeArea())
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbar }
                .toolbarBackground(Signal.bg, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .searchable(text: $searchText, prompt: "Search scripts")
                .safeAreaInset(edge: .bottom) { bottomBar }
                .navigationDestination(for: UUID.self) { id in
                    EditorView(scriptID: id, onPresent: { presenting = $0 })
                }
        }
        // Stores are passed explicitly: on Mac Catalyst, presented windows do
        // not inherit the app's environment objects.
        .fullScreenCover(item: $presenting) { script in
            PrompterScreen(script: script)
                .environment(store)
                .environment(settingsStore)
                .environment(remoteHub)
        }
        .sheet(isPresented: $showRemote) {
            NavigationStack { RemoteView() }
                .environment(remoteHub)
        }
        .onChange(of: remoteHub.openRequest) { _, id in
            // The phone remote picked a script, or Curriculum Studio sent one.
            guard let id, let script = store.script(id: id), !script.isEmpty else { return }
            remoteHub.openRequest = nil
            guard presenting != nil else { presenting = script; return }
            // Swapping the item of a presented cover only dismisses it, so close
            // the current prompter first and present once it has gone. This also
            // reloads a script that was sent again with new text.
            presenting = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(700))
                presenting = store.script(id: id) ?? script
            }
        }
        .sheet(isPresented: $showNotion) {
            NotionImportView(store: store) { message in notice = message }
                .environment(store)
                .environment(settingsStore)
        }
        .sheet(isPresented: $showSettings) {
            NavigationStack { SettingsView(context: .library) }
                .environment(store)
                .environment(settingsStore)
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: ScriptStore.importableTypes,
                      allowsMultipleSelection: true) { result in
            handleImport(result)
        }
        #if DEBUG
        // UI smoke test hooks: -uitestOpenSettings, -uitestPresentFirst
        .task {
            let args = ProcessInfo.processInfo.arguments
            if args.contains("-uitestOpenSettings") { showSettings = true }
            if args.contains("-uitestOpenNotion") { showNotion = true }
            if args.contains("-uitestPresentFirst") { presenting = store.scripts.first }
        }
        #endif
        .alert("Rename script", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $renameText)
            Button("Cancel", role: .cancel) { renaming = nil }
            Button("Rename") {
                if let script = renaming { store.rename(id: script.id, to: renameText) }
                renaming = nil
            }
        }
        .confirmationDialog(deleting.map { "Delete \($0.displayTitle)?" } ?? "",
                            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                            titleVisibility: .visible) {
            Button("Delete script", role: .destructive) {
                if let script = deleting {
                    path.removeAll { $0 == script.id }
                    store.delete(id: script.id)
                }
                deleting = nil
            }
        } message: {
            Text("This removes the script from this device. It cannot be undone.")
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if store.scripts.isEmpty {
            EmptyLibraryView(onNew: newScript, onPaste: pasteScript, onImport: { importing = true })
        } else if filtered.isEmpty {
            ContentUnavailableView.search(text: searchText)
        } else if horizontalSizeClass == .regular {
            ScrollView {
                header
                    .padding(.horizontal, Signal.Space.s6)
                    .padding(.top, Signal.Space.s4)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300, maximum: 420), spacing: Signal.Space.s5)],
                          spacing: Signal.Space.s5) {
                    ForEach(filtered) { script in
                        NavigationLink(value: script.id) {
                            ScriptCard(script: script)
                        }
                        .buttonStyle(.plain)
                        .contextMenu { menu(for: script) } preview: { ScriptPreview(script: script) }
                    }
                }
                .padding(Signal.Space.s6)
            }
        } else {
            List {
                Section {
                    ForEach(filtered) { script in
                        NavigationLink(value: script.id) {
                            ScriptRow(script: script)
                        }
                        .listRowBackground(Signal.surface)
                        .contextMenu { menu(for: script) } preview: { ScriptPreview(script: script) }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { deleting = script } label: {
                                Label("Delete", systemImage: "trash")
                            }
                            Button { store.duplicate(id: script.id) } label: {
                                Label("Duplicate", systemImage: "plus.square.on.square")
                            }
                            .tint(Signal.lineStrong)
                        }
                        .swipeActions(edge: .leading) {
                            Button { presenting = script } label: {
                                Label("Present", systemImage: "play.fill")
                            }
                            .tint(Signal.success)
                        }
                    }
                } header: {
                    header.textCase(nil)
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Signal.bg)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Signal.Space.s3) {
            Text("Scripts")
                .signal(.title)
                .foregroundStyle(Signal.ink)
                .accessibilityAddTraits(.isHeader)
            Text("\(store.scripts.count)")
                .signal(.eyebrow)
                .foregroundStyle(Signal.inkSubtle)
                .accessibilityLabel("\(store.scripts.count) \(store.scripts.count == 1 ? "script" : "scripts")")
            Spacer()
            if let error = store.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .signal(.bodySmall)
                    .foregroundStyle(Signal.warning)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func menu(for script: Script) -> some View {
        Button { presenting = script } label: { Label("Present", systemImage: "play.fill") }
            .disabled(script.isEmpty)
        Button { path.append(script.id) } label: { Label("Edit", systemImage: "square.and.pencil") }
        Button {
            renameText = script.title
            renaming = script
        } label: { Label("Rename", systemImage: "character.cursor.ibeam") }
        Button { store.duplicate(id: script.id) } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
        Divider()
        Button(role: .destructive) { deleting = script } label: { Label("Delete", systemImage: "trash") }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Button { showRemote = true } label: {
                Image(systemName: remoteHub.isEnabled ? "iphone.radiowaves.left.and.right" : "iphone")
            }
            .accessibilityLabel("Phone remote and iPad display")
            .accessibilityValue(remoteHub.isEnabled ? "On" : "Off")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button { showSettings = true } label: {
                Image(systemName: "gearshape")
            }
            .accessibilityLabel("Settings")
        }
    }
}

private extension LibraryView {
    var bottomBar: some View {
        HStack(spacing: Signal.Space.s3) {
            Menu {
                Button(action: pasteScript) { Label("Paste from clipboard", systemImage: "doc.on.clipboard") }
                Button { importing = true } label: { Label("Import text file", systemImage: "doc.badge.plus") }
                Button { showNotion = true } label: { Label("From Notion", systemImage: "books.vertical") }
            } label: {
                Label("Import", systemImage: "square.and.arrow.down")
                    .signal(.label)
                    .foregroundStyle(Signal.ink)
                    .padding(.horizontal, Signal.Space.s4)
                    .frame(minHeight: Signal.Control.lg)
                    .overlay(RoundedRectangle(cornerRadius: Signal.Radius.sm).strokeBorder(Signal.lineStrong))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)

            Spacer()

            Button(action: newScript) {
                Label("New script", systemImage: "plus")
            }
            .buttonStyle(.signalPrimary)
            .keyboardShortcut("n", modifiers: .command)
        }
        .padding(.horizontal, Signal.Space.s4)
        .padding(.vertical, Signal.Space.s3)
        .background(Signal.surface.ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Signal.line).frame(height: 1) }
    }

    // MARK: Actions

    private func newScript() {
        let script = store.create()
        path.append(script.id)
    }

    private func pasteScript() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = "The clipboard has no text to paste."
            return
        }
        let body = ScriptStore.normalizeLineEndings(text)
        let script = store.create(title: Script.suggestedTitle(for: body), body: body)
        path.append(script.id)
    }

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            var failures: [String] = []
            var last: Script?
            for url in urls {
                do { last = try store.importFile(at: url) } catch { failures.append(url.lastPathComponent) }
            }
            if !failures.isEmpty {
                notice = "These files could not be read as text: \(failures.joined(separator: ", "))"
            } else if urls.count == 1, let script = last {
                path.append(script.id)
            }
        case .failure(let error):
            notice = "Import did not finish: \(error.localizedDescription)"
        }
    }
}

// MARK: - Library pieces

private struct ScriptMeta: View {
    let script: Script

    var body: some View {
        let words = script.wordCount
        let minutes = max(1, Int((Double(words) / 140).rounded()))
        HStack(spacing: Signal.Space.s2) {
            Text("\(words) words")
            Text("·")
            Text(words == 0 ? "Empty" : "about \(minutes) min")
            Text("·")
            Text(script.modifiedAt, format: .relative(presentation: .named))
        }
        .signal(.bodySmall)
        .foregroundStyle(Signal.inkSubtle)
        .lineLimit(1)
    }
}

struct ScriptRow: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: Signal.Space.s1) {
            Text(script.displayTitle)
                .signal(.subheading)
                .foregroundStyle(Signal.ink)
                .lineLimit(1)
            Text(script.isEmpty ? "No text yet" : script.preview)
                .signal(.body)
                .foregroundStyle(Signal.inkMuted)
                .lineLimit(2)
            ScriptMeta(script: script)
        }
        .padding(.vertical, Signal.Space.s1)
        .accessibilityElement(children: .combine)
    }
}

struct ScriptCard: View {
    let script: Script

    var body: some View {
        VStack(alignment: .leading, spacing: Signal.Space.s2) {
            Text(script.displayTitle)
                .signal(.subheading)
                .foregroundStyle(Signal.ink)
                .lineLimit(1)
            Text(script.isEmpty ? "No text yet" : script.preview)
                .signal(.body)
                .foregroundStyle(Signal.inkMuted)
                .lineLimit(5)
                .frame(maxWidth: .infinity, minHeight: 110, alignment: .topLeading)
            Rectangle().fill(Signal.line).frame(height: 1)
            ScriptMeta(script: script)
        }
        .padding(Signal.Space.s4)
        .background(RoundedRectangle(cornerRadius: Signal.Radius.md).fill(Signal.surface))
        .overlay(RoundedRectangle(cornerRadius: Signal.Radius.md).strokeBorder(Signal.line))
        .contentShape(RoundedRectangle(cornerRadius: Signal.Radius.md))
        .accessibilityElement(children: .combine)
    }
}

/// Long-press preview: the script as it will read in the prompter.
struct ScriptPreview: View {
    let script: Script

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Signal.Space.s3) {
                Text(script.displayTitle).signal(.heading).foregroundStyle(Signal.ink)
                Text(script.isEmpty ? "No text yet" : String(script.body.prefix(1600)))
                    .font(Font(SignalFont.figtree(size: 22, weight: 600)))
                    .lineSpacing(6)
                    .foregroundStyle(Signal.ink)
            }
            .padding(Signal.Space.s6)
        }
        .frame(idealWidth: 420, idealHeight: 520)
        .background(Signal.bg)
        .environment(\.colorScheme, .dark)
    }
}

private struct EmptyLibraryView: View {
    let onNew: () -> Void
    let onPaste: () -> Void
    let onImport: () -> Void

    var body: some View {
        VStack(spacing: Signal.Space.s4) {
            Text("No scripts yet")
                .signal(.display)
                .foregroundStyle(Signal.ink)
                .multilineTextAlignment(.center)
            Text("Write a script, paste one from the clipboard, or import a plain text file.")
                .signal(.bodyLarge)
                .foregroundStyle(Signal.inkMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: Signal.Space.s3) {
                Button("Paste", action: onPaste).buttonStyle(.signalSecondary)
                Button("Import file", action: onImport).buttonStyle(.signalSecondary)
            }
        }
        .padding(Signal.Space.s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
