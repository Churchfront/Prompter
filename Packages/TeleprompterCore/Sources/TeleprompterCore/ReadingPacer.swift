import Foundation

/// Turns discrete matcher positions into a smooth reading goal.
///
/// Recognition results arrive in bursts. Between bursts the pacer glides the
/// goal forward at the reader's measured pace, for at most `graceInterval`
/// seconds and at most `maxLead` words past the last confirmed word. When the
/// reader pauses longer than the grace interval, the goal stops. There is no
/// fixed words-per-minute setting: the pace is measured from the reader.
public struct ReadingPacer: Sendable {
    /// Seconds after the last recognized word during which the goal keeps gliding.
    public var graceInterval: Double
    /// Maximum words the goal may run ahead of the last confirmed word.
    public var maxLead: Double

    /// Last confirmed token index (-1 before the first word).
    public private(set) var confirmed: Double = -1
    /// Measured reading pace in words per second.
    public private(set) var wordsPerSecond: Double
    public private(set) var lastAdvanceTime: Double?
    private var paceSamples = 0

    public init(graceInterval: Double = 1.2, maxLead: Double = 1.5, initialWordsPerSecond: Double = 2.3) {
        self.graceInterval = graceInterval
        self.maxLead = maxLead
        self.wordsPerSecond = initialWordsPerSecond
    }

    /// True once at least a few pace measurements were taken.
    public var hasMeasuredPace: Bool { paceSamples >= 3 }

    /// Records a matcher decision at `time` (seconds, monotonic).
    public mutating func confirm(position: Int, at time: Double, isJump: Bool) {
        let newPosition = Double(position)
        if !isJump, newPosition > confirmed, let last = lastAdvanceTime {
            let dt = time - last
            if dt >= 0.05 && dt <= 3.0 {
                let instant = min(max((newPosition - confirmed) / dt, 0.5), 7.0)
                let blend = paceSamples < 3 ? 0.5 : 0.25
                wordsPerSecond = wordsPerSecond * (1 - blend) + instant * blend
                paceSamples += 1
            }
        }
        confirmed = newPosition
        lastAdvanceTime = time
    }

    /// Resets to a position without speech (manual move, restart).
    public mutating func reset(to position: Int) {
        confirmed = Double(position)
        lastAdvanceTime = nil
    }

    /// Fractional token position the display should aim for at `time`.
    public func goal(at time: Double) -> Double {
        guard let last = lastAdvanceTime else { return confirmed }
        let elapsed = min(max(time - last, 0), graceInterval)
        return confirmed + min(wordsPerSecond * elapsed, maxLead)
    }

    /// True while the reader is within the grace interval of their last word.
    public func isSpeaking(at time: Double) -> Bool {
        guard let last = lastAdvanceTime else { return false }
        return time - last <= graceInterval
    }
}
