import Foundation
@testable import TeleprompterCore

/// Voice commands: the grammar, the wake word, and how commands are picked out
/// of a live recognizer stream (partial results that grow and get revised).
enum VoiceCommandChecks {

    static var all: [(String, () -> ScenarioReport)] {
        [
            ("Voice command grammar understands everyday phrasing", grammar),
            ("Things that are not commands are left alone", notCommands),
            ("Commands in a live transcript run once, at the right moment", streaming),
            ("Script words around commands are kept apart for matching", scriptWords),
            ("Paragraph and sentence jumps land on the right word", jumps)
        ]
    }

    static func parse(_ phrase: String) -> CommandParse {
        VoiceCommandParser.parse(TextNormalizer.words(in: phrase))
    }

    static func command(_ phrase: String) -> VoiceCommand? {
        if case .command(let c, _, _) = parse(phrase) { return c }
        return nil
    }

    static func grammar() -> ScenarioReport {
        let r = ScenarioReport("grammar")
        let cases: [(String, VoiceCommand)] = [
            ("go back one paragraph", .back(.paragraph, 1)),
            ("go back two paragraphs", .back(.paragraph, 2)),
            ("back 3 sentences", .back(.sentence, 3)),
            ("back a sentence", .back(.sentence, 1)),
            ("previous paragraph", .back(.paragraph, 1)),
            ("go back", .back(.sentence, 1)),
            ("rewind", .back(.sentence, 1)),
            ("next paragraph", .forward(.paragraph, 1)),
            ("skip ahead four sentences", .forward(.sentence, 4)),
            ("skip a paragraph", .forward(.paragraph, 1)),
            ("go forward", .forward(.sentence, 1)),
            ("start over", .restart),
            ("go to the top", .restart),
            ("back to the beginning", .restart),
            ("from the top", .restart),
            ("restart", .restart),
            ("pause", .pause),
            ("stop", .pause),
            ("hold on", .pause),
            ("play", .play),
            ("resume", .play),
            ("go", .play),
            ("speed up 5 words per minute", .speedBy(5)),
            ("speed up five words per minute", .speedBy(5)),
            ("speed up by 20", .speedBy(20)),
            ("speed up", .speedBy(10)),
            ("faster", .speedBy(10)),
            ("slow down 15 wpm", .speedBy(-15)),
            ("slower", .speedBy(-10)),
            ("set speed to 150", .speedTo(150)),
            ("set the speed to one hundred fifty", .speedTo(150)),
            ("speed 180", .speedTo(180)),
            ("speed up to 160 words per minute", .speedTo(160)),
            ("bigger", .textBigger),
            ("make the text bigger", .textBigger),
            ("smaller text", .textSmaller),
            ("zoom out", .textSmaller),
            ("mirror", .mirror(nil)),
            ("mirror on", .mirror(true)),
            ("mirror off", .mirror(false)),
            ("switch to timed", .timedMode),
            ("timed mode", .timedMode),
            ("voice follow", .voiceFollowMode),
            ("please go back one paragraph", .back(.paragraph, 1))
        ]
        for (phrase, expected) in cases {
            let got = command(phrase)
            r.check(got == expected, "\"\(phrase)\" gave \(got.map { "\($0)" } ?? "nothing"), expected \(expected)")
        }
        r.check(VoiceCommand.back(.paragraph, 1).summary == "Back 1 paragraph", "summary wording")
        r.check(VoiceCommand.speedBy(-5).summary == "Slower by 5 WPM", "speed summary wording")
        return r
    }

    static func notCommands() -> ScenarioReport {
        let r = ScenarioReport("not commands")
        for phrase in ["is ready for you", "on the stand", "big", "we love our volunteers"] {
            r.check(parse(phrase) == .none, "\"\(phrase)\" should not be a command: \(parse(phrase))")
        }
        // A script that talks about the teleprompter, and one that never says the wake word.
        var spotter = VoiceCommandSpotter()
        let script = "our teleprompter is ready and we can go back to the lobby after service"
        var heard: [VoiceCommand] = []
        let words = TextNormalizer.words(in: script)
        for n in 1...words.count {
            heard += spotter.process(words: Array(words.prefix(n)), generation: 1, isFinal: n == words.count, now: Double(n) * 0.3).commands
        }
        r.check(heard.isEmpty, "script speech triggered \(heard)")
        var plain = VoiceCommandSpotter()
        let sermon = TextNormalizer.words(in: "go back to the start of the story and pause there for a moment")
        let result = plain.process(words: sermon, generation: 1, isFinal: true, now: 1)
        r.check(result.commands.isEmpty, "commands without the wake word: \(result.commands)")
        return r
    }

    /// Feeds a phrase the way the recognizer does: one more word per partial result.
    static func speak(_ text: String, into spotter: inout VoiceCommandSpotter, generation: Int = 1,
                      start: Double = 0, step: Double = 0.25, final: Bool = false) -> [(Double, VoiceCommand)] {
        let words = TextNormalizer.words(in: text)
        var out: [(Double, VoiceCommand)] = []
        for n in 1...words.count {
            let t = start + Double(n) * step
            let result = spotter.process(words: Array(words.prefix(n)), generation: generation,
                                         isFinal: final && n == words.count, now: t)
            out += result.commands.map { (t, $0) }
        }
        return out
    }

    static func streaming() -> ScenarioReport {
        let r = ScenarioReport("streaming")

        // "go" must not fire as Play before "back one paragraph" arrives.
        var s = VoiceCommandSpotter()
        var heard = speak("and so teleprompter go back one paragraph", into: &s)
        heard += s.flush(now: 10).map { (10, $0) }
        r.check(heard.map(\.1) == [.back(.paragraph, 1)], "go back one paragraph: \(heard.map(\.1))")

        // "two" arrives as "to": "back to" waits for "paragraphs" instead of firing early.
        s = VoiceCommandSpotter()
        heard = speak("teleprompter go back two paragraphs", into: &s)
        heard += s.flush(now: 10).map { (10, $0) }
        r.check(heard.map(\.1) == [.back(.paragraph, 2)], "go back two paragraphs: \(heard.map(\.1))")

        // A complete command fires on the partial result that completes it.
        s = VoiceCommandSpotter()
        heard = speak("teleprompter pause", into: &s, step: 0.25)
        r.check(heard.count == 1 && heard[0].1 == .pause && heard[0].0 == 0.5, "pause fired at \(heard.map(\.0))")

        // A lone "go" settles into Play after the settle interval.
        s = VoiceCommandSpotter()
        heard = speak("teleprompter go", into: &s)
        r.check(heard.isEmpty, "go fired before settling")
        r.check(s.flush(now: 0.6).isEmpty, "go fired too soon")
        r.check(s.flush(now: 1.3) == [.play], "go never settled into play")
        r.check(s.flush(now: 2.0).isEmpty, "play fired twice")

        // Speaking on after a command runs it right away, and only once as the transcript grows.
        s = VoiceCommandSpotter()
        heard = speak("teleprompter speed up 5 words per minute okay so as I was saying the church", into: &s)
        heard += s.flush(now: 20).map { (20, $0) }
        r.check(heard.map(\.1) == [.speedBy(5)], "speed up once: \(heard.map(\.1))")

        // Two commands in one breath.
        s = VoiceCommandSpotter()
        heard = speak("teleprompter pause teleprompter mirror on", into: &s)
        r.check(heard.map(\.1) == [.pause, .mirror(true)], "two commands: \(heard.map(\.1))")

        // A recognition task that ends mid-command still runs what it heard.
        s = VoiceCommandSpotter()
        heard = speak("teleprompter skip ahead", into: &s)
        let next = s.process(words: ["welcome"], generation: 2, isFinal: false, now: 2)
        r.check(heard.isEmpty && next.commands == [.forward(.sentence, 1)], "task rotation: \(heard.map(\.1)) then \(next.commands)")

        // The recognizer's split spelling of the wake word.
        s = VoiceCommandSpotter()
        heard = speak("tele prompter next paragraph", into: &s)
        r.check(heard.map(\.1) == [.forward(.paragraph, 1)], "tele prompter: \(heard.map(\.1))")

        // Resetting mid-phrase (commands turned off) never replays a command as the transcript grows.
        s = VoiceCommandSpotter()
        heard = speak("teleprompter speed up 5 words", into: &s)
        s.reset()
        let grown = s.process(words: TextNormalizer.words(in: "teleprompter speed up 5 words per minute"), generation: 1, isFinal: true, now: 5)
        r.check(heard.map(\.1) == [.speedBy(5)] && grown.commands.isEmpty, "replayed after reset: \(heard.map(\.1)) then \(grown.commands)")
        s.reset()
        let pendingDropped = s.process(words: TextNormalizer.words(in: "teleprompter speed up 5 words per minute teleprompter go"), generation: 1, isFinal: false, now: 6)
        r.check(pendingDropped.isPending && pendingDropped.commands.isEmpty, "new command after reset still waits: \(pendingDropped.commands)")

        // Final results resolve immediately.
        s = VoiceCommandSpotter()
        heard = speak("teleprompter faster", into: &s, final: true)
        r.check(heard.map(\.1) == [.speedBy(10)], "final: \(heard.map(\.1))")
        return r
    }

    static func scriptWords() -> ScenarioReport {
        let r = ScenarioReport("script words")
        var s = VoiceCommandSpotter()
        var result = s.process(words: TextNormalizer.words(in: "we are so glad teleprompter go back"), generation: 1, isFinal: false, now: 0)
        r.check(result.isPending && result.scriptWords == ["we", "are", "so", "glad"], "pending command hidden: \(result.scriptWords)")
        result = s.process(words: TextNormalizer.words(in: "we are so glad teleprompter go back a paragraph we are so"), generation: 1, isFinal: false, now: 0.3)
        r.check(result.commands == [.back(.paragraph, 1)], "command ran: \(result.commands)")
        r.check(result.scriptWords == ["we", "are", "so"], "only words after the command remain: \(result.scriptWords)")
        result = s.process(words: TextNormalizer.words(in: "we are so glad teleprompter go back a paragraph we are so glad you"), generation: 1, isFinal: false, now: 0.6)
        r.check(result.commands.isEmpty && result.scriptWords == ["we", "are", "so", "glad", "you"], "no repeat: \(result.commands) \(result.scriptWords)")
        // Not a command: the wake word stays in the script words.
        var t = VoiceCommandSpotter()
        let plain = t.process(words: TextNormalizer.words(in: "the teleprompter is ready"), generation: 1, isFinal: false, now: 0)
        r.check(plain.scriptWords == ["the", "teleprompter", "is", "ready"] && !plain.isPending, "script mention kept: \(plain.scriptWords)")
        return r
    }

    static func jumps() -> ScenarioReport {
        let r = ScenarioReport("jumps")
        let text = "One two three. Four five six.\nSeven eight nine. Ten eleven twelve.\nThirteen fourteen fifteen."
        let s = TokenizedScript(text: text)
        r.check(s.paragraphStarts == [0, 6, 12], "paragraph starts \(s.paragraphStarts)")
        // In the middle of paragraph two ("Ten", token 9): back one paragraph is its own start.
        r.check(s.backTarget(from: 10, unit: .paragraph, count: 1) == 6, "back 1 paragraph from inside: \(s.backTarget(from: 10, unit: .paragraph, count: 1))")
        r.check(s.backTarget(from: 10, unit: .paragraph, count: 2) == 0, "back 2 paragraphs")
        // At the very start of a paragraph, back one goes to the previous paragraph.
        r.check(s.backTarget(from: 6, unit: .paragraph, count: 1) == 0, "back 1 from a paragraph start")
        r.check(s.backTarget(from: 13, unit: .paragraph, count: 5) == 0, "back past the top stops at the top")
        r.check(s.forwardTarget(from: 1, unit: .paragraph, count: 1) == 6, "ahead 1 paragraph")
        r.check(s.forwardTarget(from: 1, unit: .paragraph, count: 9) == 12, "ahead past the end stops at the last paragraph")
        r.check(s.forwardTarget(from: 13, unit: .paragraph, count: 1) == nil, "ahead from the last paragraph does nothing")
        // Like the back button: on the first two words of a sentence, back goes to the previous one.
        r.check(s.backTarget(from: 10, unit: .sentence, count: 1) == 6, "back 1 sentence near its start")
        r.check(s.backTarget(from: 2, unit: .sentence, count: 1) == 0, "back 1 sentence")
        r.check(s.forwardTarget(from: 1, unit: .sentence, count: 2) == 6, "ahead 2 sentences")
        return r
    }
}
