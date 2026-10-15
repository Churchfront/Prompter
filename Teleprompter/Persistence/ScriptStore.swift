import Foundation
import Observation
import UniformTypeIdentifiers

/// The script library. Each script is one JSON file in Application Support,
/// written atomically, so a crash mid-save can never leave a half-written script.
@MainActor
@Observable
final class ScriptStore {
    private(set) var scripts: [Script] = []
    /// Last save or load problem, shown in the library.
    var lastError: String?

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    @ObservationIgnored private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let base = directory ?? Self.defaultDirectory()
        self.directory = base
        self.defaults = defaults
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            lastError = "Scripts folder could not be created: \(error.localizedDescription)"
        }
        if directory == nil { Self.migrateLegacyMacFolder(to: base) }
        load()
        seedSampleIfNeeded()
    }

    /// iOS keeps Application Support inside the app's sandbox. The Mac app is
    /// not sandboxed, so it uses a folder named for the app.
    static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if targetEnvironment(macCatalyst)
        return support.appendingPathComponent("com.churchfront.prompter/Scripts", isDirectory: true)
        #else
        return support.appendingPathComponent("Scripts", isDirectory: true)
        #endif
    }

    /// Early Mac builds saved to ~/Library/Application Support/Scripts. Move only
    /// files that are this app's scripts; leave anything else untouched.
    private static func migrateLegacyMacFolder(to destination: URL) {
        #if targetEnvironment(macCatalyst)
        let fm = FileManager.default
        let legacy = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scripts", isDirectory: true)
        guard let files = try? fm.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for file in files where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let script = try? decoder.decode(Script.self, from: data),
                  file.deletingPathExtension().lastPathComponent == script.id.uuidString else { continue }
            let target = destination.appendingPathComponent(file.lastPathComponent)
            if !fm.fileExists(atPath: target.path) { try? fm.moveItem(at: file, to: target) }
        }
        if (try? fm.contentsOfDirectory(atPath: legacy.path))?.filter({ !$0.hasPrefix(".") }).isEmpty == true {
            try? fm.removeItem(at: legacy)
        }
        #endif
    }

    // MARK: Imported scripts

    func script(forSourceKey key: String) -> Script? {
        scripts.first { $0.source?.key == key }
    }

    /// Creates or refreshes an imported script. Refreshing keeps the script's
    /// identity; the text is replaced with the source's current version.
    @discardableResult
    func upsertImported(title: String, body: String, source: ScriptSource) -> (script: Script, created: Bool) {
        if var existing = script(forSourceKey: source.key) {
            let changed = existing.body != body || existing.title != title
            existing.title = title
            existing.body = body
            existing.source = source
            if changed {
                existing.modifiedAt = .now
                existing.lastPosition = nil
            }
            save(existing)
            return (existing, false)
        }
        var script = Script(title: title, body: body)
        script.source = source
        save(script)
        return (script, true)
    }

    // MARK: Queries

    func script(id: UUID) -> Script? { scripts.first { $0.id == id } }

    // MARK: Changes

    @discardableResult
    func create(title: String = "", body: String = "") -> Script {
        let script = Script(title: title, body: body)
        save(script)
        return script
    }

    /// Inserts or replaces a script and writes it to disk.
    func save(_ script: Script) {
        if let index = scripts.firstIndex(where: { $0.id == script.id }) {
            scripts[index] = script
        } else {
            scripts.append(script)
        }
        sort()
        write(script)
    }

    /// Saves edited text. Only bumps the modified date when something changed.
    func update(id: UUID, title: String, body: String) {
        guard var script = script(id: id) else { return }
        guard script.title != title || script.body != body else { return }
        script.title = title
        script.body = body
        script.modifiedAt = .now
        if script.lastPosition != nil { script.lastPosition = nil } // text changed; old position is stale
        save(script)
    }

    func rename(id: UUID, to title: String) {
        guard var script = script(id: id) else { return }
        script.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        script.modifiedAt = .now
        save(script)
    }

    @discardableResult
    func duplicate(id: UUID) -> Script? {
        guard let original = script(id: id) else { return nil }
        let copy = Script(title: "\(original.displayTitle) copy", body: original.body)
        save(copy)
        return copy
    }

    func delete(id: UUID) {
        scripts.removeAll { $0.id == id }
        do {
            let url = fileURL(for: id)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        } catch {
            lastError = "The script could not be deleted: \(error.localizedDescription)"
        }
    }

    /// Remembers where the reader stopped without reordering the library.
    func updateResumePosition(id: UUID, position: Int?) {
        guard var script = script(id: id) else { return }
        guard script.lastPosition != position else { return }
        script.lastPosition = position
        script.lastPresentedAt = .now
        if let index = scripts.firstIndex(where: { $0.id == id }) { scripts[index] = script }
        write(script)
    }

    // MARK: Import

    static let importableTypes: [UTType] = [.plainText, .utf8PlainText, .text, .rtf]

    /// Creates a script from a plain-text or RTF file (for example from the Files app).
    @discardableResult
    func importFile(at url: URL) throws -> Script {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let text = try Self.decodeText(data, fileExtension: url.pathExtension)
        let title = url.deletingPathExtension().lastPathComponent
        return create(title: title, body: text)
    }

    static func decodeText(_ data: Data, fileExtension: String) throws -> String {
        var text: String?
        if fileExtension.lowercased() == "rtf" {
            text = try? NSAttributedString(data: data,
                                           options: [.documentType: NSAttributedString.DocumentType.rtf],
                                           documentAttributes: nil).string
        }
        if text == nil {
            // UTF-16 only with a byte order mark; otherwise it "decodes" any even-length bytes.
            let hasUTF16BOM = data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF])
            let encodings: [String.Encoding] = hasUTF16BOM ? [.utf16] : [.utf8, .windowsCP1252, .macOSRoman]
            for encoding in encodings {
                if let decoded = String(data: data, encoding: encoding) { text = decoded; break }
            }
        }
        guard let result = text else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return normalizeLineEndings(result)
    }

    static func normalizeLineEndings(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    // MARK: Disk

    private func fileURL(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).json")
    }

    private func write(_ script: Script) {
        do {
            let data = try encoder.encode(script)
            try data.write(to: fileURL(for: script.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            lastError = nil
        } catch {
            lastError = "\(script.displayTitle) could not be saved: \(error.localizedDescription)"
        }
    }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var loaded: [Script] = []
        for url in files where url.pathExtension == "json" {
            do {
                loaded.append(try decoder.decode(Script.self, from: Data(contentsOf: url)))
            } catch {
                // Keep unreadable files aside instead of deleting the reader's text.
                let aside = url.deletingPathExtension().appendingPathExtension("unreadable")
                try? FileManager.default.moveItem(at: url, to: aside)
                lastError = "One script could not be read and was set aside."
            }
        }
        scripts = loaded
        sort()
    }

    private func sort() {
        scripts.sort { $0.modifiedAt > $1.modifiedAt }
    }

    private func seedSampleIfNeeded() {
        let key = "didSeedSampleScript"
        guard !defaults.bool(forKey: key) else { return }
        defaults.set(true, forKey: key)
        guard scripts.isEmpty else { return }
        create(title: "Welcome to Prompter", body: SampleScript.text)
    }
}

enum SampleScript {
    static var text: String {
        if let url = Bundle.main.url(forResource: "SampleScript", withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return "Welcome. This is a sample script. Press play and start reading out loud."
    }
}
