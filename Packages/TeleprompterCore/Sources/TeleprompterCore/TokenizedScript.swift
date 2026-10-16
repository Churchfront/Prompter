import Foundation

/// One spoken word of the script.
public struct ScriptToken: Equatable, Sendable {
    /// Normalized comparison form (see `TextNormalizer`).
    public let normalized: String
    /// UTF-16 range of the word in the original script text (NSString / TextKit coordinates).
    public let range: NSRange
    /// Index of the sentence this word belongs to.
    public let sentence: Int
    /// Index of the phrase (clause between commas, dashes, semicolons or sentence ends).
    public let phrase: Int
    /// Index of the paragraph (text between line breaks).
    public let paragraph: Int
    /// Evidence weight when matched.
    public let weight: Double
}

/// A script broken into comparable words with sentence and phrase structure.
public struct TokenizedScript: Sendable {
    public let tokens: [ScriptToken]
    public let sentenceStarts: [Int]
    public let phraseStarts: [Int]
    /// Number of UTF-16 code units in the source text.
    public let utf16Length: Int
    /// Stage directions such as "[ON CAMERA]": shown to the reader, never spoken,
    /// so they produce no tokens and the matcher never waits for them.
    public let cueRanges: [NSRange]

    /// Bracketed text on a single line counts as a stage direction.
    static let cuePattern = try! NSRegularExpression(pattern: "\\[[^\\]\\n]*\\]")

    public var count: Int { tokens.count }
    public var isEmpty: Bool { tokens.isEmpty }

    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "st", "vs", "etc", "eg", "ie", "jr", "sr", "prof", "rev", "pastor"
    ]

    public init(text: String) {
        let raw = WordScanner.scan(text)
        var tokens: [ScriptToken] = []
        tokens.reserveCapacity(raw.count)
        var sentenceStarts: [Int] = []
        var phraseStarts: [Int] = []
        var sentence = -1
        var phrase = -1
        var paragraph = 0
        var previousRaw: String? = nil
        let ns = text as NSString
        let cues = Self.cuePattern.matches(in: text, range: NSRange(location: 0, length: ns.length)).map(\.range)
        var cueIndex = 0
        var skippedCue = false

        for word in raw {
            // Skip words inside stage directions; a direction also ends the sentence before it.
            while cueIndex < cues.count && NSMaxRange(cues[cueIndex]) <= word.range.location { cueIndex += 1 }
            if cueIndex < cues.count, NSLocationInRange(word.range.location, cues[cueIndex]) {
                skippedCue = true
                continue
            }
            let normalized = TextNormalizer.normalize(word.text)
            guard !normalized.isEmpty else { continue }

            let sep = word.separatorBefore
            let hasNewline = sep.contains { $0.isNewline } || skippedCue
            skippedCue = false
            var sentenceBreak = tokens.isEmpty || hasNewline
            if !sentenceBreak, sep.contains(where: { ".!?\u{2026}".contains($0) }) {
                // "Dr. Smith" is not a sentence break.
                let prev = previousRaw.map { $0.lowercased().filter(\.isLetter) } ?? ""
                sentenceBreak = !Self.abbreviations.contains(prev) || sep.contains("!") || sep.contains("?")
            }
            let phraseBreak = sentenceBreak
                || sep.contains(where: { ",;:\u{2014}\u{2013}()[]\"\u{201C}\u{201D}".contains($0) })
                || (sep.contains("-") && sep.contains(where: { $0.isWhitespace }))

            if hasNewline && !tokens.isEmpty { paragraph += 1 }
            if sentenceBreak {
                sentence += 1
                sentenceStarts.append(tokens.count)
            }
            if phraseBreak {
                phrase += 1
                phraseStarts.append(tokens.count)
            }
            tokens.append(ScriptToken(normalized: normalized,
                                      range: word.range,
                                      sentence: sentence,
                                      phrase: phrase,
                                      paragraph: paragraph,
                                      weight: TextNormalizer.weight(of: normalized)))
            previousRaw = word.text
        }
        self.tokens = tokens
        self.sentenceStarts = sentenceStarts
        self.phraseStarts = phraseStarts
        self.utf16Length = ns.length
        self.cueRanges = cues
    }

    // MARK: - Structure queries

    /// Token indices of the sentence containing `index`.
    public func sentenceRange(containing index: Int) -> Range<Int> {
        guard !tokens.isEmpty else { return 0..<0 }
        let i = clamp(index)
        let s = tokens[i].sentence
        let start = sentenceStarts[s]
        let end = s + 1 < sentenceStarts.count ? sentenceStarts[s + 1] : tokens.count
        return start..<end
    }

    /// Token indices of the phrase containing `index`.
    public func phraseRange(containing index: Int) -> Range<Int> {
        guard !tokens.isEmpty else { return 0..<0 }
        let i = clamp(index)
        let p = tokens[i].phrase
        let start = phraseStarts[p]
        let end = p + 1 < phraseStarts.count ? phraseStarts[p + 1] : tokens.count
        return start..<end
    }

    /// First token of the sentence after the one containing `index`, or nil at the end.
    public func nextSentenceStart(after index: Int) -> Int? {
        guard !tokens.isEmpty else { return nil }
        let s = index < 0 ? -1 : tokens[clamp(index)].sentence
        return s + 1 < sentenceStarts.count ? sentenceStarts[s + 1] : nil
    }

    /// Start of the sentence to rewind to. Inside a sentence (past its first two
    /// words) that is the sentence's own start; otherwise the previous sentence.
    public func rewindTarget(from index: Int) -> Int {
        guard !tokens.isEmpty, index > 0 else { return 0 }
        let i = clamp(index)
        let s = tokens[i].sentence
        let start = sentenceStarts[s]
        if i - start > 2 { return start }
        return s > 0 ? sentenceStarts[s - 1] : 0
    }

    /// Token whose range contains or follows the given UTF-16 offset.
    public func tokenIndex(atUTF16Offset offset: Int) -> Int {
        guard !tokens.isEmpty else { return 0 }
        var lo = 0, hi = tokens.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if NSMaxRange(tokens[mid].range) <= offset { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Script words a speech recognizer is likely to miss (names, rare words),
    /// handed to the recognizer as contextual hints.
    public func distinctiveWords(in source: String, limit: Int = 100) -> [String] {
        let ns = source as NSString
        var counts: [String: (count: Int, display: String)] = [:]
        for token in tokens where token.normalized.count >= 5 && !token.normalized.allSatisfy(\.isNumber) {
            let display = ns.substring(with: token.range)
            let entry = counts[token.normalized]
            counts[token.normalized] = ((entry?.count ?? 0) + 1, entry?.display ?? display)
        }
        // Capitalized words first (likely names), then longest.
        return counts.values
            .sorted { a, b in
                let aCap = a.display.first?.isUppercase ?? false
                let bCap = b.display.first?.isUppercase ?? false
                if aCap != bCap { return aCap }
                return a.display.count > b.display.count
            }
            .prefix(limit)
            .map(\.display)
    }

    public func clamp(_ index: Int) -> Int {
        min(max(index, 0), max(tokens.count - 1, 0))
    }
}
