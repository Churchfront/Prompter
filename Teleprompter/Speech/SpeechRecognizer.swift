import AVFoundation
import Speech
import os

let speechLog = Logger(subsystem: "com.churchfront.prompter", category: "speech")

/// Why listening is not possible, with copy that explains the fix.
enum SpeechIssue: Equatable {
    case microphoneDenied
    case speechRecognitionDenied
    case restricted
    case recognizerUnavailable
    case unsupportedLanguage
    case noAudioInput
    /// Apple's recognizer refuses requests while Siri and Dictation are off.
    case dictationDisabled
    case failed(String)

    var title: String {
        switch self {
        case .microphoneDenied: "Microphone access is off"
        case .speechRecognitionDenied: "Speech recognition is off"
        case .restricted: "Speech recognition is restricted"
        case .recognizerUnavailable: "Speech recognition is unavailable right now"
        case .unsupportedLanguage: "This language is not supported"
        case .noAudioInput: "No microphone found"
        case .dictationDisabled: "Dictation is turned off"
        case .failed: "Listening stopped"
        }
    }

    var message: String {
        switch self {
        case .microphoneDenied:
            "Voice Follow needs the microphone to hear where you are in the script. Turn on Microphone for CuePrompter in Settings. Audio is never recorded or saved."
        case .speechRecognitionDenied:
            "Voice Follow uses speech recognition to match your words to the script. Turn on Speech Recognition for CuePrompter in Settings."
        case .restricted:
            "Speech recognition is restricted on this device, often by Screen Time or a device profile. Timed Scroll works without it."
        case .recognizerUnavailable:
            "Apple's speech recognizer is not responding. This is usually temporary, often from a lost network connection on devices without on-device recognition."
        case .unsupportedLanguage:
            "Speech recognition does not support this device's language. Timed Scroll works without it."
        case .noAudioInput:
            "Connect a microphone or check that no other app is using it, then try again."
        case .dictationDisabled:
            #if targetEnvironment(macCatalyst)
            "Voice Follow uses Apple's speech recognition, which works only while Dictation is on. Open System Settings > Keyboard, turn on Dictation, then press play again."
            #else
            "Voice Follow uses Apple's speech recognition, which works only while Dictation is on. Open Settings > General > Keyboard, turn on Enable Dictation, then press play again."
            #endif
        case .failed(let detail):
            "The speech recognizer stopped unexpectedly (\(detail)). Press play to try again."
        }
    }

    var canOpenSettings: Bool {
        self == .microphoneDenied || self == .speechRecognitionDenied
    }
}

enum ListeningState: Equatable {
    case idle
    case starting
    case listening
    /// A phone call, Siri or another app took the microphone.
    case interrupted
    case unavailable(SpeechIssue)
}

enum SpeechAuthorization: Equatable {
    case authorized
    case notDetermined
    case denied(SpeechIssue)
}

/// One recognizer update: the whole transcript of recognition task `generation`.
struct TranscriptUpdate {
    let text: String
    let generation: Int
    let isFinal: Bool
}

/// Streams microphone audio into Apple's speech recognizer and reports transcripts.
///
/// Audio buffers go straight from the input tap into the recognition request
/// and are never written anywhere. Recognition tasks are rotated before Apple's
/// per-task limits and restarted after silence or errors; each task gets a new
/// generation number so the transcript buffer can carry context across them.
@MainActor
final class SpeechRecognizer: NSObject {
    var onTranscript: ((TranscriptUpdate) -> Void)?
    var onStateChange: ((ListeningState) -> Void)?

    var preferOnDevice = true
    /// Script words (names, rare terms) the recognizer should expect.
    var contextualStrings: [String] = []

    private(set) var state: ListeningState = .idle {
        didSet { if state != oldValue { onStateChange?(state) } }
    }
    private(set) var isUsingOnDeviceRecognition = false

    /// Smoothed input level, 0...1, for the listening indicator.
    var level: Float { audioBridge.level }

    private let recognizer: SFSpeechRecognizer?
    private var audioEngine = AVAudioEngine()
    private var task: SFSpeechRecognitionTask?
    private let audioBridge = AudioBridge()
    private(set) var generation = 0
    private var rotationTimer: Timer?
    private var wantsListening = false
    private var recentFailures: [Date] = []
    private var engineStartedAt: Date?
    private var installedFormat: AVAudioFormat?
    private var inputRetries = 0
    private var observers: [NSObjectProtocol] = []

    override init() {
        recognizer = SFSpeechRecognizer(locale: .current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        super.init()
        recognizer?.delegate = self
        observeAudioSession()
    }

    // MARK: Authorization

    static func authorization() -> SpeechAuthorization {
        speechLog.notice("auth status: speech=\(SFSpeechRecognizer.authorizationStatus().rawValue, privacy: .public) mic=\(String(describing: AVAudioApplication.shared.recordPermission), privacy: .public)")
        switch SFSpeechRecognizer.authorizationStatus() {
        case .denied: return .denied(.speechRecognitionDenied)
        case .restricted: return .denied(.restricted)
        case .notDetermined: return .notDetermined
        case .authorized: break
        @unknown default: return .denied(.restricted)
        }
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .authorized
        case .denied: return .denied(.microphoneDenied)
        case .undetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    /// Asks for speech recognition, then microphone access. Prompts only the first time.
    static func requestAuthorization() async -> SpeechAuthorization {
        let speechStatus: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        switch speechStatus {
        case .authorized: break
        case .restricted: return .denied(.restricted)
        default: return .denied(.speechRecognitionDenied)
        }
        speechLog.notice("speech request result: \(speechStatus.rawValue, privacy: .public)")
        let micGranted = await AVAudioApplication.requestRecordPermission()
        speechLog.notice("mic request result: \(micGranted, privacy: .public)")
        return micGranted ? .authorized : .denied(.microphoneDenied)
    }

    // MARK: Control

    func start() {
        wantsListening = true
        recentFailures.removeAll()
        inputRetries = 0
        startEngine()
    }

    func stop() {
        wantsListening = false
        teardown()
        state = .idle
    }

    // MARK: Engine

    private func startEngine() {
        guard wantsListening else { return }
        guard let recognizer else { state = .unavailable(.unsupportedLanguage); return }
        guard recognizer.isAvailable else { state = .unavailable(.recognizerUnavailable); return }
        if case .denied(let issue) = Self.authorization() { state = .unavailable(issue); return }

        state = .starting
        teardown()
        // A fresh engine binds to the current input device and permission state.
        // An engine created before access was granted (macOS) reports no channels.
        audioEngine = AVAudioEngine()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.mixWithOthers, .allowBluetooth])
            try session.setActive(true, options: .notifyOthersOnDeactivation)

            let input = audioEngine.inputNode
            let format = input.outputFormat(forBus: 0)
            speechLog.notice("input format: \(format.sampleRate, privacy: .public) Hz, \(format.channelCount, privacy: .public) ch")
            guard format.sampleRate > 0, format.channelCount > 0 else {
                // The input can report an empty format for a moment while the
                // audio route settles (Bluetooth connecting, simulator devices).
                teardown()
                if inputRetries < 3 {
                    inputRetries += 1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                        MainActor.assumeIsolated { self?.startEngine() }
                    }
                } else {
                    state = .unavailable(.noAudioInput)
                }
                return
            }
            installedFormat = format
            input.installTap(onBus: 0, bufferSize: 1024, format: format, block: Self.makeTapBlock(audioBridge))
            audioEngine.prepare()
            try audioEngine.start()
            engineStartedAt = Date()
            inputRetries = 0
            beginTask()
            state = .listening
        } catch {
            speechLog.error("engine start failed: \(String(describing: error), privacy: .public)")
            teardown()
            state = .unavailable(.noAudioInput)
        }
    }

    private func beginTask() {
        guard let recognizer, wantsListening else { return }
        generation += 1
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        request.addsPunctuation = false
        request.contextualStrings = contextualStrings
        let onDevice = preferOnDevice && recognizer.supportsOnDeviceRecognition
        request.requiresOnDeviceRecognition = onDevice
        isUsingOnDeviceRecognition = onDevice

        let previousTask = task
        audioBridge.swap(to: request)?.endAudio()
        task = recognizer.recognitionTask(with: request,
                                          resultHandler: Self.makeResultHandler(generation: generation, owner: self))
        previousTask?.cancel()

        // Server recognition is limited to about a minute per task. Rotate early;
        // the transcript buffer keeps the words from the previous task.
        rotationTimer?.invalidate()
        let interval: TimeInterval = onDevice ? 240 : 50
        rotationTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.beginTask() }
        }
    }

    private func handleResult(generation resultGeneration: Int, text: String?, isFinal: Bool, errorCode: Int?) {
        guard wantsListening, resultGeneration == generation else { return }
        if let text, !text.isEmpty {
            onTranscript?(TranscriptUpdate(text: text, generation: resultGeneration, isFinal: isFinal))
        }
        if isFinal {
            beginTask()
            return
        }
        guard let code = errorCode else { return }
        speechLog.notice("recognition error code \(code, privacy: .public)")
        if code == 201 {
            teardown()
            wantsListening = false
            state = .unavailable(.dictationDisabled)
            return
        }
        // 1110: no speech detected (silence). 216, 301: task canceled. These are routine.
        let routine = [1110, 216, 301].contains(code)
        if !routine {
            let now = Date()
            recentFailures = recentFailures.filter { now.timeIntervalSince($0) < 15 } + [now]
            if recentFailures.count >= 5 {
                teardown()
                wantsListening = false
                state = .unavailable(.failed("error \(code)"))
                return
            }
        }
        beginTask()
    }

    private func teardown() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        if audioEngine.isRunning { audioEngine.stop() }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioBridge.swap(to: nil)?.endAudio()
        task?.cancel()
        task = nil
        audioBridge.resetLevel()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: Audio session events

    private func observeAudioSession() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
            MainActor.assumeIsolated { self?.handleInterruption(began: began) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
                                            object: nil, queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            let inputChanged = reason == .newDeviceAvailable || reason == .oldDeviceUnavailable
            MainActor.assumeIsolated { if inputChanged { self?.restartIfListening() } }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
    }

    private func handleInterruption(began: Bool) {
        guard wantsListening, began else { return }
        teardown()
        wantsListening = false
        state = .interrupted
    }

    /// Restarts only when the microphone really changed. Starting the engine
    /// itself causes route notifications, which must not trigger a restart loop.
    private func restartIfListening() {
        guard wantsListening, state == .listening else { return }
        if let started = engineStartedAt, Date().timeIntervalSince(started) < 1.5 { return }
        let current = audioEngine.inputNode.outputFormat(forBus: 0)
        if let installed = installedFormat,
           current.sampleRate == installed.sampleRate,
           current.channelCount == installed.channelCount {
            return
        }
        startEngine()
    }

    private func handleMediaServicesReset() {
        audioEngine = AVAudioEngine()
        if wantsListening { startEngine() }
    }

    // MARK: Callbacks off the main actor

    /// Built outside the main actor: the tap runs on a real-time audio thread.
    nonisolated private static func makeTapBlock(_ bridge: AudioBridge) -> AVAudioNodeTapBlock {
        { buffer, _ in bridge.append(buffer) }
    }

    nonisolated private static func makeResultHandler(generation: Int, owner: SpeechRecognizer)
        -> (SFSpeechRecognitionResult?, Error?) -> Void {
        { [weak owner] result, error in
            let text = result?.bestTranscription.formattedString
            let isFinal = result?.isFinal ?? false
            let code = (error as NSError?)?.code
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    owner?.handleResult(generation: generation, text: text, isFinal: isFinal, errorCode: code)
                }
            }
        }
    }
}

extension SpeechRecognizer: SFSpeechRecognizerDelegate {
    nonisolated func speechRecognizer(_ speechRecognizer: SFSpeechRecognizer, availabilityDidChange available: Bool) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if !available && self.wantsListening {
                    self.teardown()
                    self.state = .unavailable(.recognizerUnavailable)
                } else if available, case .unavailable(.recognizerUnavailable) = self.state, self.wantsListening {
                    self.startEngine()
                }
            }
        }
    }
}

/// Hands audio buffers from the real-time tap to the current recognition request.
/// Thread-safe; holds no audio beyond the buffer being appended.
private final class AudioBridge: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var smoothedLevel: Float = 0

    var level: Float {
        lock.lock(); defer { lock.unlock() }
        return smoothedLevel
    }

    /// Installs a new request and returns the previous one.
    func swap(to newRequest: SFSpeechAudioBufferRecognitionRequest?) -> SFSpeechAudioBufferRecognitionRequest? {
        lock.lock(); defer { lock.unlock() }
        let old = request
        request = newRequest
        return old
    }

    func resetLevel() {
        lock.lock(); smoothedLevel = 0; lock.unlock()
    }

    func append(_ buffer: AVAudioPCMBuffer) {
        let rms = Self.rms(buffer)
        lock.lock()
        let current = request
        // Map roughly -55...-10 dBFS onto 0...1 and smooth it.
        let db = 20 * log10(max(rms, 0.000_01))
        let normalized = min(max((db + 55) / 45, 0), 1)
        smoothedLevel = smoothedLevel * 0.7 + normalized * 0.3
        lock.unlock()
        current?.append(buffer)
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        for i in 0..<n { sum += data[i] * data[i] }
        return sqrt(sum / Float(n))
    }
}
