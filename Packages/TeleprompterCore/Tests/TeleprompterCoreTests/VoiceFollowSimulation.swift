import Foundation
@testable import TeleprompterCore

// Framework-free scenario code shared by the XCTest suite and by
// Tools/run-core-tests.sh (which runs without Xcode).
//
// The simulation reproduces how Apple's speech recognizer reports results:
// each update carries the whole transcript of the current recognition task,
// words arrive after a latency, the newest word first appears truncated and is
// then revised, tasks end after silence or time limits and a fresh task starts
// with an empty transcript. Everything downstream is the production pipeline:
// TranscriptBuffer -> ScriptMatcher -> ReadingPacer -> ScrollSpring.

struct SpokenWord {
    let text: String
    let time: Double
    /// Index of the script token this word reads, or nil for an ad-lib or garbled word.
    let scriptIndex: Int?
}

struct SimulationSample {
    let time: Double
    let truth: Int          // last script token actually spoken (-1 before any)
    let matched: Int        // matcher position
    let scroll: Double      // spring position in points
    let goalTokens: Double  // pacer goal
}

struct SimulationResult {
    var samples: [SimulationSample] = []
    var maxUpdateMilliseconds: Double = 0
    var updates = 0
    var finalPosition = -1
    var outcomes: [MatchOutcome] = []

    func samples(from t0: Double, to t1: Double) -> [SimulationSample] {
        samples.filter { $0.time >= t0 && $0.time <= t1 }
    }
}

/// Deterministic pseudo-random numbers so scenarios are reproducible.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFFF) / Double(0xFFFFFF)
    }
}

struct SpeechPlan {
    private(set) var words: [SpokenWord] = []
    private(set) var time: Double = 0
    let scriptWords: [String]

    init(script: String, startTime: Double = 0) {
        scriptWords = WordScanner.scan(script)
            .map(\.text)
            .filter { !TextNormalizer.normalize($0).isEmpty }
        time = startTime
    }

    /// Reads script tokens `range` at `wordsPerSecond`, with optional errors.
    mutating func read(_ range: Range<Int>, wordsPerSecond: Double,
                       substitutionRate: Double = 0, dropRate: Double = 0, insertionRate: Double = 0,
                       random: inout SeededRandom) {
        let step = 1 / wordsPerSecond
        for index in range {
            time += step * (0.8 + 0.4 * random.next())
            let r = random.next()
            if r < dropRate {
                continue // recognizer missed the word entirely
            } else if r < dropRate + substitutionRate {
                words.append(SpokenWord(text: garble(scriptWords[index], &random), time: time, scriptIndex: index))
            } else {
                words.append(SpokenWord(text: scriptWords[index], time: time, scriptIndex: index))
            }
            if random.next() < insertionRate {
                time += step
                let fillers = ["like", "you know", "so", "right", "amen"]
                let filler = fillers[Int(random.next() * Double(fillers.count)) % fillers.count]
                words.append(SpokenWord(text: filler, time: time, scriptIndex: nil))
            }
        }
    }

    /// Says words that are not in the script.
    mutating func adLib(_ text: String, wordsPerSecond: Double) {
        for w in text.split(separator: " ") {
            time += 1 / wordsPerSecond
            words.append(SpokenWord(text: String(w), time: time, scriptIndex: nil))
        }
    }

    mutating func pause(_ seconds: Double) { time += seconds }

    private func garble(_ word: String, _ random: inout SeededRandom) -> String {
        let swaps = ["great": "grate", "their": "there", "know": "no", "for": "four",
                     "to": "two", "you": "ewe", "here": "hear", "right": "write"]
        if let s = swaps[word.lowercased()] { return s }
        var chars = Array(word.lowercased())
        guard chars.count > 3 else { return word + "s" }
        // Change one interior letter: the kind of near-miss recognizers make.
        let i = 1 + Int(random.next() * Double(chars.count - 2))
        chars[i] = chars[i] == "e" ? "a" : "e"
        return String(chars)
    }
}

struct SimulationOptions {
    var latency = 0.35
    var taskRotationInterval = 55.0
    var silenceFinalizes = 1.8
    var frameRate = 60.0
    var pauseGrace = 1.2
    var lineHeight = 60.0
    var wordsPerLine = 8
    var matcher = MatcherConfiguration()
    /// Optional layout change during the run: (time, new words per line).
    var relayoutAt: (time: Double, wordsPerLine: Int)? = nil
}

func makeGeometry(tokenCount: Int, wordsPerLine: Int, lineHeight: Double) -> TokenGeometry {
    TokenGeometry(readingY: (0..<tokenCount).map { i in
        let line = i / wordsPerLine
        let column = i % wordsPerLine
        return Double(line) * lineHeight + Double(column) / Double(wordsPerLine) * lineHeight
    })
}

/// Runs the production pipeline against a speech plan.
func simulate(script text: String, plan: SpeechPlan, options: SimulationOptions = .init(),
              duration: Double? = nil) -> SimulationResult {
    let script = TokenizedScript(text: text)
    let matcher = ScriptMatcher(script: script, configuration: options.matcher)
    var buffer = TranscriptBuffer()
    var pacer = ReadingPacer(graceInterval: options.pauseGrace)
    var spring = ScrollSpring()
    var geometry = makeGeometry(tokenCount: script.count, wordsPerLine: options.wordsPerLine,
                                lineHeight: options.lineHeight)
    var result = SimulationResult()

    // Build recognizer events: (time, generation, hypothesis, isFinal).
    struct Event { let time: Double; let generation: Int; let text: String; let isFinal: Bool }
    var events: [Event] = []
    var generation = 0
    var taskStart = 0.0
    var taskWords: [String] = []
    var lastWordTime = -10.0
    for word in plan.words {
        let arrival = word.time + options.latency
        // Silence long enough finalizes the task; time limits rotate it.
        if (!taskWords.isEmpty && word.time - lastWordTime > options.silenceFinalizes)
            || arrival - taskStart > options.taskRotationInterval {
            if !taskWords.isEmpty {
                events.append(Event(time: lastWordTime + options.latency + 0.6, generation: generation,
                                    text: taskWords.joined(separator: " "), isFinal: true))
            }
            generation += 1
            taskStart = arrival
            taskWords = []
        }
        // Newest word first arrives truncated, then is revised.
        let w = word.text
        if w.count >= 6 {
            let partial = String(w.prefix(Int(Double(w.count) * 0.6)))
            events.append(Event(time: arrival, generation: generation,
                                text: (taskWords + [partial]).joined(separator: " "), isFinal: false))
            taskWords.append(w)
            events.append(Event(time: arrival + 0.12, generation: generation,
                                text: taskWords.joined(separator: " "), isFinal: false))
        } else {
            taskWords.append(w)
            events.append(Event(time: arrival, generation: generation,
                                text: taskWords.joined(separator: " "), isFinal: false))
        }
        lastWordTime = word.time
    }
    events.sort { $0.time < $1.time }

    let end = duration ?? ((plan.words.last?.time ?? 0) + 5)
    let dt = 1 / options.frameRate
    var t = 0.0
    var eventIndex = 0
    var truthIndex = 0
    var truth = -1
    var relayoutDone = false

    while t <= end {
        while eventIndex < events.count && events[eventIndex].time <= t {
            let e = events[eventIndex]
            eventIndex += 1
            let start = DispatchTime.now().uptimeNanoseconds
            if buffer.update(hypothesis: e.text, generation: e.generation, isFinal: e.isFinal) {
                let outcome = matcher.process(spoken: buffer.tail(matcher.configuration.tailLength))
                result.outcomes.append(outcome)
                switch outcome {
                case .advanced(let p): pacer.confirm(position: p, at: t, isJump: false)
                case .jumped(let p): pacer.confirm(position: p, at: t, isJump: true)
                case .held: break
                }
                result.updates += 1
            }
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            result.maxUpdateMilliseconds = max(result.maxUpdateMilliseconds, ms)
        }
        while truthIndex < plan.words.count && plan.words[truthIndex].time <= t {
            if let idx = plan.words[truthIndex].scriptIndex { truth = idx }
            truthIndex += 1
        }
        if let relayout = options.relayoutAt, !relayoutDone, t >= relayout.time {
            // Rotation / font change: keep the same token position under the new layout.
            let anchor = geometry.position(forOffset: spring.position)
            geometry = makeGeometry(tokenCount: script.count, wordsPerLine: relayout.wordsPerLine,
                                    lineHeight: options.lineHeight)
            spring.snap(to: geometry.offset(forPosition: anchor))
            relayoutDone = true
        }
        let goalTokens = pacer.goal(at: t)
        let goal = geometry.offset(forPosition: goalTokens + 1)
        spring.step(toward: goal, dt: dt, backwardTolerance: options.lineHeight * 1.2)
        result.samples.append(SimulationSample(time: t, truth: truth, matched: matcher.position,
                                               scroll: spring.position, goalTokens: goalTokens))
        t += dt
    }
    result.finalPosition = matcher.position
    return result
}

// MARK: - Scenario scripts

enum TestScripts {
    static let sample = """
    Welcome. This is a sample script, so you can try the prompter before you write your own.

    Press play and start reading out loud. In Voice Follow mode, the script listens to you and moves at your pace. Read slowly, and it waits for you. Read quickly, and it keeps up. If you stop to take a breath, the text stops with you.

    Try skipping ahead to the next sentence. The prompter will find your place. Try repeating a phrase. Your place stays put.

    If you lose your spot, keep reading any line you can see, and the script will catch up. You can also drag the text with your finger at any time to move it by hand.

    Prefer a steady scroll? Switch to Timed Scroll at the bottom of the screen and set the speed in words per minute. Tap anywhere on the text to pause.

    Open settings to change the font, the size, the colors and the line spacing. If you use a beam splitter glass, turn on mirroring so the words read correctly in the reflection.

    On Sunday morning, the goal is simple. The person on stage should be looking at the people in the room, not hunting for the next line. Good tools get out of the way so the message comes through clearly.

    When you are ready, go back to the library and create your first script. You can paste text from the clipboard or import a plain text file.

    Thank you for reading. You are ready to go.
    """

    /// Duplicate phrases on purpose: sentence 2 and sentence 4 start the same way.
    static let duplicates = """
    We gather every week to worship together. The band starts at nine and the doors open at eight thirty. Grace is enough for every one of us. We serve our city with open hands and open doors. Grace is enough for every one of us, even on the hard days. Thank you for being here this morning.
    """

    static let longForm: String = {
        let extra = """
        Every service starts long before the first song. It starts on Tuesday, when the team looks at the plan and asks what the room needs to hear. A clear plan gives every volunteer a place to stand and a reason to be there.

        Sound check is not a formality. It is the moment the band and the engineer agree on what the room should feel like. When the mix is right, nobody notices the mix. They notice the song, the words, and the people singing next to them.

        Lighting works the same way. Bright enough to see faces, warm enough to feel welcome, and quiet enough that it never pulls attention away from the stage. Good lighting supports the moment instead of competing with it.

        The camera team tells the story for everyone watching from home. A wide shot shows the room. A close shot shows a face. Knowing when to cut between them is what turns a recording into a service people want to join.

        Volunteers are the heart of all of this. Train them well, thank them often, and give them tools that make sense on a busy Sunday. A volunteer who feels prepared will come back next week, and the week after that.

        When something breaks, and something always breaks, stay calm and work the problem. Check the cable, check the input, check the setting. Most problems are simple once you slow down long enough to look.

        At the end of the day, the technology is there to serve the message. When it works, people hear clearly, see clearly, and feel invited in. That is the whole point.
        """
        return sample + "\n\n" + extra
    }()
}
