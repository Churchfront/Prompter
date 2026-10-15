import Foundation
import Security
import TeleprompterCore

/// A Notion page that can be imported.
struct NotionPageSummary: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String?
    let lastEdited: Date?
    let url: URL?
}

enum NotionError: LocalizedError, Equatable {
    case notConnected
    case invalidToken
    case notShared
    case rateLimited
    case network(String)
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            "Connect Notion first."
        case .invalidToken:
            "Notion did not accept this token. Copy the Internal Integration Secret again from notion.so/my-integrations."
        case .notShared:
            "Prompter cannot see this page. In Notion, open the page (or its parent, such as Course Development), choose ••• > Connections, and add your Prompter integration."
        case .rateLimited:
            "Notion asked us to slow down. Wait a few seconds and try again."
        case .network(let detail):
            "Notion could not be reached (\(detail)). Check the internet connection and try again."
        case .server(let code, let message):
            "Notion returned an error (\(code)): \(message)"
        }
    }
}

/// Read-only Notion API client. Uses an internal integration token stored in
/// the Keychain. Only reads pages the reader has shared with the integration.
actor NotionClient {
    static let shared = NotionClient()

    private let base = URL(string: "https://api.notion.com/v1/")!
    private let version = "2022-06-28"
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()

    // MARK: Connection

    nonisolated static var isConnected: Bool { NotionTokenStore.load() != nil }

    /// Checks the token with Notion, then stores it. Returns the workspace bot name.
    func connect(token rawToken: String) async throws -> String {
        let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        let me = try await request("users/me", token: token)
        try NotionTokenStore.save(token)
        let bot = me["bot"] as? [String: Any]
        return (bot?["workspace_name"] as? String) ?? (me["name"] as? String) ?? "Notion"
    }

    nonisolated static func disconnect() {
        NotionTokenStore.delete()
    }

    // MARK: Reading

    /// Pages matching `query` that the integration can see.
    func searchPages(_ query: String) async throws -> [NotionPageSummary] {
        let body: [String: Any] = [
            "query": query,
            "filter": ["property": "object", "value": "page"],
            "sort": ["direction": "descending", "timestamp": "last_edited_time"],
            "page_size": 50
        ]
        let json = try await request("search", method: "POST", body: body)
        let results = json["results"] as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return results.compactMap { page in
            guard let id = page["id"] as? String else { return nil }
            let icon = (page["icon"] as? [String: Any])?["emoji"] as? String
            let edited = (page["last_edited_time"] as? String).flatMap { iso.date(from: $0) }
            let url = (page["url"] as? String).flatMap(URL.init(string:))
            return NotionPageSummary(id: id, title: Self.title(of: page), icon: icon, lastEdited: edited, url: url)
        }
    }

    /// Page title by ID.
    func pageTitle(_ pageID: String) async throws -> String {
        Self.title(of: try await request("pages/\(pageID)"))
    }

    /// All blocks of a page. Descends only into blocks that can hold script
    /// text (toggles, headings, lists), which keeps request counts low.
    func blocks(of blockID: String, depth: Int = 0) async throws -> [NotionBlock] {
        var collected: [NotionBlock] = []
        var cursor: String?
        repeat {
            var path = "blocks/\(blockID)/children?page_size=100"
            if let cursor { path += "&start_cursor=\(cursor)" }
            let json = try await request(path)
            for object in json["results"] as? [[String: Any]] ?? [] {
                guard var block = NotionBlock(apiObject: object) else { continue }
                let descend = block.hasChildren && depth < 4
                    && !["child_page", "child_database", "callout", "synced_block", "column_list"].contains(block.type)
                if descend { block.children = try await blocks(of: block.id, depth: depth + 1) }
                collected.append(block)
            }
            cursor = (json["has_more"] as? Bool) == true ? json["next_cursor"] as? String : nil
        } while cursor != nil
        return collected
    }

    // MARK: HTTP

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil,
                         token: String? = nil, attempt: Int = 0) async throws -> [String: Any] {
        guard let token = token ?? NotionTokenStore.load() else { throw NotionError.notConnected }
        guard let url = URL(string: path, relativeTo: base) else { throw NotionError.network("bad URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "Notion-Version")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw NotionError.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        switch status {
        case 200..<300:
            return json
        case 401:
            throw NotionError.invalidToken
        case 403, 404:
            throw NotionError.notShared
        case 429:
            // Notion allows about three requests a second; back off and retry.
            guard attempt < 3 else { throw NotionError.rateLimited }
            let wait = Double((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 1.0
            try await Task.sleep(for: .seconds(max(wait, 0.5)))
            return try await self.request(path, method: method, body: body, token: token, attempt: attempt + 1)
        default:
            throw NotionError.server(status, json["message"] as? String ?? "unknown")
        }
    }

    private static func title(of page: [String: Any]) -> String {
        let properties = page["properties"] as? [String: Any] ?? [:]
        for case let property as [String: Any] in properties.values where property["type"] as? String == "title" {
            let parts = property["title"] as? [[String: Any]] ?? []
            let text = parts.compactMap { $0["plain_text"] as? String }.joined()
            if !text.isEmpty { return text }
        }
        return "Untitled"
    }
}

/// Keeps the Notion token in the Keychain (never in files or UserDefaults).
enum NotionTokenStore {
    private static let service = "com.churchfront.prompter.notion"
    private static let account = "integration-token"

    static func save(_ token: String) throws {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data(token.utf8)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw NotionError.network("could not save the token to the Keychain (\(status))")
        }
    }

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Imports lessons into the library.
@MainActor
enum NotionImporter {
    static func lessons(for page: NotionPageSummary) async throws -> [NotionLesson] {
        let blocks = try await NotionClient.shared.blocks(of: page.id)
        let lessons = NotionScriptExtractor.lessons(pageID: page.id, blocks: blocks)
        if !lessons.isEmpty { return lessons }
        let whole = NotionScriptExtractor.wholePage(pageID: page.id, title: page.title, blocks: blocks)
        return whole.body.isEmpty ? [] : [whole]
    }

    static func scriptTitle(course: String, lesson: NotionLesson) -> String {
        lesson.scriptLabel == "Page" ? course : "\(course) · \(lesson.lessonTitle)"
    }

    /// Saves lessons; returns how many were new and how many were refreshed.
    static func save(_ lessons: [NotionLesson], from page: NotionPageSummary, into store: ScriptStore) -> (created: Int, updated: Int) {
        let course = NotionScriptExtractor.shortCourseName(page.title)
        var created = 0, updated = 0
        for lesson in lessons {
            let source = ScriptSource(key: lesson.key, notionPageID: page.id, courseName: course,
                                      lessonTitle: lesson.lessonTitle, importedAt: .now)
            let result = store.upsertImported(title: scriptTitle(course: course, lesson: lesson),
                                              body: lesson.body, source: source)
            if result.created { created += 1 } else { updated += 1 }
        }
        return (created, updated)
    }

    /// Pulls the latest text for one imported script.
    static func refresh(_ script: Script, in store: ScriptStore) async throws -> Bool {
        guard let source = script.source else { return false }
        let title = try await NotionClient.shared.pageTitle(source.notionPageID)
        let page = NotionPageSummary(id: source.notionPageID, title: title, icon: nil, lastEdited: nil, url: nil)
        let lessons = try await lessons(for: page)
        guard let lesson = lessons.first(where: { $0.key == source.key }) else { return false }
        _ = save([lesson], from: page, into: store)
        return true
    }
}
