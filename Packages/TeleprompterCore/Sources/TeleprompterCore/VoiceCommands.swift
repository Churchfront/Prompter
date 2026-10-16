import Foundation

/// How far a spoken jump moves.
public enum JumpUnit: String, Sendable {
    case sentence
    case paragraph
}

/// A spoken instruction to the prompter, said after the wake word "Teleprompter".
public enum VoiceCommand: Equatable, Sendable {
    case play
    case pause
    case restart
    case back(JumpUnit, Int)
    case forward(JumpUnit, Int)
    /// Change the timed scroll speed by this many words per minute.
    case speedBy(Double)
    /// Set the timed scroll speed in words per minute.
    case speedTo(Double)
    case textBigger
    case textSmaller
    /// Mirror on, off, or toggle (nil).
    case mirror(Bool?)
    case timedMode
    case voiceFollowMode

    /// Short confirmation shown to the reader, for example "Back 1 paragraph".
    public var summary: String {
        func amount(_ n: Int, _ unit: JumpUnit) -> String { "\(n) \(unit.rawValue)\(n == 1 ? "" : "s")" }
        func wpm(_ v: Double) -> String { "\(Int(abs(v).rounded())) WPM" }
        switch self {
        case .play: return "Play"
        case .pause: return "Pause"
        case .restart: return "Start over"
        case .back(let unit, let n): return "Back \(amount(n, unit))"
        case .forward(let unit, let n): return "Ahead \(amount(n, unit))"
        case .speedBy(let d): return d >= 0 ? "Faster by \(wpm(d))" : "Slower by \(wpm(d))"
        case .speedTo(let v): return "Speed \(wpm(v))"
        case .textBigger: return "Larger text"
        case .textSmaller: return "Smaller text"
        case .mirror(let on): return on == nil ? "Mirror" : on! ? "Mirror on" : "Mirror off"
        case .timedMode: return "Timed Scroll"
        case .voiceFollowMode: return "Voice Follow"
        }
    }
}

/// What the words after the wake word amount to so far.
public enum CommandParse: Equatable, Sendable {
    /// Not a command (for example the script itself says "teleprompter").
    case none
    /// Could still become a command as more words arrive.
    case prefix
    /// A command, the number of words it used, and whether more words could still change it
    /// ("go" might become "go back", "back" might become "back two paragraphs").
    case command(VoiceCommand, length: Int, extendable: Bool)
}

/// The spoken command grammar. Works on normalized words (see `TextNormalizer`),
/// so "two" arrives as "to", "four" as "for", and "five" as "5".
public enum VoiceCommandParser {

    public static func parse(_ words: [String]) -> CommandParse {
        var start = 0
        while start < words.count, fillers.contains(words[start]) { start += 1 }
        if start >= words.count { return .prefix }
        let rules: [(Cursor) -> CommandParse] = [restart, back, forward, speed, text, mirror, mode, pause, play]
        var best: (VoiceCommand, Int, Bool)?
        var sawPrefix = false
        for rule in rules {
            switch rule(Cursor(words: words, index: start)) {
            case .command(let c, let length, let ext):
                if best == nil || length > best!.1 { best = (c, length, ext) }
            case .prefix:
                sawPrefix = true
            case .none:
                break
            }
        }
        if let best {
            // Another reading that needs more words keeps a short command open ("start" vs "start over").
            return .command(best.0, length: best.1, extendable: best.2 || (sawPrefix && start + best.1 >= words.count))
        }
        return sawPrefix ? .prefix : .none
    }

    // MARK: Vocabulary

    static let fillers: Set<String> = ["please", "now", "can", "could", "would", "you", "lets", "let", "us",
                                       "okay", "hey", "uh", "um", "and", "just", "so"]
    static let sentenceWords: Set<String> = ["sentence", "sentences", "line", "lines"]
    static let paragraphWords: Set<String> = ["paragraph", "paragraphs", "para", "section", "sections"]
    static let topWords: Set<String> = ["top", "beginning", "start"]
    static let rateWords: Set<String> = ["words", "word", "wpm", "per", "minute", "a"]

    struct Cursor {
        let words: [String]
        var index: Int
        var atEnd: Bool { index >= words.count }
        func peek(_ k: Int = 0) -> String? { index + k < words.count ? words[index + k] : nil }
        mutating func accept(_ set: Set<String>) -> String? {
            guard let w = peek(), set.contains(w) else { return nil }
            index += 1
            return w
        }
        func length(from start: Int) -> Int { index - start }
    }

    /// A required word: the matched word, nil at the end of input (prefix), or a mismatch.
    enum Need { case matched(String), end, mismatch }
    static func need(_ c: inout Cursor, _ set: Set<String>) -> Need {
        if c.atEnd { return .end }
        if let w = c.accept(set) { return .matched(w) }
        return .mismatch
    }

    static func unit(_ c: inout Cursor) -> JumpUnit? {
        if c.accept(sentenceWords) != nil { return .sentence }
        if c.accept(paragraphWords) != nil { return .paragraph }
        return nil
    }

    static func isUnit(_ w: String?) -> Bool {
        guard let w else { return false }
        return sentenceWords.contains(w) || paragraphWords.contains(w)
    }

    /// A count or amount: digits ("150", or "1" "100" "50"), "a" or "an" before a unit, and
    /// "to" and "for" (two and four after normalizing) when a unit or rate word follows.
    static func number(_ c: inout Cursor) -> Int? {
        guard let w = c.peek() else { return nil }
        let next = c.peek(1)
        if (w == "a" || w == "an") && isUnit(next) { c.index += 1; return 1 }
        if (w == "to" || w == "for") && (isUnit(next) || next.map(rateWords.contains) == true) {
            c.index += 1
            return w == "to" ? 2 : 4
        }
        var total = 0, current = 0, found = false
        while let t = c.peek(), let v = Int(t) {
            if v == 100 { current = max(current, 1) * 100 }
            else if v == 1000 { total += max(current, 1) * 1000; current = 0 }
            else if current % 100 == 0 || v < 10 { current += v }
            else { break }
            found = true
            c.index += 1
        }
        return found ? total + current : nil
    }

    // MARK: Rules

    static func restart(_ start: Cursor) -> CommandParse {
        var c = start
        if c.accept(["restart"]) != nil { return .command(.restart, length: 1, extendable: false) }
        // "start over", "start again", "start from the top"
        if c.accept(["start", "begin"]) != nil {
            if c.accept(["over", "again"]) != nil { return .command(.restart, length: c.length(from: start.index), extendable: false) }
            if c.accept(["from"]) != nil {
                _ = c.accept(["the"])
                switch need(&c, topWords) {
                case .matched: return .command(.restart, length: c.length(from: start.index), extendable: false)
                case .end: return .prefix
                case .mismatch: return .none
                }
            }
            return c.atEnd ? .prefix : .none
        }
        // "from the top", "go to the top", "back to the beginning", "top"
        if c.accept(["from"]) != nil || c.accept(["go", "back", "jump", "skip"]) != nil {
            if start.peek() != "from" {
                switch need(&c, ["to"]) {
                case .matched: break
                case .end: return .prefix
                case .mismatch: return .none
                }
            }
            _ = c.accept(["the"])
            switch need(&c, topWords) {
            case .matched: return .command(.restart, length: c.length(from: start.index), extendable: false)
            case .end: return .prefix
            case .mismatch: return .none
            }
        }
        if c.accept(["top", "beginning"]) != nil { return .command(.restart, length: 1, extendable: false) }
        return .none
    }

    static func back(_ start: Cursor) -> CommandParse {
        var c = start
        let movedVerb = c.accept(["go", "jump", "move"]) != nil
        guard c.accept(["back", "backward", "backwards", "previous", "rewind", "last", "backup"]) != nil else {
            return movedVerb && c.atEnd ? .prefix : .none
        }
        _ = c.accept(["up"])
        // "back to the top" is a restart, not "back two".
        if c.peek() == "to", c.peek(1).map({ topWords.contains($0) || $0 == "the" }) == true { return .none }
        let count = number(&c)
        _ = c.accept(["more", "whole"])
        let u = unit(&c)
        return .command(.back(u ?? .sentence, max(count ?? 1, 1)), length: c.length(from: start.index), extendable: u == nil)
    }

    static func forward(_ start: Cursor) -> CommandParse {
        var c = start
        let verb = c.accept(["go", "jump", "move", "skip"])
        let direction = c.accept(["forward", "forwards", "ahead", "next", "down", "onward", "on"])
        if direction == nil && verb != "skip" {
            return verb != nil && c.atEnd ? .prefix : .none
        }
        if direction == "on" && verb == nil { return .none }
        let count = number(&c)
        _ = c.accept(["more", "whole"])
        let u = unit(&c)
        return .command(.forward(u ?? .sentence, max(count ?? 1, 1)), length: c.length(from: start.index), extendable: u == nil)
    }

    static func speed(_ start: Cursor) -> CommandParse {
        var c = start
        var sign: Double?
        var absolute = false
        if c.accept(["faster", "quicker", "speedup"]) != nil {
            sign = 1
        } else if c.accept(["slower", "slowdown"]) != nil {
            sign = -1
        } else if c.accept(["slow"]) != nil {
            switch need(&c, ["down"]) {
            case .matched: sign = -1
            case .end: return .prefix
            case .mismatch: return .none
            }
        } else {
            let setVerb = c.accept(["set", "change", "make"]) != nil
            if setVerb { _ = c.accept(["the"]) }
            switch need(&c, ["speed", "pace", "scroll"]) {
            case .matched: break
            case .end: return setVerb ? .prefix : .none
            case .mismatch: return .none
            }
            if c.accept(["up"]) != nil { sign = 1 }
            else if c.accept(["down"]) != nil { sign = -1 }
            else { absolute = true }
        }
        _ = c.accept(["it", "the", "speed"])
        if c.accept(["to"]) != nil {
            // "speed up to 150", "set speed to 150": an absolute speed.
            var probe = c
            if let n = number(&probe), n >= 40 {
                c = probe
                while c.accept(rateWords) != nil {}
                return .command(.speedTo(Double(n)), length: c.length(from: start.index), extendable: false)
            }
            if absolute { return c.atEnd ? .prefix : .none }
            // "speed up to" alone: "two"?
            c.index -= 1
        }
        if c.accept(["by"]) != nil, c.atEnd { return .prefix }
        let n = number(&c)
        var sawRate = false
        while c.accept(rateWords) != nil { sawRate = true }
        if absolute {
            guard let n else { return c.atEnd ? .prefix : .none }
            return n >= 40 ? .command(.speedTo(Double(n)), length: c.length(from: start.index), extendable: !sawRate)
                           : .command(.speedBy(Double(n)), length: c.length(from: start.index), extendable: !sawRate)
        }
        let delta = Double(min(max(n ?? 10, 1), 200)) * (sign ?? 1)
        return .command(.speedBy(delta), length: c.length(from: start.index), extendable: n == nil || !sawRate)
    }

    static func text(_ start: Cursor) -> CommandParse {
        var c = start
        var lead = 0
        while c.accept(["make", "the", "text", "font", "type", "letters", "words", "it"]) != nil { lead += 1 }
        var command: VoiceCommand?
        if c.accept(["bigger", "larger", "biggest", "big", "large"]) != nil { command = .textBigger }
        else if c.accept(["smaller", "smallest", "small", "tiny"]) != nil { command = .textSmaller }
        else if c.accept(["zoom"]) != nil {
            if c.accept(["in"]) != nil { command = .textBigger }
            else if c.accept(["out"]) != nil { command = .textSmaller }
            else { return c.atEnd ? .prefix : .none }
        }
        guard let command else { return lead > 0 && c.atEnd ? .prefix : .none }
        // "big" and "small" need a lead-in ("make it big") so "big" alone in a script never counts.
        if lead == 0, let w = c.words[safe: c.index - 1], ["big", "large", "small", "tiny"].contains(w) { return .none }
        _ = c.accept(["text", "font", "please"])
        return .command(command, length: c.length(from: start.index), extendable: false)
    }

    static func mirror(_ start: Cursor) -> CommandParse {
        var c = start
        if c.accept(["unmirror"]) != nil { return .command(.mirror(false), length: 1, extendable: false) }
        _ = c.accept(["turn", "switch"])
        guard c.accept(["mirror", "mirrored", "mirroring"]) != nil else { return .none }
        _ = c.accept(["mode", "the", "text", "screen"])
        if c.accept(["on"]) != nil { return .command(.mirror(true), length: c.length(from: start.index), extendable: false) }
        if c.accept(["off"]) != nil { return .command(.mirror(false), length: c.length(from: start.index), extendable: false) }
        return .command(.mirror(nil), length: c.length(from: start.index), extendable: true)
    }

    static func mode(_ start: Cursor) -> CommandParse {
        var c = start
        let verb = c.accept(["switch", "change", "use", "go"]) != nil
        if verb { _ = c.accept(["to"]) }
        if c.accept(["timed", "timer", "time"]) != nil {
            _ = c.accept(["mode", "scroll", "scrolling"])
            return .command(.timedMode, length: c.length(from: start.index), extendable: false)
        }
        if c.accept(["voice"]) != nil {
            _ = c.accept(["follow", "mode"])
            _ = c.accept(["mode"])
            return .command(.voiceFollowMode, length: c.length(from: start.index), extendable: false)
        }
        if c.accept(["follow"]) != nil {
            _ = c.accept(["me", "mode"])
            return .command(.voiceFollowMode, length: c.length(from: start.index), extendable: false)
        }
        return verb && c.atEnd ? .prefix : .none
    }

    static func pause(_ start: Cursor) -> CommandParse {
        var c = start
        guard c.accept(["pause", "stop", "hold", "wait", "freeze", "halt"]) != nil else { return .none }
        _ = c.accept(["on", "it", "there", "please"])
        return .command(.pause, length: c.length(from: start.index), extendable: false)
    }

    static func play(_ start: Cursor) -> CommandParse {
        var c = start
        guard let w = c.accept(["play", "resume", "continue", "start", "go", "roll", "begin", "unpause"]) else { return .none }
        _ = c.accept(["again", "please", "it"])
        // "go" and "start" usually begin a longer command; wait a moment before acting on them alone.
        return .command(.play, length: c.length(from: start.index), extendable: w == "go" || w == "start" || w == "begin")
    }
}

/// Finds "Teleprompter, <command>" in a stream of recognizer transcripts.
///
/// Feed it every transcript of the current recognition task. A command runs once,
/// as soon as it is unambiguous: right away for complete commands ("pause"), and
/// for commands that could still grow ("go" before "go back") once two more words
/// follow it, the task ends, or the transcript has been still for `settleInterval`.
/// "Teleprompter" followed by something that is not a command (the script talking
/// about a teleprompter) is ignored and left in the text for script matching.
public struct VoiceCommandSpotter: Sendable {
    public struct Result: Sendable {
        public var commands: [VoiceCommand]
        /// The transcript without commands and without anything said before the last command,
        /// for script matching: a command often moves the script, so earlier words are stale.
        public var scriptWords: [String]
        /// A possible command is waiting for more words or for the settle interval.
        public var isPending: Bool
    }

    enum Resolution: Equatable { case executed(end: Int), ignored }

    public var settleInterval: Double

    private var generation = -1
    private var words: [String] = []
    private var resolutions: [Int: Resolution] = [:]
    private var cutoff = 0
    private var pendingStart: Int?
    private var changedAt: Double = 0

    public init(settleInterval: Double = 0.7) {
        self.settleInterval = settleInterval
    }

    /// Feeds the full transcript of recognition task `generation` (normalized words).
    public mutating func process(words newWords: [String], generation newGeneration: Int, isFinal: Bool, now: Double) -> Result {
        var commands: [VoiceCommand] = []
        if newGeneration < generation { return Result(commands: [], scriptWords: [], isPending: pendingStart != nil) }
        if newGeneration != generation {
            // The previous task ended: whatever it was still waiting on is as complete as it gets.
            commands += evaluate(final: true, now: now)
            generation = newGeneration
            words = []
            resolutions = [:]
            cutoff = 0
            pendingStart = nil
        }
        if newWords != words {
            words = newWords
            changedAt = now
        }
        commands += evaluate(final: isFinal, now: now)
        return Result(commands: commands, scriptWords: scriptWords, isPending: pendingStart != nil)
    }

    /// Call after `settleInterval` while a command is pending.
    public mutating func flush(now: Double) -> [VoiceCommand] {
        evaluate(final: false, now: now)
    }

    /// Drops anything pending and ignores everything already heard in the current
    /// recognition task, so turning commands off and on never replays an old command.
    public mutating func reset() {
        pendingStart = nil
        var ordinal = 0
        var i = 0
        while i < words.count {
            if let wake = Self.wakeLength(words, at: i) {
                if resolutions[ordinal] == nil { resolutions[ordinal] = .ignored }
                ordinal += 1
                i += wake
            } else {
                i += 1
            }
        }
        cutoff = max(cutoff, words.count)
    }

    private var scriptWords: [String] {
        let end = pendingStart ?? words.count
        guard cutoff < end else { return [] }
        return Array(words[cutoff..<end])
    }

    private mutating func evaluate(final: Bool, now: Double) -> [VoiceCommand] {
        pendingStart = nil
        var out: [VoiceCommand] = []
        let settled = final || now - changedAt >= settleInterval
        var ordinal = 0
        var i = 0
        while i < words.count {
            guard let wake = Self.wakeLength(words, at: i) else {
                i += 1
                continue
            }
            defer { ordinal += 1 }
            switch resolutions[ordinal] {
            case .executed(let end):
                i = max(end, i + wake)
                continue
            case .ignored:
                i += wake
                continue
            case nil:
                break
            }
            let restStart = i + wake
            switch VoiceCommandParser.parse(Array(words[restStart...])) {
            case .none:
                resolutions[ordinal] = .ignored
                i = restStart
            case .prefix:
                if settled {
                    resolutions[ordinal] = .ignored
                    i = restStart
                } else {
                    pendingStart = i
                    i = words.count
                }
            case .command(let command, let length, let extendable):
                let end = restStart + length
                // Two words past the command mean the reader moved on. One could still be
                // part of it: "back to" before "paragraphs" ("two" arrives as "to").
                if !extendable || words.count - end >= 2 || settled {
                    out.append(command)
                    resolutions[ordinal] = .executed(end: end)
                    cutoff = end
                    i = end
                } else {
                    pendingStart = i
                    i = words.count
                }
            }
        }
        return out
    }

    /// Length of the wake word at `i` (1 or 2 words), or nil. Covers the recognizer's
    /// usual spellings: "teleprompter", "tele prompter", "teleprompters", "telly prompter".
    static func wakeLength(_ words: [String], at i: Int) -> Int? {
        let w = words[i]
        if w == "teleprompter" || w == "teleprompters" { return 1 }
        if w.count >= 10, w.hasPrefix("tele"), WordSimilarity.score(w, "teleprompter") >= 0.8 { return 1 }
        if ["tele", "telly", "tell", "teller"].contains(w), i + 1 < words.count,
           ["prompter", "prompters", "promoter", "promter", "a"].contains(words[i + 1]) {
            if words[i + 1] == "a" {
                return i + 2 < words.count && words[i + 2] == "prompter" ? 3 : nil
            }
            return 2
        }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
