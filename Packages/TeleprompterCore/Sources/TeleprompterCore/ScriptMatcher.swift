import Foundation

/// Tuning for `ScriptMatcher`. The defaults are a balanced starting point; the
/// app exposes a single "matching tolerance" control mapped onto these values.
public struct MatcherConfiguration: Sendable, Equatable {
    /// Most recent recognized words used for each alignment.
    public var tailLength = 10
    /// Similarity at or above which two words count as the same word.
    public var similarityThreshold = 0.75
    /// How far behind the current position the local search looks (tokens).
    public var lookBehind = 40
    /// How far ahead of the current position the local search looks (tokens).
    public var lookAhead = 80
    /// Forward moves up to this many tokens are ordinary reading progress.
    public var nearForward = 12
    /// Matched words needed for an ordinary forward move.
    public var minimumMatchesNear = 2
    /// Matched words needed to accept a larger forward move (a skipped sentence).
    public var minimumMatchesSkip = 3
    /// Matched words needed to move backward (the reader re-reads earlier text).
    public var minimumMatchesBackward = 5
    /// Matched words needed to relocate anywhere in the script after getting lost.
    public var minimumMatchesGlobal = 4
    /// Backward matches within this many tokens are treated as repetition and ignored.
    public var backwardTolerance = 6
    /// Consecutive unmatched updates before a whole-script search is attempted.
    public var lostUpdatesBeforeGlobalSearch = 3
    /// Required score lead of the best location over any other location.
    public var ambiguityMargin = 0.75

    public init() {}

    /// Maps a single 0 (strict) ... 1 (lenient) control onto the thresholds.
    public init(tolerance: Double) {
        self.init()
        let t = min(max(tolerance, 0), 1)
        similarityThreshold = 0.83 - 0.15 * t
        minimumMatchesSkip = t < 0.34 ? 4 : 3
        minimumMatchesGlobal = t < 0.34 ? 5 : 4
        minimumMatchesBackward = t < 0.34 ? 6 : 5
    }
}

/// What the matcher decided for one recognizer update.
public enum MatchOutcome: Equatable, Sendable {
    /// Ordinary forward progress (including a skipped sentence nearby).
    case advanced(to: Int)
    /// Relocation: backward re-read, or recovery after the reader was lost.
    case jumped(to: Int)
    /// Position unchanged.
    case held(HoldReason)

    public var newPosition: Int? {
        switch self {
        case .advanced(let p), .jumped(let p): return p
        case .held: return nil
        }
    }
}

public enum HoldReason: Equatable, Sendable {
    case emptyScript
    case noSpeech
    /// The latest words match where the reader already is (pause, repetition).
    case noNewWords
    /// Some match exists but the evidence is too thin to move.
    case lowConfidence
    /// Two or more places in the script fit equally well.
    case ambiguous
    /// The latest words do not match the script near the reader.
    case offScript
}

/// Aligns recognized speech with the script and tracks the reading position.
///
/// Each update aligns the last few recognized words against script text near
/// the current position using a fuzzy local alignment (Smith-Waterman with
/// word similarity). The alignment must end on the newest spoken word, so the
/// end of the best alignment is where the reader is now. A distance prior
/// favors nearby positions, which keeps duplicate phrases elsewhere in the
/// script from pulling the position away. Weak or ambiguous evidence holds the
/// position instead of guessing. Only after several unmatched updates does the
/// matcher search the whole script, and then only accepts a strong, unique match.
public final class ScriptMatcher {
    public let script: TokenizedScript
    public var configuration: MatcherConfiguration

    /// Index of the last script word the reader has spoken; -1 before the first word.
    public private(set) var position: Int
    /// Consecutive updates without usable evidence.
    public private(set) var lostStreak = 0
    /// Number of matched words behind the last accepted move.
    public private(set) var lastEvidence = 0

    public var isLost: Bool { lostStreak >= configuration.lostUpdatesBeforeGlobalSearch }

    private var lastTail: [String] = []
    private var similarityCache: [String: [String: Double]] = [:]
    private var globalSearchCounter = 0

    // Alignment scoring.
    private let mismatchPenalty = 0.6
    private let spokenGapPenalty = 0.6
    private let scriptGapPenalty = 0.5
    private let trailingPenalty = 0.4

    public init(script: TokenizedScript, configuration: MatcherConfiguration = .init(), startPosition: Int = -1) {
        self.script = script
        self.configuration = configuration
        self.position = min(max(startPosition, -1), script.count - 1)
    }

    /// Moves the position by hand (manual reposition, jump buttons, restart).
    public func reset(to newPosition: Int) {
        position = min(max(newPosition, -1), script.count - 1)
        lostStreak = 0
        lastTail = []
        lastEvidence = 0
    }

    /// Processes the recognized words so far (oldest first) and returns the decision.
    @discardableResult
    public func process(spoken words: [String]) -> MatchOutcome {
        guard !script.isEmpty else { return .held(.emptyScript) }
        let tail = Array(words.suffix(configuration.tailLength))
        guard !tail.isEmpty else { return .held(.noSpeech) }
        if tail == lastTail { return .held(.noNewWords) }
        lastTail = tail

        let p = position
        let lo = max(0, p - configuration.lookBehind)
        let hi = min(script.count, p + 1 + configuration.lookAhead)
        let candidates = align(tail, range: lo..<hi)

        let outcome = evaluateLocal(candidates, from: p)
        switch outcome {
        case .advanced, .jumped:
            lostStreak = 0
            return outcome
        case .held(let reason):
            if reason == .noNewWords { return outcome }
            lostStreak += 1
            if lostStreak >= configuration.lostUpdatesBeforeGlobalSearch,
               let relocated = globalSearch(tail, from: p) {
                position = relocated
                lostStreak = 0
                return .jumped(to: relocated)
            }
            return outcome
        }
    }

    // MARK: - Decision

    private func distancePenalty(_ delta: Int) -> Double {
        if delta >= 0 && delta <= configuration.nearForward { return 0 }
        if delta > configuration.nearForward { return 0.08 * Double(delta - configuration.nearForward) }
        return 0.4 + 0.12 * Double(-delta)
    }

    private func evaluateLocal(_ candidates: [Candidate], from p: Int) -> MatchOutcome {
        guard !candidates.isEmpty else { return .held(.offScript) }
        func adjusted(_ c: Candidate) -> Double { c.raw - distancePenalty(c.end - p) }
        guard let best = candidates.max(by: { adjusted($0) < adjusted($1) }) else { return .held(.offScript) }
        let delta = best.end - p

        func isUnique() -> Bool {
            let rival = candidates
                .filter { abs($0.end - best.end) > 4 }
                .map(adjusted)
                .max() ?? -.infinity
            return adjusted(best) - rival >= configuration.ambiguityMargin
        }

        if delta == 0 { return .held(.noNewWords) }

        if delta < 0 {
            if -delta <= configuration.backwardTolerance { return .held(.noNewWords) }
            let strong = best.matches >= configuration.minimumMatchesBackward
                && best.run >= 4 && best.raw >= 4.5
            guard strong else { return .held(.lowConfidence) }
            guard isUnique() else { return .held(.ambiguous) }
            return accept(best, jump: true)
        }

        if delta <= configuration.nearForward {
            // The newest evidence must mean something: two consecutive matched
            // words, or one content word (not "the", "and", ...).
            let endWeight = script.tokens[best.end].weight
            let meaningfulEnd = best.run >= 2 || (endWeight >= 1.0 && !best.trailing)
            if best.matches >= configuration.minimumMatchesNear && best.raw >= 1.4 && meaningfulEnd {
                return accept(best, jump: false)
            }
            // Single word at the very start of an utterance, right where we expect it.
            if best.matches == 1 && delta <= 2 && !best.trailing && endWeight >= 1.0 && best.raw >= 0.9 {
                return accept(best, jump: false)
            }
            return .held(.lowConfidence)
        }

        // Larger forward move: the reader skipped ahead.
        let strong = best.matches >= configuration.minimumMatchesSkip && best.run >= 2 && best.raw >= 2.4
        guard strong else { return .held(.lowConfidence) }
        guard isUnique() else { return .held(.ambiguous) }
        return accept(best, jump: false)
    }

    private func accept(_ c: Candidate, jump: Bool) -> MatchOutcome {
        position = c.end
        lastEvidence = c.matches
        return jump ? .jumped(to: c.end) : .advanced(to: c.end)
    }

    /// Whole-script search, used only after the reader has been lost for a while.
    /// Accepts only a strong match that clearly beats every other location.
    private func globalSearch(_ tail: [String], from p: Int) -> Int? {
        let contentWords = tail.filter { !TextNormalizer.stopWords.contains($0) }.count
        guard contentWords >= 3 else { return nil }
        // Throttle: a long script makes this the most expensive step.
        globalSearchCounter += 1
        if script.count > 4000 && globalSearchCounter % 3 != 1 { return nil }

        let candidates = align(tail, range: 0..<script.count)
        let viable = candidates.filter {
            $0.matches >= configuration.minimumMatchesGlobal && $0.run >= 3 && $0.raw >= 4.0
        }
        func score(_ c: Candidate) -> Double { c.raw - 0.002 * Double(abs(c.end - p)) }
        guard let best = viable.max(by: { score($0) < score($1) }) else { return nil }
        let rival = candidates
            .filter { abs($0.end - best.end) > 5 }
            .map(\.raw)
            .max() ?? -.infinity
        guard best.raw - rival >= 1.5 else { return nil }
        lastEvidence = best.matches
        return best.end
    }

    // MARK: - Alignment

    struct Candidate {
        /// Script token index where the alignment ends (the reader's position).
        let end: Int
        /// Alignment score.
        let raw: Double
        /// Matched words in the alignment.
        let matches: Int
        /// Consecutive matched words ending the alignment.
        let run: Int
        /// True when the newest spoken word was left unmatched (unstable partial word).
        let trailing: Bool
    }

    /// Local alignment of `spoken` against `script.tokens[range]`. Returns one
    /// candidate per script position where an alignment ends on the newest
    /// spoken word (or on the word before it, with a penalty).
    func align(_ spoken: [String], range: Range<Int>) -> [Candidate] {
        let m = spoken.count, n = range.count
        guard m > 0, n > 0 else { return [] }
        let tokens = script.tokens
        let threshold = configuration.similarityThreshold
        let width = n + 1

        var prevH = [Double](repeating: 0, count: width)
        var prevM = [Int](repeating: 0, count: width)
        var prevR = [Int](repeating: 0, count: width)
        var prevD = [Bool](repeating: false, count: width)
        var curH = prevH, curM = prevM, curR = prevR, curD = prevD

        // Saved row m-1 for the "trailing word unmatched" candidates.
        var penH = prevH, penM = prevM, penR = prevR, penD = prevD

        for i in 1...m {
            let word = spoken[i - 1]
            curH[0] = 0; curM[0] = 0; curR[0] = 0; curD[0] = false
            for j in 1...n {
                let token = tokens[range.lowerBound + j - 1]
                let sim = similarity(word, token.normalized)
                var best = 0.0, bestM = 0, bestR = 0, diagMatch = false
                if sim >= threshold {
                    let s = prevH[j - 1] + token.weight * sim
                    if s > best { best = s; bestM = prevM[j - 1] + 1; bestR = prevR[j - 1] + 1; diagMatch = true }
                } else {
                    let s = prevH[j - 1] - mismatchPenalty
                    if s > best { best = s; bestM = prevM[j - 1]; bestR = 0 }
                }
                let up = prevH[j] - spokenGapPenalty
                if up > best { best = up; bestM = prevM[j]; bestR = 0; diagMatch = false }
                let left = curH[j - 1] - scriptGapPenalty
                if left > best { best = left; bestM = curM[j - 1]; bestR = 0; diagMatch = false }
                curH[j] = best; curM[j] = bestM; curR[j] = bestR; curD[j] = diagMatch
            }
            if i == m - 1 { penH = curH; penM = curM; penR = curR; penD = curD }
            swap(&prevH, &curH); swap(&prevM, &curM); swap(&prevR, &curR); swap(&prevD, &curD)
        }

        // After the final swap, prev* holds row m.
        var candidates: [Candidate] = []
        candidates.reserveCapacity(n / 2)
        for j in 1...n {
            let end = range.lowerBound + j - 1
            if prevD[j] {
                candidates.append(Candidate(end: end, raw: prevH[j], matches: prevM[j], run: prevR[j], trailing: false))
            } else if m >= 2 && penD[j] {
                candidates.append(Candidate(end: end, raw: penH[j] - trailingPenalty, matches: penM[j], run: penR[j], trailing: true))
            }
        }
        return candidates
    }

    private func similarity(_ spoken: String, _ scriptWord: String) -> Double {
        if spoken == scriptWord { return 1 }
        if let cached = similarityCache[spoken]?[scriptWord] { return cached }
        let value = WordSimilarity.score(spoken, scriptWord)
        if similarityCache.count > 600 { similarityCache.removeAll(keepingCapacity: true) }
        similarityCache[spoken, default: [:]][scriptWord] = value
        return value
    }
}
