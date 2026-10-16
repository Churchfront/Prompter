import SwiftUI
import UIKit
import TeleprompterCore

/// Edits one script. Changes save automatically shortly after typing stops,
/// and immediately when leaving the screen or the app.
struct EditorView: View {
    let scriptID: UUID
    let onPresent: (Script) -> Void

    @Environment(ScriptStore.self) private var store
    @Environment(SettingsStore.self) private var settingsStore
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    @State private var title = ""
    @State private var bodyText = ""
    @State private var loaded = false
    @State private var saveTask: Task<Void, Never>?
    @State private var hasUnsavedChanges = false
    @State private var importing = false
    @State private var confirmReplace: PendingReplace?
    @State private var notice: String?
    @State private var refreshing = false
    @FocusState private var focus: Field?

    private enum Field { case title, body }

    private struct PendingReplace: Identifiable {
        let id = UUID()
        let text: String
        let source: String
    }

    private var wordCount: Int { TextNormalizer.words(in: bodyText).count }
    private var isEmpty: Bool { bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Group {
            if store.script(id: scriptID) == nil && loaded {
                ContentUnavailableView("Script not found", systemImage: "doc.questionmark",
                                       description: Text("This script was deleted."))
            } else {
                editor
            }
        }
        .background(Signal.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbar }
        .onAppear(perform: load)
        .onDisappear(perform: finishEditing)
        .onChange(of: title) { _, _ in scheduleSave() }
        .onChange(of: bodyText) { _, _ in scheduleSave() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { saveNow() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: ScriptStore.importableTypes) { result in
            handleImport(result)
        }
        .confirmationDialog("Replace the current text?",
                            isPresented: Binding(get: { confirmReplace != nil }, set: { if !$0 { confirmReplace = nil } }),
                            titleVisibility: .visible,
                            presenting: confirmReplace) { pending in
            Button("Replace with \(pending.source)", role: .destructive) {
                bodyText = pending.text
                confirmReplace = nil
            }
            Button("Add to the end") {
                bodyText = bodyText.trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n" + pending.text
                confirmReplace = nil
            }
        } message: { _ in
            Text("Your current text will be replaced. Undo is available right after.")
        }
        .alert(notice ?? "", isPresented: Binding(get: { notice != nil }, set: { if !$0 { notice = nil } })) {
            Button("OK", role: .cancel) { notice = nil }
        }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            TextField("Title", text: $title, axis: .vertical)
                .font(Font(SignalFont.uiFont(.heading)))
                .foregroundStyle(Signal.ink)
                .focused($focus, equals: .title)
                .submitLabel(.next)
                .onSubmit { focus = .body }
                .padding(.horizontal, Signal.Space.s5)
                .padding(.top, Signal.Space.s4)
                .padding(.bottom, Signal.Space.s3)

            Rectangle().fill(Signal.line).frame(height: 1)

            ZStack(alignment: .topLeading) {
                TextEditor(text: $bodyText)
                    .font(Font(SignalFont.uiFont(.bodyLarge)))
                    .lineSpacing(6)
                    .foregroundStyle(Signal.ink)
                    .scrollContentBackground(.hidden)
                    .focused($focus, equals: .body)
                    .padding(.horizontal, Signal.Space.s4)
                    .padding(.top, Signal.Space.s2)
                    .accessibilityLabel("Script text")
                if bodyText.isEmpty {
                    Text("Type or paste your script here.")
                        .signal(.bodyLarge)
                        .foregroundStyle(Signal.inkSubtle)
                        .padding(.horizontal, Signal.Space.s5)
                        .padding(.top, Signal.Space.s4)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)

            footer
        }
    }

    private var footer: some View {
        HStack(spacing: Signal.Space.s2) {
            let wpm = settingsStore.settings.wordsPerMinute
            Text("\(wordCount) words")
            Text("·")
            Text(isEmpty ? "Add text to start" : "about \(ReadingTime.format(ReadingTime.remaining(words: wordCount, wordsPerMinute: wpm))) at \(Int(wpm)) WPM")
            Spacer()
            Label(hasUnsavedChanges ? "Saving" : "Saved",
                  systemImage: hasUnsavedChanges ? "circle.dotted" : "checkmark")
        }
        .signal(.bodySmall)
        .foregroundStyle(Signal.inkSubtle)
        .padding(.horizontal, Signal.Space.s5)
        .padding(.vertical, Signal.Space.s3)
        .background(Signal.surface)
        .overlay(alignment: .top) { Rectangle().fill(Signal.line).frame(height: 1) }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button(action: pasteFromClipboard) { Label("Paste from clipboard", systemImage: "doc.on.clipboard") }
                Button { importing = true } label: { Label("Import text file", systemImage: "doc.badge.plus") }
                if let source = store.script(id: scriptID)?.source {
                    Divider()
                    if source.isFromNotion {
                        Button { Task { await refreshFromNotion() } } label: {
                            Label("Refresh from Notion", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(refreshing)
                        Text("From \(source.courseName), \(source.lessonTitle)")
                    } else {
                        Button { Task { await refreshFromChurchfront() } } label: {
                            Label("Refresh from Churchfront", systemImage: "arrow.triangle.2.circlepath")
                        }
                        .disabled(refreshing)
                        Text("From the Churchfront portal: \(source.courseName)")
                    }
                }
                Divider()
                Button {
                    saveNow()
                    if let copy = store.duplicate(id: scriptID) { notice = "Saved a copy named \(copy.displayTitle)." }
                } label: { Label("Duplicate", systemImage: "plus.square.on.square") }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .accessibilityLabel("More")
        }
        ToolbarItem(placement: .topBarTrailing) {
            Button {
                saveNow()
                focus = nil
                if let script = store.script(id: scriptID) { onPresent(script) }
            } label: {
                Label("Start", systemImage: "play.fill").labelStyle(.titleAndIcon)
            }
            .buttonStyle(PrimaryButtonStyle(height: Signal.Control.md))
            .disabled(isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { focus = nil }
        }
    }

    // MARK: Persistence

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let script = store.script(id: scriptID) else { return }
        title = script.title
        bodyText = script.body
        hasUnsavedChanges = false
        if script.isEmpty && script.title.isEmpty { focus = .title }
    }

    private func scheduleSave() {
        guard loaded, let script = store.script(id: scriptID) else { return }
        guard script.title != title || script.body != bodyText else {
            hasUnsavedChanges = false
            return
        }
        hasUnsavedChanges = true
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            saveNow()
        }
    }

    private func saveNow() {
        saveTask?.cancel()
        guard loaded, store.script(id: scriptID) != nil else { return }
        store.update(id: scriptID, title: title, body: bodyText)
        hasUnsavedChanges = false
    }

    private func finishEditing() {
        saveNow()
        // A brand-new script left completely empty is not kept.
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && isEmpty,
           store.script(id: scriptID) != nil {
            store.delete(id: scriptID)
        }
    }

    // MARK: Import

    private func refreshFromNotion() async {
        guard let script = store.script(id: scriptID) else { return }
        saveNow()
        refreshing = true
        defer { refreshing = false }
        do {
            if try await NotionImporter.refresh(script, in: store), let updated = store.script(id: scriptID) {
                title = updated.title
                bodyText = updated.body
                hasUnsavedChanges = false
                notice = "Updated from Notion."
            } else {
                notice = "This lesson's script was not found in Notion. It may have been renamed or moved."
            }
        } catch {
            notice = error.localizedDescription
        }
    }

    private func refreshFromChurchfront() async {
        guard let script = store.script(id: scriptID), let key = ChurchfrontImporter.portalKey(of: script) else { return }
        guard ChurchfrontClient.isSignedIn else {
            notice = "Sign in to Churchfront first: in the library, choose Import, then From Churchfront."
            return
        }
        saveNow()
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await ChurchfrontImporter.download(key, into: store)
            title = result.script.title
            bodyText = result.script.body
            hasUnsavedChanges = false
            notice = "Updated from the portal."
        } catch {
            notice = error.localizedDescription
        }
    }

    private func pasteFromClipboard() {
        guard let text = UIPasteboard.general.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            notice = "The clipboard has no text to paste."
            return
        }
        offerReplace(with: ScriptStore.normalizeLineEndings(text), source: "clipboard text")
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            let accessing = url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let text = try ScriptStore.decodeText(data, fileExtension: url.pathExtension)
                offerReplace(with: text, source: url.lastPathComponent)
            } catch {
                notice = "\(url.lastPathComponent) could not be read as text."
            }
        case .failure(let error):
            notice = "Import did not finish: \(error.localizedDescription)"
        }
    }

    private func offerReplace(with text: String, source: String) {
        if isEmpty {
            bodyText = text
            if title.isEmpty { title = Script.suggestedTitle(for: text) }
        } else {
            confirmReplace = PendingReplace(text: text, source: source)
        }
    }
}
