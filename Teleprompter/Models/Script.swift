import Foundation
import TeleprompterCore

/// A script imported from Notion: the course page and lesson it came from.
struct ScriptSource: Codable, Hashable {
    var key: String
    var notionPageID: String
    var courseName: String
    var lessonTitle: String
    var importedAt: Date
}

struct Script: Identifiable, Codable, Hashable {
    var id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var modifiedAt: Date
    /// Token index the reader last reached, for "pick up where you left off".
    var lastPosition: Int?
    var lastPresentedAt: Date?
    /// Where the script was imported from, so it can be refreshed in place.
    var source: ScriptSource?

    init(id: UUID = UUID(), title: String, body: String, createdAt: Date = .now, modifiedAt: Date = .now) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled script" : trimmed
    }

    var wordCount: Int { TextNormalizer.words(in: TokenizedScript.removingCues(body)).count }

    var isEmpty: Bool { body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// First lines of the script, for previews in the library.
    var preview: String {
        let collapsed = TokenizedScript.removingCues(body)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(400))
    }

    /// A title taken from the first line of pasted or imported text.
    static func suggestedTitle(for text: String) -> String {
        let firstLine = text
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
        guard firstLine.count > 60 else { return firstLine }
        let cut = firstLine.prefix(60)
        if let space = cut.lastIndex(of: " ") { return String(cut[..<space]) }
        return String(cut)
    }
}
