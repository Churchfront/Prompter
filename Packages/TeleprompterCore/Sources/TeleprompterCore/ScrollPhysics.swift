import Foundation

/// Critically damped spring that follows a moving goal (voice-follow scrolling
/// and jumps). Velocity stays continuous, so the text never stutters when the
/// goal updates in bursts. Small backward goals are ignored so recognition
/// corrections never make the text twitch backward.
public struct ScrollSpring: Sendable {
    /// Stiffness in 1/seconds. Higher settles faster.
    public var omega: Double
    public private(set) var position: Double
    public private(set) var velocity: Double = 0
    private var retreating = false

    public init(position: Double = 0, omega: Double = 4.5) {
        self.position = position
        self.omega = omega
    }

    /// Jumps to a position immediately (layout change, user drag).
    public mutating func snap(to newPosition: Double) {
        position = newPosition
        velocity = 0
        retreating = false
    }

    /// Advances by `dt` seconds toward `goal`. Goals behind the current position
    /// by more than `backwardTolerance` are followed; smaller ones are held.
    @discardableResult
    public mutating func step(toward goal: Double, dt rawDt: Double, backwardTolerance: Double) -> Double {
        // Long frames (app busy) are clamped so the text never leaps.
        let dt = min(max(rawDt, 0), 1.0 / 20.0)
        guard dt > 0 else { return position }

        if goal < position - backwardTolerance { retreating = true }
        if retreating && abs(goal - position) < 0.5 { retreating = false }

        var target = goal
        if !retreating && target < position { target = position }

        let displacement = position - target
        let acceleration = -omega * omega * displacement - 2 * omega * velocity
        velocity += acceleration * dt
        if !retreating && velocity < 0 { velocity = 0 }
        position += velocity * dt
        return position
    }

    public var isSettled: Bool { abs(velocity) < 0.5 }
}

/// Time-based continuous scrolling. Distance is speed multiplied by elapsed
/// time, never a fixed step per frame. Speed changes ease in so the text does
/// not lurch when the reader adjusts speed mid-script.
public struct TimedScrollModel: Sendable {
    /// Time constant for speed changes, in seconds.
    public var speedResponse: Double
    public private(set) var currentSpeed: Double = 0

    public init(speedResponse: Double = 0.35) {
        self.speedResponse = speedResponse
    }

    /// Returns the new offset after `dt` seconds at `targetSpeed` points per second.
    public mutating func step(offset: Double, targetSpeed: Double, dt rawDt: Double) -> Double {
        let dt = min(max(rawDt, 0), 0.1)
        let blend = 1 - exp(-dt / speedResponse)
        currentSpeed += (targetSpeed - currentSpeed) * blend
        return offset + currentSpeed * dt
    }

    public mutating func stop() { currentSpeed = 0 }
}

/// Maps between fractional token positions and vertical scroll offsets.
///
/// Each token gets a "reading y": the top of its line plus a fraction of the
/// line height proportional to the word's horizontal position on the line.
/// Reading across a line therefore scrolls the line up smoothly instead of in
/// line-sized steps, and the mapping is rebuilt after any layout change, so a
/// token position survives rotation and font-size changes exactly.
public struct TokenGeometry: Sendable {
    public let readingY: [Double]

    public init(readingY: [Double]) {
        self.readingY = readingY
    }

    public var isEmpty: Bool { readingY.isEmpty }

    /// Offset for a fractional token position.
    public func offset(forPosition position: Double) -> Double {
        guard let first = readingY.first else { return 0 }
        if position <= 0 { return first * max(0, 1 + position) }
        let last = readingY.count - 1
        if position >= Double(last) { return readingY[last] }
        let i = Int(position.rounded(.down))
        let f = position - Double(i)
        return readingY[i] + (readingY[i + 1] - readingY[i]) * f
    }

    /// Fractional token position for an offset (inverse of `offset(forPosition:)`).
    public func position(forOffset offset: Double) -> Double {
        guard let first = readingY.first else { return 0 }
        if offset <= first { return first > 0 ? offset / first - 1 : 0 }
        let last = readingY.count - 1
        if offset >= readingY[last] { return Double(last) }
        var lo = 0, hi = last
        while hi - lo > 1 {
            let mid = (lo + hi) / 2
            if readingY[mid] <= offset { lo = mid } else { hi = mid }
        }
        let span = readingY[hi] - readingY[lo]
        let f = span > 0 ? (offset - readingY[lo]) / span : 0
        return Double(lo) + f
    }

    /// Average vertical distance per word, used to convert words per minute to points per second.
    public var pointsPerWord: Double {
        guard readingY.count > 1, let first = readingY.first, let last = readingY.last else { return 0 }
        return (last - first) / Double(readingY.count - 1)
    }
}

/// Remaining-time estimates.
public enum ReadingTime {
    public static func remaining(words: Int, wordsPerMinute: Double) -> TimeInterval {
        guard wordsPerMinute > 0 else { return 0 }
        return Double(max(words, 0)) / wordsPerMinute * 60
    }

    /// "4:05" or "1:02:10".
    public static func format(_ interval: TimeInterval) -> String {
        let total = Int(max(interval, 0).rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
