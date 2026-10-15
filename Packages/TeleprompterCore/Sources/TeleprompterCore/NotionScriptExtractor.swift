import Foundation

/// A Notion block reduced to what script import needs.
public struct NotionBlock: Sendable, Equatable {
    public let id: String
    public let type: String
    public let text: String
    public var children: [NotionBlock]
    public let hasChildren: Bool

    public init(id: String, type: String, text: String, children: [NotionBlock] = [], hasChildren: Bool = false) {
        self.id = id
        self.type = type
        self.text = text
        self.children = children
        self.hasChildren = hasChildren
    }

    /// Builds a block from a Notion API block object (children are filled in separately).
    public init?(apiObject object: [String: Any]) {
        guard let id = object["id"] as? String, let type = object["type"] as? String else { return nil }
        self.id = id
        self.type = type
        self.hasChildren = object["has_children"] as? Bool ?? false
        self.children = []
        let payload = object[type] as? [String: Any]
        let richText = payload?["rich_text"] as? [[String: Any]] ?? []
        self.text = richText.compactMap { $0["plain_text"] as? String }.joined()
    }

    var isHeading: Bool { type == "heading_1" || type == "heading_2" || type == "heading_3" }
}

/// One lesson script found in a course page.
public struct NotionLesson: Sendable, Equatable, Identifiable {
    /// Stable identity for re-imports: page plus lesson title.
    public let key: String
    public let lessonTitle: String
    public let scriptLabel: String
    public let body: String
    public var id: String { key }
    public var wordCount: Int { TextNormalizer.words(in: TokenizedScript.removingCues(body)).count }
}

/// Turns a Churchfront course build doc into teleprompter scripts.
///
/// Course docs list lessons as level-2 headings. A lesson's script lives in a
/// toggle whose title starts with "Script". Bracketed lines such as
/// "[ON CAMERA]" are stage directions and stay as cues; subheadings inside a
/// script become cues too. Callouts are production notes and are left out.
public enum NotionScriptExtractor {

    /// "🎥 Video 101: The Fundamentals … — Course Build Doc" becomes "Video 101".
    public static func shortCourseName(_ pageTitle: String) -> String {
        var title = pageTitle
        if let dash = title.range(of: " — ") { title = String(title[..<dash.lowerBound]) }
        title = String(title.drop { !$0.isLetter && !$0.isNumber })
        if let colon = title.firstIndex(of: ":") { title = String(title[..<colon]) }
        return title.trimmingCharacters(in: .whitespaces)
    }

    public static func lessons(pageID: String, blocks: [NotionBlock]) -> [NotionLesson] {
        var result: [NotionLesson] = []
        var currentLesson = ""
        func walk(_ blocks: [NotionBlock]) {
            for block in blocks {
                if block.type == "heading_2" || block.type == "heading_1" {
                    currentLesson = block.text.trimmingCharacters(in: .whitespaces)
                }
                let isScriptToggle = (block.type == "toggle" || block.isHeading)
                    && block.text.lowercased().hasPrefix("script")
                if isScriptToggle {
                    let body = render(block.children)
                    if !body.isEmpty {
                        let title = currentLesson.isEmpty ? block.text : currentLesson
                        result.append(NotionLesson(key: "notion:\(pageID):\(title)",
                                                   lessonTitle: title,
                                                   scriptLabel: block.text,
                                                   body: body))
                    }
                } else if !block.children.isEmpty && block.type != "callout" {
                    walk(block.children)
                }
            }
        }
        walk(blocks)
        return result
    }

    /// Whole-page fallback for pages without script toggles.
    public static func wholePage(pageID: String, title: String, blocks: [NotionBlock]) -> NotionLesson {
        NotionLesson(key: "notion:\(pageID):page", lessonTitle: title, scriptLabel: "Page", body: render(blocks))
    }

    /// Script blocks to prompter text: paragraphs separated by blank lines.
    public static func render(_ blocks: [NotionBlock]) -> String {
        var parts: [String] = []
        func add(_ blocks: [NotionBlock]) {
            for block in blocks {
                let text = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
                switch block.type {
                case "callout", "divider", "image", "video", "file", "pdf", "embed", "bookmark", "table_of_contents":
                    continue
                case "heading_1", "heading_2", "heading_3":
                    if !text.isEmpty { parts.append(text.hasPrefix("[") ? text : "[\(text)]") }
                case "bulleted_list_item":
                    if !text.isEmpty { parts.append("• " + text) }
                case "numbered_list_item", "paragraph", "quote", "to_do", "toggle":
                    if !text.isEmpty { parts.append(text) }
                default:
                    if !text.isEmpty { parts.append(text) }
                }
                if !block.children.isEmpty { add(block.children) }
            }
        }
        add(blocks)
        return parts.joined(separator: "\n\n")
    }
}

extension TokenizedScript {
    /// The text with stage directions removed (for word counts).
    public static func removingCues(_ text: String) -> String {
        let ns = text as NSString
        return cuePattern.stringByReplacingMatches(in: text, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
    }
}
