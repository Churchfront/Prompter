import Foundation
@testable import TeleprompterCore

/// Framework-free unit checks for the building blocks.
enum UnitChecks {

    static var all: [(String, () -> ScenarioReport)] {
        [
            ("Normalizer handles case, punctuation, contractions, numbers", normalizer),
            ("Tokenizer finds sentences, phrases, paragraphs and ranges", tokenizer),
            ("Tokenizer survives empty and unusual text", unusualText),
            ("Word similarity tolerates near misses only", similarity),
            ("Transcript buffer carries context across tasks", transcriptBuffer),
            ("Matcher handles empty scripts and manual resets", matcherBasics),
            ("Timed scroll is time-based and eases speed changes", timedScroll),
            ("Spring never twitches backward on small corrections", spring),
            ("Geometry maps positions and offsets both ways", geometry),
            ("Remaining time formatting", readingTime),
            ("Stage directions are shown but never spoken", cues),
            ("Notion course pages become lesson scripts", notionExtraction)
        ]
    }

    static func cues() -> ScenarioReport {
        let r = ScenarioReport("cues")
        let text = "[ON CAMERA, cold open]\n\nIf you have ever stood at the back. [TITLE CARD: Video 101] That is what we fix."
        let s = TokenizedScript(text: text)
        let ns = text as NSString
        let words = s.tokens.map { ns.substring(with: $0.range) }
        r.check(!words.contains("CAMERA") && !words.contains("TITLE") && !words.contains("Video"), "cue words were tokenized: \(words)")
        r.check(words.first == "If" && words.last == "fix", "words: \(words)")
        r.check(s.cueRanges.count == 2, "cue ranges \(s.cueRanges.count)")
        // A cue ends the sentence before it.
        let thatIndex = words.firstIndex(of: "That") ?? -1
        r.check(s.sentenceStarts.contains(thatIndex), "sentence after a cue starts fresh")
        // Matching skips straight over cues.
        let m = ScriptMatcher(script: s)
        let spoken = TextNormalizer.words(in: "if you have ever stood at the back that is what")
        r.check(m.process(spoken: spoken).newPosition == thatIndex + 2, "matcher across a cue: \(m.position)")
        return r
    }

    static func notionExtraction() -> ScenarioReport {
        let r = ScenarioReport("notion")
        func b(_ type: String, _ text: String, _ children: [NotionBlock] = []) -> NotionBlock {
            NotionBlock(id: UUID().uuidString, type: type, text: text, children: children, hasChildren: !children.isEmpty)
        }
        let blocks = [
            b("callout", "Status: Outline locked"),
            b("heading_1", "Course Summary"),
            b("paragraph", "A public Churchfront course."),
            b("heading_1", "Lesson Build"),
            b("heading_2", "1. Introduction"),
            b("paragraph", "Objective: Students know what the course covers."),
            b("toggle", "Script (draft 1, target 2:30 to 3:00)", [
                b("paragraph", "[ON CAMERA, cold open, no logo bumper yet]"),
                b("paragraph", "If you have ever stood at the back of your room on a Sunday, this course is for you."),
                b("heading_3", "Bucket One: Cameras"),
                b("callout", "Written without a specific room."),
                b("paragraph", "Cameras capture what is physically happening in your room.")
            ]),
            b("heading_2", "2. Video Sources"),
            b("toggle", "Script (draft 1, target 6:00 to 7:00)", [b("paragraph", "Every video system starts the same way.")]),
            b("heading_2", "4. The Language of Video"),
            b("paragraph", "Objective: Read a format spec.")
        ]
        let lessons = NotionScriptExtractor.lessons(pageID: "page1", blocks: blocks)
        r.check(lessons.map(\.lessonTitle) == ["1. Introduction", "2. Video Sources"], "lessons: \(lessons.map(\.lessonTitle))")
        let first = lessons.first?.body ?? ""
        r.check(first.hasPrefix("[ON CAMERA, cold open, no logo bumper yet]\n\nIf you have ever"), "body: \(first.prefix(80))")
        r.check(first.contains("[Bucket One: Cameras]"), "subheadings become cues")
        r.check(!first.contains("Written without"), "callouts are left out")
        r.check(lessons.first?.key == "notion:page1:1. Introduction", "stable key")
        r.check(NotionScriptExtractor.shortCourseName("🎥 Video 101: The Fundamentals of Video and Signal Flow — Course Build Doc") == "Video 101", "short name")
        r.check(NotionScriptExtractor.shortCourseName("AUD 203: Mixing for In-Ears — Course Build Doc") == "AUD 203", "short name 2")
        let api: [String: Any] = ["id": "abc", "type": "paragraph", "has_children": false,
                                  "paragraph": ["rich_text": [["plain_text": "Hello "], ["plain_text": "church."]]]]
        r.check(NotionBlock(apiObject: api)?.text == "Hello church.", "API block parsing")
        return r
    }

    static func normalizer() -> ScenarioReport {
        let r = ScenarioReport("normalizer")
        r.check(TextNormalizer.normalize("Don't") == "dont", "Don't")
        r.check(TextNormalizer.normalize("don\u{2019}t") == "dont", "curly apostrophe")
        r.check(TextNormalizer.normalize("Café") == "cafe", "diacritics")
        r.check(TextNormalizer.normalize("TWO") == TextNormalizer.normalize("2"), "two vs 2")
        r.check(TextNormalizer.normalize("too") == TextNormalizer.normalize("to"), "too vs to")
        r.check(TextNormalizer.normalize("three") == "3", "three")
        r.check(TextNormalizer.normalize("Their") == TextNormalizer.normalize("there"), "their/there")
        r.check(TextNormalizer.normalize("&") == "and", "ampersand")
        r.check(TextNormalizer.normalize("...") == "", "punctuation only")
        r.check(TextNormalizer.words(in: "Well-being, isn't it? Yes!") == ["well", "being", "isnt", "it", "yes"],
                "words: \(TextNormalizer.words(in: "Well-being, isn't it? Yes!"))")
        return r
    }

    static func tokenizer() -> ScenarioReport {
        let r = ScenarioReport("tokenizer")
        let text = "Hello there, friend. Dr. Smith said hi!\n\nNew paragraph: one more\u{2014}really."
        let s = TokenizedScript(text: text)
        let ns = text as NSString
        let words = s.tokens.map { ns.substring(with: $0.range) }
        r.check(words == ["Hello", "there", "friend", "Dr", "Smith", "said", "hi", "New", "paragraph", "one", "more", "really"],
                "words: \(words)")
        r.check(s.sentenceStarts == [0, 3, 7], "sentences: \(s.sentenceStarts) (Dr. is not a sentence end)")
        r.check(s.tokens[7].paragraph == 1 && s.tokens[6].paragraph == 0, "paragraphs")
        r.check(s.phraseStarts.contains(2) && s.phraseStarts.contains(9) && s.phraseStarts.contains(11),
                "phrases: \(s.phraseStarts)")
        r.check(s.sentenceRange(containing: 5) == 3..<7, "sentence range")
        r.check(s.rewindTarget(from: 9) == 3, "rewind from early in sentence goes to previous sentence")
        r.check(s.rewindTarget(from: 11) == 7, "rewind from mid sentence goes to its start")
        r.check(s.nextSentenceStart(after: 4) == 7, "next sentence")
        r.check(s.nextSentenceStart(after: 8) == nil, "no next sentence at the end")
        r.check(s.tokenIndex(atUTF16Offset: 0) == 0 && s.tokenIndex(atUTF16Offset: 7) == 1, "token at offset")
        return r
    }

    static func unusualText() -> ScenarioReport {
        let r = ScenarioReport("unusual")
        r.check(TokenizedScript(text: "").isEmpty, "empty")
        r.check(TokenizedScript(text: "   \n\n  ...  — ").isEmpty, "whitespace and punctuation")
        let emoji = TokenizedScript(text: "Praise 🙌🏽 God! Ça va? 3.5% of $10 & “quotes” (aside) — done…")
        let ns = "Praise 🙌🏽 God! Ça va? 3.5% of $10 & “quotes” (aside) — done…" as NSString
        let words = emoji.tokens.map { ns.substring(with: $0.range) }
        r.check(words == ["Praise", "God", "Ça", "va", "3", "5", "of", "10", "&", "quotes", "aside", "done"],
                "words: \(words)")
        // Matcher and geometry must accept an empty script without crashing.
        let m = ScriptMatcher(script: TokenizedScript(text: ""))
        r.check(m.process(spoken: ["hello"]) == .held(.emptyScript), "empty script matcher")
        r.check(TokenGeometry(readingY: []).offset(forPosition: 3) == 0, "empty geometry")
        // Very long script tokenizes quickly.
        let long = String(repeating: TestScripts.sample + "\n\n", count: 60)
        let start = Date()
        let big = TokenizedScript(text: long)
        let elapsed = Date().timeIntervalSince(start)
        r.check(big.count > 15_000, "long script tokens \(big.count)")
        r.check(elapsed < 2.0, "tokenizing \(big.count) words took \(elapsed) s")
        r.note("tokenized \(big.count) words in \(String(format: "%.2f", elapsed)) s")
        return r
    }

    static func similarity() -> ScenarioReport {
        let r = ScenarioReport("similarity")
        r.check(WordSimilarity.score("worship", "worship") == 1, "identical")
        r.check(WordSimilarity.score("worship", "worshp") >= 0.75, "one letter dropped")
        r.check(WordSimilarity.score("commission", "commis") >= 0.75, "truncated partial")
        r.check(WordSimilarity.score("fit", "fat") < 0.75, "short words need exact match")
        r.check(WordSimilarity.score("grace", "place") < 0.75, "different words")
        r.check(WordSimilarity.score("an", "and") == 0, "two-letter words")
        return r
    }

    static func transcriptBuffer() -> ScenarioReport {
        let r = ScenarioReport("buffer")
        var b = TranscriptBuffer()
        b.update(hypothesis: "good morning every", generation: 0, isFinal: false)
        b.update(hypothesis: "good morning everyone", generation: 0, isFinal: false)
        r.check(b.tail(10) == ["good", "morning", "everyone"], "revision replaces live words")
        b.update(hypothesis: "welcome", generation: 1, isFinal: false)
        r.check(b.tail(10) == ["good", "morning", "everyone", "welcome"], "new task keeps context: \(b.tail(10))")
        r.check(!b.update(hypothesis: "good morning everyone and", generation: 0, isFinal: true), "late results from old tasks ignored")
        b.update(hypothesis: "welcome home", generation: 1, isFinal: true)
        r.check(!b.update(hypothesis: "welcome home again", generation: 1, isFinal: false), "results after final ignored")
        r.check(b.tail(3) == ["everyone", "welcome", "home"], "tail: \(b.tail(3))")
        b.clear()
        r.check(b.tail(5).isEmpty, "clear")
        return r
    }

    static func matcherBasics() -> ScenarioReport {
        let r = ScenarioReport("matcher")
        let script = TokenizedScript(text: TestScripts.sample)
        let m = ScriptMatcher(script: script)
        r.check(m.process(spoken: ["welcome"]) == .advanced(to: 0), "first word")
        r.check(m.process(spoken: ["welcome", "this", "is", "a"]) == .advanced(to: 3), "next words")
        r.check(m.process(spoken: ["welcome", "this", "is", "a"]) == .held(.noNewWords), "same words")
        m.reset(to: 100)
        r.check(m.position == 100, "reset")
        // After a manual reset, reading from the new spot works.
        let words = script.tokens[101...104].map(\.normalized)
        r.check(m.process(spoken: words) == .advanced(to: 104), "reading after reset")
        m.reset(to: 10_000)
        r.check(m.position == script.count - 1, "reset clamps")
        return r
    }

    static func timedScroll() -> ScenarioReport {
        let r = ScenarioReport("timed")
        // Same elapsed time gives the same distance at 30, 60 and 120 frames per second.
        var distances: [Double] = []
        for fps in [30.0, 60.0, 120.0] {
            var model = TimedScrollModel()
            var offset = 0.0
            for _ in 0..<Int(fps * 10) { offset = model.step(offset: offset, targetSpeed: 50, dt: 1 / fps) }
            distances.append(offset)
        }
        r.check(distances.max()! - distances.min()! < 1.0, "distance depends on frame rate: \(distances)")
        // A stalled frame does not cause a jump.
        var model = TimedScrollModel()
        var offset = 0.0
        for _ in 0..<120 { offset = model.step(offset: offset, targetSpeed: 50, dt: 1 / 60) }
        let before = offset
        offset = model.step(offset: offset, targetSpeed: 50, dt: 2.0)
        r.check(offset - before <= 5.01, "2 s stall moved \(offset - before) pt")
        // Speed changes ease in.
        let jump = model.step(offset: offset, targetSpeed: 400, dt: 1 / 60) - offset
        r.check(jump < 3, "speed change jumped \(jump) pt in one frame")
        return r
    }

    static func spring() -> ScenarioReport {
        let r = ScenarioReport("spring")
        var s = ScrollSpring()
        for _ in 0..<120 { s.step(toward: 300, dt: 1 / 60, backwardTolerance: 72) }
        r.check(abs(s.position - 300) < 2, "settles: \(s.position)")
        let hold = s.position
        for _ in 0..<60 { s.step(toward: 260, dt: 1 / 60, backwardTolerance: 72) }
        r.check(s.position >= hold - 0.001, "small backward goal ignored")
        for _ in 0..<240 { s.step(toward: 20, dt: 1 / 60, backwardTolerance: 72) }
        r.check(abs(s.position - 20) < 1, "large backward goal followed: \(s.position)")
        return r
    }

    static func geometry() -> ScenarioReport {
        let r = ScenarioReport("geometry")
        let g = makeGeometry(tokenCount: 100, wordsPerLine: 10, lineHeight: 50)
        for p in stride(from: 0.0, through: 99.0, by: 3.7) {
            let back = g.position(forOffset: g.offset(forPosition: p))
            r.check(abs(back - p) < 0.001, "round trip \(p) -> \(back)")
        }
        r.check(g.offset(forPosition: 10) == 50, "line start")
        r.check(abs(g.pointsPerWord - 5) < 0.01, "points per word \(g.pointsPerWord)")
        return r
    }

    static func readingTime() -> ScenarioReport {
        let r = ScenarioReport("time")
        r.check(ReadingTime.format(ReadingTime.remaining(words: 300, wordsPerMinute: 150)) == "2:00", "2:00")
        r.check(ReadingTime.format(3725) == "1:02:05", "hours")
        r.check(ReadingTime.format(-3) == "0:00", "negative")
        return r
    }
}
