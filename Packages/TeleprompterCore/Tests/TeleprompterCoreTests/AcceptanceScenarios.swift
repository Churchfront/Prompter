import Foundation
@testable import TeleprompterCore

/// Collects pass/fail checks for one scenario without depending on a test framework.
final class ScenarioReport {
    let name: String
    private(set) var failures: [String] = []
    private(set) var notes: [String] = []

    init(_ name: String) { self.name = name }

    func check(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { failures.append(message()) }
    }
    func note(_ message: String) { notes.append(message) }
    var passed: Bool { failures.isEmpty }
}

enum AcceptanceScenarios {

    static var all: [(String, () -> ScenarioReport)] {
        [
            ("1. Slow reading is followed slowly", slowReading),
            ("2. Fast reading is followed quickly", fastReading),
            ("3. Silence stops the script", pauseStops),
            ("4. Resuming continues at the right words", resumeAfterPause),
            ("5. Skipping a sentence ignores distant duplicates", skipSentence),
            ("6. Repeating a phrase keeps the position stable", repeatPhrase),
            ("7. Recognition errors do not break tracking", recognitionErrors),
            ("8. Rotation preserves the reading position", rotationPreservesPosition),
            ("Extra. Off-script speech holds, then recovers", offScriptHoldsThenRecovers),
            ("10. Several minutes without drift", longReadNoDrift)
        ]
    }

    // MARK: Helpers

    /// Fraction of samples (after `warmup` seconds into speech) whose matched
    /// position is within `tolerance` tokens of the truth.
    static func trackingAccuracy(_ result: SimulationResult, from t0: Double, to t1: Double, tolerance: Int) -> Double {
        let window = result.samples(from: t0, to: t1).filter { $0.truth >= 0 }
        guard !window.isEmpty else { return 0 }
        let good = window.filter { abs($0.matched - $0.truth) <= tolerance }.count
        return Double(good) / Double(window.count)
    }

    static func largestBackwardStep(_ result: SimulationResult) -> Double {
        var worst = 0.0
        for (a, b) in zip(result.samples, result.samples.dropFirst()) {
            worst = max(worst, a.scroll - b.scroll)
        }
        return worst
    }

    static func tokenCount(_ text: String) -> Int { TokenizedScript(text: text).count }

    // MARK: Scenarios

    static func readWhole(wps: Double, seed: UInt64) -> (SimulationResult, SpeechPlan, Int) {
        let text = TestScripts.sample
        let n = tokenCount(text)
        var random = SeededRandom(seed: seed)
        var plan = SpeechPlan(script: text, startTime: 1)
        plan.read(0..<n, wordsPerSecond: wps, random: &random)
        return (simulate(script: text, plan: plan), plan, n)
    }

    static func slowReading() -> ScenarioReport {
        let r = ScenarioReport("slow")
        let (result, plan, n) = readWhole(wps: 1.2, seed: 1)
        let speechEnd = plan.words.last!.time
        r.check(result.finalPosition >= n - 2, "finished at \(result.finalPosition) of \(n - 1)")
        let accuracy = trackingAccuracy(result, from: 3, to: speechEnd, tolerance: 2)
        r.check(accuracy >= 0.95, "tracking within 2 words only \(Int(accuracy * 100))% of the time")
        // The text must not run ahead of a slow reader.
        let ahead = result.samples.filter { $0.matched > $0.truth + 1 }.count
        r.check(ahead == 0, "matcher ran ahead of the reader in \(ahead) samples")
        r.check(largestBackwardStep(result) < 0.5, "scroll moved backward by \(largestBackwardStep(result)) pt")
        r.note("read \(n) words in \(Int(speechEnd)) s, accuracy \(Int(accuracy * 100))%")
        return r
    }

    static func fastReading() -> ScenarioReport {
        let r = ScenarioReport("fast")
        let (result, plan, n) = readWhole(wps: 4.2, seed: 2)
        let speechEnd = plan.words.last!.time
        r.check(result.finalPosition >= n - 2, "finished at \(result.finalPosition) of \(n - 1)")
        // At 4+ words per second, recognition latency alone is ~1.5 words.
        let accuracy = trackingAccuracy(result, from: 2, to: speechEnd, tolerance: 3)
        r.check(accuracy >= 0.93, "tracking within 3 words only \(Int(accuracy * 100))% of the time")
        r.check(largestBackwardStep(result) < 0.5, "scroll moved backward by \(largestBackwardStep(result)) pt")
        // Fast reading finishes much sooner than slow reading: the script follows the reader.
        let slow = readWhole(wps: 1.2, seed: 1)
        let reachEndFast = result.samples.first { $0.matched >= n - 2 }?.time ?? .infinity
        let reachEndSlow = slow.0.samples.first { $0.matched >= n - 2 }?.time ?? .infinity
        r.check(reachEndFast < reachEndSlow * 0.4, "fast read reached the end at \(Int(reachEndFast)) s vs slow \(Int(reachEndSlow)) s")
        r.note("reached end at \(Int(reachEndFast)) s (slow read: \(Int(reachEndSlow)) s), accuracy \(Int(accuracy * 100))%")
        return r
    }

    static func pauseScenario() -> (SimulationResult, pauseStart: Double, resumeTime: Double, pausedAt: Int, plan: SpeechPlan) {
        let text = TestScripts.sample
        var random = SeededRandom(seed: 3)
        var plan = SpeechPlan(script: text, startTime: 1)
        plan.read(0..<60, wordsPerSecond: 2.5, random: &random)
        let pauseStart = plan.time
        plan.pause(6)
        let resumeTime = plan.time
        plan.read(60..<110, wordsPerSecond: 2.5, random: &random)
        return (simulate(script: text, plan: plan), pauseStart, resumeTime, 59, plan)
    }

    static func pauseStops() -> ScenarioReport {
        let r = ScenarioReport("pause")
        let (result, pauseStart, resumeTime, pausedAt, _) = pauseScenario()
        let settle = pauseStart + 0.35 + 1.2 + 1.5 // latency + grace + spring settle
        let before = result.samples.first { $0.time >= settle }!
        let after = result.samples.last { $0.time <= resumeTime }!
        r.check(abs(after.scroll - before.scroll) < 1.0,
                "scroll kept moving during silence: \(before.scroll) -> \(after.scroll) pt")
        let duringPause = result.samples(from: pauseStart + 0.5, to: resumeTime)
        r.check(duringPause.allSatisfy { $0.matched == pausedAt },
                "position changed during silence (expected \(pausedAt))")
        let maxGoal = duringPause.map(\.goalTokens).max() ?? 0
        r.check(maxGoal <= Double(pausedAt) + 1.5 + 0.001, "goal ran \(maxGoal - Double(pausedAt)) words past the last spoken word")
        r.note("scroll held at \(Int(after.scroll)) pt for the \(Int(resumeTime - settle)) s after the grace period")
        return r
    }

    static func resumeAfterPause() -> ScenarioReport {
        let r = ScenarioReport("resume")
        let (result, _, resumeTime, _, plan) = pauseScenario()
        let firstWord = plan.words.first { $0.time >= resumeTime }!.time
        let window = result.samples(from: firstWord + 1.5, to: plan.words.last!.time)
        let accurate = window.filter { abs($0.matched - $0.truth) <= 2 }.count
        r.check(Double(accurate) / Double(window.count) >= 0.95,
                "after resuming, only \(accurate) of \(window.count) samples within 2 words")
        r.check(result.finalPosition >= 108, "ended at \(result.finalPosition), expected about 109")
        r.check(largestBackwardStep(result) < 0.5, "scroll moved backward")
        return r
    }

    static func skipSentence() -> ScenarioReport {
        let r = ScenarioReport("skip")
        let text = TestScripts.duplicates
        let script = TokenizedScript(text: text)
        let s = script.sentenceStarts
        var random = SeededRandom(seed: 5)

        // A: read sentence 0, skip sentence 1, read sentence 2 (whose opening repeats in sentence 4).
        var planA = SpeechPlan(script: text, startTime: 1)
        planA.read(s[0]..<s[1], wordsPerSecond: 2.5, random: &random)
        planA.read(s[2]..<s[3], wordsPerSecond: 2.5, random: &random)
        let a = simulate(script: text, plan: planA)
        r.check(a.finalPosition == s[3] - 1, "case A ended at \(a.finalPosition), expected \(s[3] - 1) (end of sentence 2)")
        let wrongA = a.samples.filter { $0.matched >= s[4] }.count
        r.check(wrongA == 0, "case A jumped to the duplicate in sentence 4")

        // B: read sentences 0 to 2, skip sentence 3, read sentence 4 (same opening as sentence 2, behind us).
        var planB = SpeechPlan(script: text, startTime: 1)
        planB.read(s[0]..<s[3], wordsPerSecond: 2.5, random: &random)
        planB.read(s[4]..<s[5], wordsPerSecond: 2.5, random: &random)
        let b = simulate(script: text, plan: planB)
        r.check(b.finalPosition == s[5] - 1, "case B ended at \(b.finalPosition), expected \(s[5] - 1) (end of sentence 4)")
        let backward = zip(b.samples, b.samples.dropFirst()).contains { $1.matched < $0.matched }
        r.check(!backward, "case B moved backward to the earlier duplicate")
        let recoveryB = b.samples.first { $0.matched >= s[4] }?.time ?? .infinity
        let skipStart = planB.words.first { ($0.scriptIndex ?? 0) >= s[4] }!.time
        r.check(recoveryB - skipStart < 3.5, "case B took \(recoveryB - skipStart) s to find the skipped-to sentence")
        r.note("case B recovered \(String(format: "%.1f", recoveryB - skipStart)) s after the skip")
        return r
    }

    static func repeatPhrase() -> ScenarioReport {
        let r = ScenarioReport("repeat")
        let text = TestScripts.sample
        var random = SeededRandom(seed: 6)
        var plan = SpeechPlan(script: text, startTime: 1)
        plan.read(0..<45, wordsPerSecond: 2.5, random: &random)
        let repeatStart = plan.time
        plan.read(41..<45, wordsPerSecond: 2.5, random: &random)   // repeat the last four words
        plan.read(41..<45, wordsPerSecond: 2.5, random: &random)   // and again
        let repeatEnd = plan.time
        plan.read(45..<80, wordsPerSecond: 2.5, random: &random)
        let result = simulate(script: text, plan: plan)

        let duringRepeat = result.samples(from: repeatStart + 0.5, to: repeatEnd + 0.3)
        r.check(duringRepeat.allSatisfy { $0.matched == 44 }, "position moved while repeating (expected 44)")
        let backward = zip(result.samples, result.samples.dropFirst()).contains { $1.matched < $0.matched }
        r.check(!backward, "position moved backward")
        r.check(largestBackwardStep(result) < 0.5, "scroll moved backward")
        r.check(result.finalPosition == 79, "ended at \(result.finalPosition), expected 79")
        return r
    }

    static func recognitionErrors() -> ScenarioReport {
        let r = ScenarioReport("errors")
        let text = TestScripts.sample
        let n = tokenCount(text)
        var random = SeededRandom(seed: 7)
        var plan = SpeechPlan(script: text, startTime: 1)
        plan.read(0..<n, wordsPerSecond: 2.6, substitutionRate: 0.12, dropRate: 0.05,
                  insertionRate: 0.03, random: &random)
        let result = simulate(script: text, plan: plan)
        r.check(result.finalPosition >= n - 3, "ended at \(result.finalPosition) of \(n - 1)")
        let accuracy = trackingAccuracy(result, from: 3, to: plan.words.last!.time, tolerance: 3)
        r.check(accuracy >= 0.9, "tracking within 3 words only \(Int(accuracy * 100))% of the time")
        r.check(largestBackwardStep(result) < 0.5, "scroll moved backward")
        r.note("12% garbled, 5% dropped, 3% inserted words: accuracy \(Int(accuracy * 100))%")
        return r
    }

    static func rotationPreservesPosition() -> ScenarioReport {
        let r = ScenarioReport("rotation")
        let text = TestScripts.sample
        let n = tokenCount(text)
        var random = SeededRandom(seed: 8)
        var plan = SpeechPlan(script: text, startTime: 1)
        plan.read(0..<n, wordsPerSecond: 2.5, random: &random)
        var options = SimulationOptions()
        options.relayoutAt = (time: 30, wordsPerLine: 14)    // portrait to landscape
        let result = simulate(script: text, plan: plan, options: options)

        // Same geometry maths the app uses, checked directly.
        let portrait = makeGeometry(tokenCount: n, wordsPerLine: 8, lineHeight: 60)
        let landscape = makeGeometry(tokenCount: n, wordsPerLine: 14, lineHeight: 60)
        for position in [0.0, 17.4, 63.9, Double(n - 1)] {
            let back = landscape.position(forOffset: landscape.offset(forPosition:
                portrait.position(forOffset: portrait.offset(forPosition: position))))
            r.check(abs(back - position) < 0.01, "position \(position) became \(back) after relayout")
        }
        let accuracy = trackingAccuracy(result, from: 3, to: plan.words.last!.time, tolerance: 2)
        r.check(accuracy >= 0.95, "tracking after relayout only \(Int(accuracy * 100))%")
        r.check(result.finalPosition >= n - 2, "ended at \(result.finalPosition)")
        return r
    }

    static func offScriptHoldsThenRecovers() -> ScenarioReport {
        let r = ScenarioReport("off-script")
        let text = TestScripts.sample
        var random = SeededRandom(seed: 9)
        var plan = SpeechPlan(script: text, startTime: 1)
        plan.read(0..<50, wordsPerSecond: 2.5, random: &random)
        let adLibStart = plan.time
        plan.adLib("hold on everybody I want to tell you a quick story about my dog before we keep going this morning", wordsPerSecond: 2.5)
        let adLibEnd = plan.time
        // The reader lost their place and picks up further down.
        plan.read(120..<160, wordsPerSecond: 2.5, random: &random)
        let result = simulate(script: text, plan: plan)

        let during = result.samples(from: adLibStart + 0.5, to: adLibEnd + 0.3)
        r.check(during.allSatisfy { $0.matched == 49 }, "position moved during off-script speech")
        r.check(result.finalPosition == 159, "ended at \(result.finalPosition), expected 159")
        let recovered = result.samples.first { $0.matched >= 120 }?.time ?? .infinity
        let resume = plan.words.first { ($0.scriptIndex ?? 0) >= 120 }!.time
        r.check(recovered - resume < 4, "took \(recovered - resume) s to find the reader again")
        r.note("held through \(Int(adLibEnd - adLibStart)) s of ad-lib, relocated \(String(format: "%.1f", recovered - resume)) s after reading resumed")
        return r
    }

    static func longReadNoDrift() -> ScenarioReport {
        let r = ScenarioReport("long")
        let text = TestScripts.longForm
        let n = tokenCount(text)
        var random = SeededRandom(seed: 10)
        var plan = SpeechPlan(script: text, startTime: 1)
        // Natural reading: varied pace, short breaths between paragraphs, some recognition errors.
        let script = TokenizedScript(text: text)
        var start = 0
        var paragraphStarts: [Int] = [0]
        for (i, t) in script.tokens.enumerated() where i > 0 && t.paragraph != script.tokens[i - 1].paragraph {
            paragraphStarts.append(i)
        }
        paragraphStarts.append(n)
        for (k, end) in paragraphStarts.dropFirst().enumerated() {
            let pace = [1.8, 2.4, 2.1, 2.7, 1.7][k % 5]
            plan.read(start..<end, wordsPerSecond: pace, substitutionRate: 0.06, dropRate: 0.03,
                      insertionRate: 0.01, random: &random)
            plan.pause(k % 3 == 0 ? 2.5 : 0.8)
            start = end
        }
        let result = simulate(script: text, plan: plan)
        let speechEnd = plan.words.last!.time
        r.check(speechEnd > 240, "plan should last several minutes (lasted \(Int(speechEnd)) s)")
        r.check(result.finalPosition >= n - 3, "ended at \(result.finalPosition) of \(n - 1)")

        // No progressive drift: accuracy in the last minute matches the first minute.
        let first = trackingAccuracy(result, from: 3, to: 63, tolerance: 3)
        let last = trackingAccuracy(result, from: speechEnd - 60, to: speechEnd, tolerance: 3)
        r.check(first >= 0.9 && last >= 0.9, "accuracy first minute \(Int(first * 100))%, last minute \(Int(last * 100))%")
        r.check(largestBackwardStep(result) < 0.5, "scroll moved backward by \(largestBackwardStep(result)) pt")
        r.check(result.maxUpdateMilliseconds < 25, "slowest update took \(result.maxUpdateMilliseconds) ms")
        r.note("\(n) words over \(Int(speechEnd / 60)) min \(Int(speechEnd) % 60) s with task restarts; accuracy first/last minute \(Int(first * 100))%/\(Int(last * 100))%; slowest update \(String(format: "%.2f", result.maxUpdateMilliseconds)) ms")
        return r
    }
}
