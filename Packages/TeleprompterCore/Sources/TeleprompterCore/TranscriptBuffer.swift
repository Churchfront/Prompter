import Foundation

/// Keeps a rolling window of recognized words across recognition tasks.
///
/// Speech recognition tasks are restarted periodically (time limits, silence,
/// errors). Each new task starts with an empty transcript, which would leave
/// the matcher with only one or two words of context. The buffer carries the
/// last words of finished tasks forward so the matcher always sees a full tail.
public struct TranscriptBuffer: Sendable {
    public private(set) var committed: [String] = []
    public private(set) var live: [String] = []
    public private(set) var generation: Int = -1
    private var finishedGenerations: Set<Int> = []
    public let capacity: Int

    public init(capacity: Int = 40) {
        self.capacity = capacity
    }

    /// Feeds the full transcript of recognition task `generation`.
    /// Returns true when the word sequence changed.
    @discardableResult
    public mutating func update(hypothesis: String, generation: Int, isFinal: Bool) -> Bool {
        // Late results from a task we already moved past are ignored.
        if generation < self.generation || finishedGenerations.contains(generation) { return false }
        if generation > self.generation {
            commitLive()
            self.generation = generation
        }
        let words = TextNormalizer.words(in: hypothesis)
        let changed = words != live
        live = words
        if isFinal {
            commitLive()
            finishedGenerations.insert(generation)
            if finishedGenerations.count > 16, let minGen = finishedGenerations.min() {
                finishedGenerations.remove(minGen)
            }
        }
        return changed
    }

    /// Moves live words into the committed history (task ended or rotated).
    public mutating func commitLive() {
        guard !live.isEmpty else { return }
        committed.append(contentsOf: live)
        if committed.count > capacity { committed.removeFirst(committed.count - capacity) }
        live = []
    }

    /// Forgets all context, for example after the reader repositions the script by hand.
    public mutating func clear() {
        committed = []
        live = []
    }

    /// The most recent `count` words across committed and live text.
    public func tail(_ count: Int) -> [String] {
        if live.count >= count { return Array(live.suffix(count)) }
        let fromCommitted = count - live.count
        return Array(committed.suffix(fromCommitted)) + live
    }
}
