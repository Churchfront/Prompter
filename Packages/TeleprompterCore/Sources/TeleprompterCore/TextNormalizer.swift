import Foundation

/// Turns script words and recognized words into a shared comparable form.
///
/// Both sides of the comparison go through the same normalizer, so mappings are
/// symmetric: "two", "2", "too" and "to" all become "to". That keeps common
/// speech-recognition substitutions (homophones, digits versus number words,
/// contractions with or without apostrophes) from breaking the alignment.
public enum TextNormalizer {

    /// Canonical forms applied after lowercasing and stripping punctuation.
    static let canonical: [String: String] = {
        var map: [String: String] = [:]
        // Number words and digits. Homophones of numbers collapse onto one key.
        let numbers: [(String, String)] = [
            ("zero", "0"), ("one", "1"), ("won", "1"), ("three", "3"), ("five", "5"),
            ("six", "6"), ("seven", "7"), ("eight", "8"), ("ate", "8"), ("nine", "9"),
            ("ten", "10"), ("eleven", "11"), ("twelve", "12"), ("thirteen", "13"),
            ("fourteen", "14"), ("fifteen", "15"), ("sixteen", "16"), ("seventeen", "17"),
            ("eighteen", "18"), ("nineteen", "19"), ("twenty", "20"), ("thirty", "30"),
            ("forty", "40"), ("fifty", "50"), ("sixty", "60"), ("seventy", "70"),
            ("eighty", "80"), ("ninety", "90"), ("hundred", "100"), ("thousand", "1000")
        ]
        for (word, digit) in numbers { map[word] = digit }
        // "to / too / two / 2" and "for / four / 4" are the most common homophone swaps.
        for word in ["too", "two", "2"] { map[word] = "to" }
        for word in ["four", "4"] { map[word] = "for" }
        // Ordinals.
        let ordinals = ["1st": "first", "2nd": "second", "3rd": "third", "4th": "fourth",
                        "5th": "fifth", "6th": "sixth", "7th": "seventh", "8th": "eighth",
                        "9th": "ninth", "10th": "tenth"]
        for (k, v) in ordinals { map[k] = v }
        // Homophones and spelling variants the recognizer swaps freely.
        let variants: [String: String] = [
            "their": "there", "theyre": "there",
            "youre": "your",
            "whose": "whos",
            "hear": "here",
            "write": "right", "rite": "right",
            "hole": "whole",
            "buy": "by", "bye": "by",
            "knew": "new",
            "piece": "peace",
            "prey": "pray",
            "sun": "son",
            "ok": "okay",
            "mr": "mister", "mrs": "missus", "dr": "doctor",
            "vs": "versus", "etc": "etcetera",
            "thru": "through",
            "till": "until", "til": "until",
            "gonna": "going", "wanna": "want"
        ]
        for (k, v) in variants { map[k] = v }
        return map
    }()

    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "\u{2018}", "`", "\u{02BC}"]

    /// Normalizes a single raw word. Returns an empty string when nothing comparable is left.
    public static func normalize<S: StringProtocol>(_ raw: S) -> String {
        if raw == "&" { return "and" }
        var folded = String(raw)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        folded.removeAll { apostrophes.contains($0) }
        let cleaned = String(folded.filter { $0.isLetter || $0.isNumber })
        if let mapped = canonical[cleaned] { return mapped }
        return cleaned
    }

    /// Splits free text (for example a recognizer transcript) into normalized words.
    public static func words(in text: String) -> [String] {
        WordScanner.scan(text).compactMap { word in
            let n = normalize(word.text)
            return n.isEmpty ? nil : n
        }
    }

    /// Words that carry little information on their own. A match on one of these
    /// counts for less than a match on a content word.
    public static let stopWords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "of", "to", "in", "on", "at", "for",
        "is", "it", "its", "i", "you", "we", "he", "she", "they", "that", "this",
        "be", "as", "with", "so", "if", "my", "your", "our", "me", "us", "do", "was",
        "are", "not", "there", "by", "im", "from", "his", "her", "them", "were",
        "have", "has", "had", "will", "can", "just", "all", "what", "who", "1"
    ]

    /// Relative evidence weight of a matched word.
    public static func weight(of normalized: String) -> Double {
        if stopWords.contains(normalized) { return 0.5 }
        if normalized.count >= 6 { return 1.2 }
        return 1.0
    }
}

/// A raw word found in text, with its UTF-16 range and the separator text before it.
struct RawWord {
    let text: String
    let range: NSRange
    let separatorBefore: String
}

/// Finds words in text. Letters and digits form words; an apostrophe inside a
/// word ("don't", "church's") stays part of it; "&" stands alone as a word.
/// Hyphens and dashes separate words because people say "well being" as two words.
enum WordScanner {
    private static let apostrophes: Set<Character> = ["'", "\u{2019}", "`", "\u{02BC}"]

    static func scan(_ text: String) -> [RawWord] {
        var result: [RawWord] = []
        let chars = Array(text)
        var utf16Offset = 0
        var wordStart: Int? = nil
        var wordStartOffset = 0
        var current = ""
        var separator = ""

        func flush(endOffset: Int) {
            guard !current.isEmpty else { return }
            result.append(RawWord(text: current,
                                  range: NSRange(location: wordStartOffset, length: endOffset - wordStartOffset),
                                  separatorBefore: separator))
            current = ""
            separator = ""
            wordStart = nil
        }

        var i = 0
        while i < chars.count {
            let c = chars[i]
            let len = c.utf16.count
            let isWordChar = c.isLetter || c.isNumber
            if isWordChar {
                if wordStart == nil {
                    wordStart = i
                    wordStartOffset = utf16Offset
                }
                current.append(c)
            } else if apostrophes.contains(c), !current.isEmpty,
                      i + 1 < chars.count, chars[i + 1].isLetter {
                current.append(c)
            } else if c == "&" {
                flush(endOffset: utf16Offset)
                result.append(RawWord(text: "&",
                                      range: NSRange(location: utf16Offset, length: len),
                                      separatorBefore: separator))
                separator = ""
            } else {
                flush(endOffset: utf16Offset)
                separator.append(c)
            }
            utf16Offset += len
            i += 1
        }
        flush(endOffset: utf16Offset)
        return result
    }
}
