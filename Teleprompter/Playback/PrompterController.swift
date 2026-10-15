import SwiftUI
import QuartzCore
import TeleprompterCore

enum PlaybackState: Equatable {
    case ready
    case countingDown(Int)
    case playing
    case paused
    case finished

    var isRunning: Bool {
        switch self {
        case .playing, .countingDown: true
        default: false
        }
    }
}

/// What the voice-follow indicator shows.
enum TrackingStatus: Equatable {
    case off
    case starting
    case following
    case waiting
    case findingPlace
    case unavailable
}

/// Highlight to draw: words before `readUpTo` are dimmed, `current` is emphasized.
struct PrompterHighlight: Equatable {
    var readUpTo: Int
    var current: Range<Int>?
}

/// The scrolling text view, as seen by the controller.
@MainActor
protocol PrompterSurface: AnyObject {
    var currentOffset: CGFloat { get }
    var maxOffset: CGFloat { get }
    var lineHeight: CGFloat { get }
    var geometry: TokenGeometry { get }
    var isUserInteracting: Bool { get }
    func setOffset(_ offset: CGFloat)
    func applyHighlight(_ highlight: PrompterHighlight)
}

/// Runs a prompter session: timed scrolling, voice following, countdown,
/// jumps, manual repositioning, app lifecycle and resume position.
///
/// Speech recognition (SpeechRecognizer), matching (ScriptMatcher), pacing
/// (ReadingPacer), scroll physics (ScrollSpring / TimedScrollModel) and
/// rendering (PrompterTextSurface) stay separate; this class only wires them.
/// Scroll offsets are applied directly to the text view every display frame
/// and never go through SwiftUI state.
@MainActor
@Observable
final class PrompterController {
    let scriptID: UUID
    let title: String
    let text: String
    let tokens: TokenizedScript

    // UI state
    private(set) var state: PlaybackState = .ready
    private(set) var mode: PrompterMode
    private(set) var progress: Double = 0
    private(set) var remaining: TimeInterval = 0
    private(set) var tracking: TrackingStatus = .off
    private(set) var micLevel: Double = 0
    private(set) var isOnDeviceRecognition = false
    var controlsVisible = true
    /// Problem that blocks Voice Follow, shown with a way forward.
    var speechIssue: SpeechIssue?
    /// Token to offer "pick up where you left off" from.
    private(set) var resumeCandidate: Int?

    var isEmpty: Bool { tokens.isEmpty }
    var settings: ReaderSettings { settingsStore.settings }

    // Collaborators
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let scriptStore: ScriptStore
    @ObservationIgnored private weak var surface: PrompterSurface?
    @ObservationIgnored private let speech = SpeechRecognizer()
    @ObservationIgnored private let matcher: ScriptMatcher
    @ObservationIgnored private var transcript = TranscriptBuffer()
    @ObservationIgnored private var pacer: ReadingPacer
    @ObservationIgnored private var spring = ScrollSpring()
    /// Firmer spring for jumps (restart, sentence skips), so long moves land quickly.
    @ObservationIgnored private var jumpSpring = ScrollSpring(omega: 9)
    @ObservationIgnored private var timed = TimedScrollModel()

    // Frame loop
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastFrameTime: CFTimeInterval?
    @ObservationIgnored private var lastReadoutTime: CFTimeInterval = 0
    @ObservationIgnored private var offset: CGFloat = 0
    @ObservationIgnored private var jumpGoal: CGFloat?
    @ObservationIgnored private var jumpToken: Int?
    @ObservationIgnored private var idleFrames = 0
    @ObservationIgnored private var pendingStartToken: Int?

    @ObservationIgnored private var countdownTask: Task<Void, Never>?
    @ObservationIgnored private var hideControlsTask: Task<Void, Never>?
    @ObservationIgnored private var finishTask: Task<Void, Never>?

    init(script: Script, settingsStore: SettingsStore, scriptStore: ScriptStore) {
        scriptID = script.id
        title = script.displayTitle
        text = script.body
        tokens = TokenizedScript(text: script.body)
        self.settingsStore = settingsStore
        self.scriptStore = scriptStore
        let s = settingsStore.settings
        mode = s.mode
        matcher = ScriptMatcher(script: tokens, configuration: MatcherConfiguration(tolerance: s.matchTolerance))
        pacer = ReadingPacer(graceInterval: s.pauseGrace)

        if let last = script.lastPosition, last > 10, last < tokens.count - 5 {
            resumeCandidate = last
        }

        speech.onTranscript = { [weak self] update in self?.handleTranscript(update) }
        speech.onStateChange = { [weak self] state in self?.handleListeningState(state) }
    }

    // MARK: Surface

    func attach(surface: PrompterSurface) {
        self.surface = surface
        startDisplayLink()
    }

    /// The text view re-laid out (rotation, font change) and preserved the reading position.
    func surfaceDidRelayout(offset newOffset: CGFloat) {
        offset = newOffset
        spring.snap(to: Double(newOffset))
        if jumpGoal != nil, let token = jumpToken, let surface {
            // Recompute an in-flight jump against the new layout.
            jumpGoal = min(CGFloat(surface.geometry.offset(forPosition: Double(token))), surface.maxOffset)
        }
        if let token = pendingStartToken, let surface, !surface.geometry.isEmpty {
            pendingStartToken = nil
            place(atToken: token, animated: false)
        }
        refreshReadouts(now: CACurrentMediaTime(), force: true)
        wakeFrameLoop()
    }

    // MARK: Playback controls

    func togglePlay() {
        noteInteraction()
        if state.isRunning { pause() } else { play() }
    }

    func play() {
        guard !isEmpty else { return }
        resumeCandidate = nil
        if state == .finished { place(atToken: 0, animated: true) }

        if mode == .voiceFollow {
            switch SpeechRecognizer.authorization() {
            case .authorized:
                break
            case .notDetermined:
                Task {
                    let result = await SpeechRecognizer.requestAuthorization()
                    if case .denied(let issue) = result {
                        self.speechIssue = issue
                    } else if result == .authorized {
                        self.play()
                    }
                }
                return
            case .denied(let issue):
                speechIssue = issue
                return
            }
        }

        let useCountdown = state == .ready || state == .finished
        if useCountdown && settings.countdownSeconds > 0 {
            startCountdown(seconds: settings.countdownSeconds)
        } else {
            beginPlaying()
        }
    }

    func pause() {
        countdownTask?.cancel()
        finishTask?.cancel()
        guard state.isRunning else { return }
        state = .paused
        timed.stop()
        stopListening()
        showControls()
        saveResumePosition()
    }

    /// Jump to the top. A running session counts down again from the start.
    func restart() {
        noteInteraction()
        let wasRunning = state.isRunning
        countdownTask?.cancel()
        finishTask?.cancel()
        timed.stop()
        stopListening()
        resumeCandidate = nil
        place(atToken: 0, animated: true)
        state = .ready
        showControls()
        if wasRunning { play() }
    }

    /// Back to the start of the current sentence, or the previous one.
    func rewind() {
        noteInteraction()
        place(atToken: tokens.rewindTarget(from: currentToken), animated: true)
    }

    /// Ahead to the start of the next sentence.
    func skipForward() {
        noteInteraction()
        if let next = tokens.nextSentenceStart(after: currentToken) {
            place(atToken: next, animated: true)
        }
    }

    func setMode(_ newMode: PrompterMode) {
        guard newMode != mode else { return }
        noteInteraction()
        if state.isRunning { pause() }
        mode = newMode
        settingsStore.settings.mode = newMode
        syncVoicePositionToScroll()
        speechIssue = nil
        tracking = .off
        refreshReadouts(now: CACurrentMediaTime(), force: true)
    }

    /// Mirror mode for beam-splitter glass: flips the script text left to right.
    var isMirrored: Bool { settings.mirrorHorizontally }

    func toggleMirror() {
        noteInteraction()
        settingsStore.settings.mirrorHorizontally.toggle()
    }

    func adjustSpeed(by delta: Double) {
        noteInteraction()
        let range = ReaderSettings.wordsPerMinuteRange
        settingsStore.settings.wordsPerMinute = (settings.wordsPerMinute + delta).clamped(to: range).rounded()
    }

    func resumeFromLastPosition() {
        guard let token = resumeCandidate else { return }
        resumeCandidate = nil
        place(atToken: token, animated: true)
    }

    func dismissResume() {
        resumeCandidate = nil
    }

    func handleTap() {
        if settings.tapToPause && !isEmpty {
            if state.isRunning { pause() } else if state != .ready || resumeCandidate == nil { play() }
        } else {
            controlsVisible.toggle()
            if controlsVisible { noteInteraction() }
        }
    }

    func noteInteraction() {
        showControls()
        scheduleAutoHide()
    }

    func useTimedScrollInstead() {
        speechIssue = nil
        setMode(.timed)
    }

    /// Settings changed (possibly mid-script).
    func settingsDidChange() {
        wakeFrameLoop()
        let s = settings
        let config = MatcherConfiguration(tolerance: s.matchTolerance)
        if matcher.configuration != config { matcher.configuration = config }
        pacer.graceInterval = s.pauseGrace
        refreshReadouts(now: CACurrentMediaTime(), force: true)
    }

    // MARK: Manual repositioning

    func userBeganInteraction() {
        jumpGoal = nil
        showControls()
        wakeFrameLoop()
    }

    func userEndedInteraction(at newOffset: CGFloat) {
        jumpGoal = nil
        offset = newOffset
        spring.snap(to: Double(newOffset))
        resumeCandidate = nil
        syncVoicePositionToScroll()
        if state == .finished { state = .paused }
        refreshReadouts(now: CACurrentMediaTime(), force: true)
        scheduleAutoHide()
    }

    // MARK: Lifecycle

    func handleScenePhase(_ phase: ScenePhase) {
        switch phase {
        case .background:
            pause()
            saveResumePosition()
        case .inactive:
            // Control Center, an incoming call banner: stop listening, keep the place.
            if mode == .voiceFollow { pause() }
        case .active:
            showControls()
        @unknown default:
            break
        }
    }

    /// The prompter is closing.
    func close() {
        countdownTask?.cancel()
        hideControlsTask?.cancel()
        finishTask?.cancel()
        stopListening()
        saveResumePosition()
        displayLink?.invalidate()
        displayLink = nil
    }

    // MARK: Internals

    private var currentToken: Int {
        guard !tokens.isEmpty else { return 0 }
        if mode == .voiceFollow { return tokens.clamp(matcher.position + 1) }
        return tokens.clamp(Int(scrollPosition.rounded()))
    }

    /// Fractional token position at the reading line.
    private var scrollPosition: Double {
        guard let surface else { return 0 }
        return surface.geometry.position(forOffset: Double(offset))
    }

    private func place(atToken token: Int, animated: Bool) {
        let t = tokens.clamp(token)
        matcher.reset(to: t - 1)
        pacer.reset(to: t - 1)
        transcript.clear()
        guard let surface, !surface.geometry.isEmpty else {
            pendingStartToken = t
            return
        }
        // The start of the script is the very top, so opening stage directions stay in view.
        let position = t == 0 ? -1 : Double(t)
        let goal = min(max(CGFloat(surface.geometry.offset(forPosition: position)), 0), surface.maxOffset)
        if animated {
            jumpSpring.snap(to: Double(offset))
            jumpGoal = goal
            jumpToken = t
            wakeFrameLoop()
        } else {
            jumpGoal = nil
            offset = goal
            spring.snap(to: Double(goal))
            surface.setOffset(goal)
        }
        refreshReadouts(now: CACurrentMediaTime(), force: true)
    }

    private func syncVoicePositionToScroll() {
        guard !tokens.isEmpty else { return }
        let token = tokens.clamp(Int(scrollPosition.rounded()))
        matcher.reset(to: token - 1)
        pacer.reset(to: token - 1)
        transcript.clear()
    }

    private func startCountdown(seconds: Int) {
        countdownTask?.cancel()
        if mode == .voiceFollow { startListening() } // warm up the microphone during the countdown
        state = .countingDown(seconds)
        wakeFrameLoop()
        countdownTask = Task { [weak self] in
            for remaining in stride(from: seconds, to: 0, by: -1) {
                guard let self, !Task.isCancelled else { return }
                self.state = .countingDown(remaining)
                try? await Task.sleep(for: .seconds(1))
            }
            guard let self, !Task.isCancelled else { return }
            self.beginPlaying()
        }
    }

    private func beginPlaying() {
        state = .playing
        wakeFrameLoop()
        lastFrameTime = nil
        timed.stop()
        if mode == .voiceFollow {
            pacer.reset(to: matcher.position)
            startListening()
        }
        scheduleAutoHide()
    }

    private func finish() {
        guard state == .playing else { return }
        state = .finished
        timed.stop()
        stopListening()
        showControls()
        scriptStore.updateResumePosition(id: scriptID, position: nil)
    }

    private func startListening() {
        speech.preferOnDevice = settings.preferOnDeviceRecognition
        if speech.contextualStrings.isEmpty {
            speech.contextualStrings = tokens.distinctiveWords(in: text)
        }
        if speech.state != .listening && speech.state != .starting {
            speech.start()
        }
        tracking = .starting
    }

    private func stopListening() {
        speech.stop()
        tracking = .off
        micLevel = 0
    }

    private func handleTranscript(_ update: TranscriptUpdate) {
        guard mode == .voiceFollow, state == .playing, jumpGoal == nil else { return }
        guard transcript.update(hypothesis: update.text, generation: update.generation, isFinal: update.isFinal) else { return }
        let outcome = matcher.process(spoken: transcript.tail(matcher.configuration.tailLength))
        let now = CACurrentMediaTime()
        switch outcome {
        case .advanced(let p): pacer.confirm(position: p, at: now, isJump: false)
        case .jumped(let p): pacer.confirm(position: p, at: now, isJump: true)
        case .held: break
        }
        if matcher.position >= tokens.count - 1 && finishTask == nil {
            // Let the last line settle before stopping.
            finishTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(1.5))
                guard let self, !Task.isCancelled else { return }
                self.finishTask = nil
                self.finish()
            }
        }
    }

    private func handleListeningState(_ listening: ListeningState) {
        isOnDeviceRecognition = speech.isUsingOnDeviceRecognition
        switch listening {
        case .unavailable(let issue):
            tracking = .unavailable
            if mode == .voiceFollow && state.isRunning {
                pause()
                speechIssue = issue
            }
        case .interrupted:
            if mode == .voiceFollow && state.isRunning { pause() }
        case .listening:
            tracking = .waiting
        case .starting:
            tracking = .starting
        case .idle:
            break
        }
    }

    private func saveResumePosition() {
        guard !tokens.isEmpty else { return }
        let token = currentToken
        let position = token > 10 && token < tokens.count - 5 ? token : nil
        scriptStore.updateResumePosition(id: scriptID, position: position)
    }

    // MARK: Controls visibility

    private func showControls() {
        hideControlsTask?.cancel()
        if !controlsVisible { controlsVisible = true }
    }

    private func scheduleAutoHide() {
        hideControlsTask?.cancel()
        guard settings.autoHideControls, state.isRunning else { return }
        hideControlsTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard let self, !Task.isCancelled, self.state == .playing else { return }
            self.controlsVisible = false
        }
    }

    // MARK: Frame loop

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = DisplayLinkTarget(owner: self)
        let link = CADisplayLink(target: target, selector: #selector(DisplayLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.timestamp
        let dt = lastFrameTime.map { now - $0 } ?? (1.0 / 60.0)
        lastFrameTime = now
        guard let surface else { return }

        if surface.isUserInteracting {
            // The reader is dragging: follow their hand, do not fight it.
            offset = surface.currentOffset
            spring.snap(to: Double(offset))
            refreshReadouts(now: now, force: false)
            return
        }

        var next = offset
        if let goal = jumpGoal {
            next = CGFloat(jumpSpring.step(toward: Double(goal), dt: dt, backwardTolerance: 0))
            spring.snap(to: Double(next))
            if abs(next - goal) < 0.5 {
                next = goal
                jumpGoal = nil
                spring.snap(to: Double(goal))
                timed.stop()
            }
        } else if state == .playing {
            switch mode {
            case .timed:
                next = CGFloat(timed.step(offset: Double(offset), targetSpeed: timedPointsPerSecond, dt: dt))
                spring.snap(to: Double(next))
                if next >= surface.maxOffset {
                    next = surface.maxOffset
                    finish()
                }
            case .voiceFollow:
                let goal = surface.geometry.offset(forPosition: pacer.goal(at: now) + 1)
                next = CGFloat(spring.step(toward: goal, dt: dt,
                                           backwardTolerance: Double(surface.lineHeight) * 1.2))
            }
        }

        next = min(max(next, 0), max(surface.maxOffset, 0))
        if abs(next - offset) > 0.001 || abs(surface.currentOffset - next) > 0.5 {
            offset = next
            surface.setOffset(next)
        }
        refreshReadouts(now: now, force: false)

        // Sleep the frame loop when nothing moves; interactions wake it.
        let idle = !state.isRunning && jumpGoal == nil
        idleFrames = idle ? idleFrames + 1 : 0
        if idleFrames > 30 {
            link.isPaused = true
            lastFrameTime = nil
        }
    }

    private func wakeFrameLoop() {
        idleFrames = 0
        displayLink?.isPaused = false
    }

    private var timedPointsPerSecond: Double {
        let perWord = surface?.geometry.pointsPerWord ?? 0
        let fallback = Double(surface?.lineHeight ?? 60) / 8
        return settings.wordsPerMinute / 60 * (perWord > 0 ? perWord : fallback)
    }

    /// Updates progress, remaining time, highlight and the listening indicator, about ten times a second.
    private func refreshReadouts(now: CFTimeInterval, force: Bool) {
        guard force || now - lastReadoutTime >= 0.1 else { return }
        lastReadoutTime = now
        guard let surface, !tokens.isEmpty else {
            progress = 0
            remaining = 0
            return
        }
        let n = tokens.count
        let token = currentToken
        let newProgress = (Double(token) / Double(max(n - 1, 1))).clamped(to: 0...1)
        if abs(newProgress - progress) > 0.001 { progress = newProgress }

        let wordsLeft = n - token
        let pace: Double
        if mode == .voiceFollow && pacer.hasMeasuredPace {
            pace = pacer.wordsPerSecond * 60
        } else {
            pace = settings.wordsPerMinute
        }
        let newRemaining = ReadingTime.remaining(words: wordsLeft, wordsPerMinute: pace).rounded()
        if newRemaining != remaining { remaining = newRemaining }

        surface.applyHighlight(highlight(at: token))

        if mode == .voiceFollow && state == .playing {
            let level = Double(speech.level)
            if abs(level - micLevel) > 0.02 { micLevel = level }
            let status: TrackingStatus
            switch speech.state {
            case .listening:
                if matcher.isLost { status = .findingPlace }
                else if pacer.isSpeaking(at: now) { status = .following }
                else { status = .waiting }
            case .starting: status = .starting
            case .unavailable: status = .unavailable
            case .idle, .interrupted: status = .waiting
            }
            if status != tracking { tracking = status }
        }
    }

    private func highlight(at token: Int) -> PrompterHighlight {
        let s = settings
        let readUpTo: Int
        if !s.dimReadText {
            readUpTo = 0
        } else if mode == .voiceFollow {
            readUpTo = max(matcher.position + 1, 0)
        } else {
            readUpTo = token
        }
        let current: Range<Int>?
        let showCurrent = mode == .timed || state.isRunning || matcher.position >= 0
        switch s.highlightMode {
        case .off: current = nil
        case .word: current = showCurrent ? token..<(token + 1) : nil
        case .phrase: current = showCurrent ? tokens.phraseRange(containing: token) : nil
        case .sentence: current = showCurrent ? tokens.sentenceRange(containing: token) : nil
        }
        return PrompterHighlight(readUpTo: readUpTo, current: current)
    }
}

/// Breaks the retain cycle between CADisplayLink and the controller.
private final class DisplayLinkTarget: NSObject {
    weak var owner: PrompterController?

    init(owner: PrompterController) {
        self.owner = owner
    }

    @objc func tick(_ link: CADisplayLink) {
        MainActor.assumeIsolated {
            if let owner { owner.tick(link) } else { link.invalidate() }
        }
    }
}
