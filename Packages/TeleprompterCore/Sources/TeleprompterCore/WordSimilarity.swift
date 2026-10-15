import Foundation

/// Fuzzy similarity between two normalized words, from 0 (unrelated) to 1 (identical).
public enum WordSimilarity {

    public static func score(_ a: String, _ b: String) -> Double {
        if a == b { return 1 }
        if a.isEmpty || b.isEmpty { return 0 }
        let la = a.count, lb = b.count
        let shorter = min(la, lb), longer = max(la, lb)
        // Short words must match exactly: "fit" and "fat" are different words.
        if shorter < 3 { return 0 }
        // Partial results often truncate the last word; plurals differ by a suffix.
        if shorter >= 4 {
            let (s, l) = la < lb ? (a, b) : (b, a)
            if l.hasPrefix(s) { return longer - shorter <= 3 ? 0.85 : 0.78 }
        }
        if longer - shorter > max(1, longer / 3) { return 0 }
        let distance = levenshtein(Array(a.unicodeScalars), Array(b.unicodeScalars))
        return max(0, 1 - Double(distance) / Double(longer))
    }

    static func levenshtein(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
