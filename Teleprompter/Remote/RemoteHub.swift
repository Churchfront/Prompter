import Foundation
import QuartzCore
import Observation
import TeleprompterCore

/// Preferences for the remote display screen only (an iPad under beam-splitter
/// glass, for example), kept apart from the host's own reading settings.
struct DisplayOptions: Codable, Equatable {
    var mirror = false
    var flip = false
    /// Text size on the display relative to the host's size.
    var scale: Double = 1

    static let scaleRange: ClosedRange<Double> = 0.5...2.5
}

/// Runs the phone remote and the display link.
///
/// Two ports on this device's address:
/// - control (default 7070): the phone remote page. It sees the library and the
///   live session and sends commands.
/// - display (default 7071): a read-only prompter page for an iPad or any other
///   screen. It renders the script itself and follows the host's reading position.
///
/// The host stays the source of truth. Voice Follow, timing and position all run
/// here; the pages only mirror and command it.
@MainActor
@Observable
final class RemoteHub {
    enum Status: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    static let defaultControlPort: UInt16 = 7070
    static let defaultDisplayPort: UInt16 = 7071

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.enabled)
            isEnabled ? start() : stop()
        }
    }

    private(set) var controlPort: UInt16
    private(set) var displayPort: UInt16
    private(set) var status: Status = .off
    private(set) var addresses: [String] = []
    private(set) var remoteCount = 0
    private(set) var displayCount = 0

    var display: DisplayOptions {
        didSet {
            guard display != oldValue else { return }
            if let data = try? JSONEncoder().encode(display) { defaults.set(data, forKey: Keys.display) }
            pushStyle()
        }
    }

    /// Script the remote asked to present. The library opens it and clears this.
    var openRequest: UUID?
    /// Changes when the remote asks to close the prompter.
    private(set) var closeRequest = 0

    var controlURL: String? { addresses.first.map { "http://\($0):\(controlPort)" } }
    var displayURL: String? { addresses.first.map { "http://\($0):\(displayPort)" } }

    @ObservationIgnored private let scriptStore: ScriptStore
    @ObservationIgnored private let settingsStore: SettingsStore
    @ObservationIgnored private let defaults: UserDefaults
    /// The open prompter, if any.
    @ObservationIgnored private(set) weak var session: PrompterController?
    @ObservationIgnored private var control: RemoteHTTPServer?
    @ObservationIgnored private var displayServer: RemoteHTTPServer?
    @ObservationIgnored private var serverStatus: [RemoteRole: RemoteHTTPServer.Status] = [:]
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var ticks = 0
    @ObservationIgnored private var lastState = ""
    @ObservationIgnored private var lastStyle = ""
    @ObservationIgnored private var lastLibrary = ""
    @ObservationIgnored private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private enum Keys {
        static let enabled = "remote.enabled"
        static let controlPort = "remote.controlPort"
        static let displayPort = "remote.displayPort"
        static let display = "remote.display"
    }

    init(scriptStore: ScriptStore, settingsStore: SettingsStore, defaults: UserDefaults = .standard) {
        self.scriptStore = scriptStore
        self.settingsStore = settingsStore
        self.defaults = defaults
        let storedControl = defaults.integer(forKey: Keys.controlPort)
        let storedDisplay = defaults.integer(forKey: Keys.displayPort)
        controlPort = (1024...65535).contains(storedControl) ? UInt16(storedControl) : Self.defaultControlPort
        displayPort = (1024...65535).contains(storedDisplay) ? UInt16(storedDisplay) : Self.defaultDisplayPort
        if let data = defaults.data(forKey: Keys.display),
           let stored = try? JSONDecoder().decode(DisplayOptions.self, from: data) {
            display = stored
        } else {
            display = DisplayOptions()
        }
        isEnabled = defaults.bool(forKey: Keys.enabled)
        if isEnabled { start() }
    }

    // MARK: Lifecycle

    /// Changes the ports. Ports must differ and sit above 1023 (no special privileges needed).
    func setPorts(control newControl: UInt16, display newDisplay: UInt16) {
        guard newControl != newDisplay, newControl > 1023, newDisplay > 1023 else { return }
        guard newControl != controlPort || newDisplay != displayPort else { return }
        controlPort = newControl
        displayPort = newDisplay
        defaults.set(Int(newControl), forKey: Keys.controlPort)
        defaults.set(Int(newDisplay), forKey: Keys.displayPort)
        if isEnabled {
            stop()
            start()
        }
    }

    func refreshAddresses() {
        addresses = LocalNetwork.addresses()
    }

    private func start() {
        stop()
        refreshAddresses()
        status = .starting
        let control = RemoteHTTPServer(role: .control, port: controlPort)
        let displayServer = RemoteHTTPServer(role: .display, port: displayPort)
        for server in [control, displayServer] {
            let role = server.role
            server.handler = { [weak self] request in
                self?.handle(request, role: role) ?? .notFound
            }
            server.onStatus = { [weak self] status, clients in
                self?.serverChanged(role: role, status: status, clients: clients)
            }
            server.start()
        }
        self.control = control
        self.displayServer = displayServer
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        control?.stop()
        displayServer?.stop()
        control = nil
        displayServer = nil
        serverStatus = [:]
        remoteCount = 0
        displayCount = 0
        status = .off
        lastState = ""
        lastStyle = ""
        lastLibrary = ""
    }

    private func serverChanged(role: RemoteRole, status newStatus: RemoteHTTPServer.Status, clients: Int) {
        // Late reports from a server that was already replaced are ignored.
        guard isEnabled, (role == .control ? control : displayServer) != nil else { return }
        serverStatus[role] = newStatus
        if role == .control { remoteCount = clients } else { displayCount = clients }
        let all = [serverStatus[.control], serverStatus[.display]]
        if let failure = all.compactMap({ s -> String? in if case .failed(let m) = s { return m }; return nil }).first {
            status = .failed(failure)
        } else if all.allSatisfy({ $0 == .running }) {
            status = .running
        } else {
            status = .starting
        }
    }

    // MARK: Session

    /// The prompter opened. The pages switch to this script.
    func attach(_ controller: PrompterController) {
        session = controller
        pushScript()
        pushState(force: true)
    }

    /// The prompter closed.
    func detach(_ controller: PrompterController) {
        guard session === controller else { return }
        session = nil
        pushScript()
        pushState(force: true)
    }

    // MARK: Requests

    private func handle(_ request: RemoteRequest, role: RemoteRole) -> RemoteResponse {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            return WebAssets.response(for: role == .control ? "remote.html" : "display.html")
        case ("GET", "/events"):
            var events = [frame("hello", HelloPayload(role: role.rawValue)),
                          frame("script", scriptPayload()),
                          frame("style", stylePayload()),
                          frame("state", statePayload())]
            if role == .control { events.append(frame("library", libraryPayload())) }
            return .stream(events)
        case ("GET", "/state"):
            return .json(Data(json(statePayload()).utf8))
        case ("OPTIONS", "/import"):
            // The browser's preflight for Send to Prompter on the Churchfront portal.
            guard role == .control, let origin = Self.portalOrigin(request) else {
                return .text("Not allowed.", status: 403)
            }
            var response = RemoteResponse(status: 204)
            response.headers = Self.corsHeaders(origin)
            response.headers["Access-Control-Allow-Methods"] = "POST"
            response.headers["Access-Control-Allow-Headers"] = "Content-Type"
            // Chrome's Private Network Access: a public site reaching localhost.
            response.headers["Access-Control-Allow-Private-Network"] = "true"
            response.headers["Access-Control-Max-Age"] = "600"
            return response
        case ("POST", "/import"):
            return importScript(request, role: role)
        case ("POST", "/command"):
            guard role == .control else { return .text("This port is display only.", status: 403) }
            // A JSON content type makes browsers preflight cross-site requests,
            // which this server never approves, so other web pages cannot send commands.
            guard request.headers["content-type"]?.hasPrefix("application/json") == true else {
                return .text("Send application/json.", status: 415)
            }
            guard let command = try? JSONDecoder().decode(RemoteCommand.self, from: request.body) else {
                return .text("Unreadable command.", status: 400)
            }
            perform(command)
            return RemoteResponse(status: 204)
        case ("GET", _):
            return WebAssets.response(for: String(request.path.dropFirst()))
        default:
            return .text("Method not allowed.", status: 405)
        }
    }

    // MARK: Import from the Churchfront portal

    /// Web pages allowed to send scripts: the portal, its Vercel previews, and local development.
    static func isPortalOrigin(_ origin: String) -> Bool {
        guard let url = URL(string: origin), let host = url.host?.lowercased() else { return false }
        switch url.scheme {
        case "https":
            return host == "app.churchfront.com" || (host.hasPrefix("churchfront-portal-") && host.hasSuffix("-churchfront.vercel.app"))
        case "http":
            return host == "localhost" || host == "127.0.0.1"
        default:
            return false
        }
    }

    /// The request's Origin when it is the portal.
    private static func portalOrigin(_ request: RemoteRequest) -> String? {
        guard let origin = request.headers["origin"], isPortalOrigin(origin) else { return nil }
        return origin
    }

    private static func corsHeaders(_ origin: String) -> [String: String] {
        ["Access-Control-Allow-Origin": origin, "Vary": "Origin"]
    }

    /// POST /import: Curriculum Studio's Send to Prompter. Only from this device
    /// (the portal open in a browser on the Mac running Prompter) and, from a
    /// browser, only from the portal. Creates or updates the script for that
    /// course, opens it, and answers with the display and control addresses so
    /// the portal can show them to an iPad and a phone.
    private func importScript(_ request: RemoteRequest, role: RemoteRole) -> RemoteResponse {
        let origin = request.headers["origin"]
        var headers: [String: String] = [:]
        if let origin, Self.isPortalOrigin(origin) { headers = Self.corsHeaders(origin) }
        func fail(_ message: String, _ status: Int) -> RemoteResponse {
            var response = RemoteResponse.text(message, status: status)
            response.headers = headers
            return response
        }
        guard role == .control else { return fail("This port is display only.", 403) }
        guard request.fromLoopback else { return fail("Scripts can only be sent from this device.", 403) }
        if let origin, !Self.isPortalOrigin(origin) { return fail("Not allowed.", 403) }
        guard request.headers["content-type"]?.hasPrefix("application/json") == true else {
            return fail("Send application/json.", 415)
        }
        guard let payload = try? JSONDecoder().decode(ImportPayload.self, from: request.body),
              !payload.key.isEmpty, !payload.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return fail("Unreadable script.", 400)
        }
        let title = payload.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = ScriptSource(key: "churchfront:\(payload.key)", notionPageID: "",
                                  courseName: payload.course ?? title, lessonTitle: title,
                                  importedAt: .now, origin: "churchfront")
        let result = scriptStore.upsertImported(title: title, body: ScriptStore.normalizeLineEndings(payload.text), source: source)
        openRequest = result.script.id
        pushLibrary()
        let answer = ImportResult(id: result.script.id.uuidString, title: result.script.displayTitle,
                                  created: result.created, control: controlURL, display: displayURL)
        var response = RemoteResponse.json(Data(json(answer).utf8), status: result.created ? 201 : 200)
        response.headers = headers
        return response
    }

    func perform(_ command: RemoteCommand) {
        switch command.action {
        case "open":
            if let id = command.id.flatMap(UUID.init(uuidString:)), scriptStore.script(id: id) != nil {
                openRequest = id
            }
        case "close":
            if session != nil { closeRequest += 1 }
        case "displayMirror":
            display.mirror.toggle()
        case "displayFlip":
            display.flip.toggle()
        case "displayScale":
            display.scale = ((display.scale + (command.value ?? 0)) * 100).rounded() / 100
            display.scale = display.scale.clamped(to: DisplayOptions.scaleRange)
        case "fontSize":
            settingsStore.settings.fontSize = (settingsStore.settings.fontSize + (command.value ?? 0))
                .clamped(to: ReaderSettings.fontSizeRange)
            session?.settingsDidChange()
        default:
            guard let session else { return }
            switch command.action {
            case "toggle": session.togglePlay()
            case "play": if !session.state.isRunning { session.play() }
            case "pause": session.pause()
            case "rewind": session.rewind()
            case "skip": session.skipForward()
            case "restart": session.restart()
            case "speed": session.adjustSpeed(by: command.value ?? 0)
            case "mode":
                session.setMode(command.mode == PrompterMode.timed.rawValue ? .timed : .voiceFollow)
            case "mirror": session.toggleMirror()
            case "seek": session.seek(toProgress: command.value ?? 0)
            default: break
            }
            session.settingsDidChange()
        }
        pushStyle()
        pushState(force: true)
    }

    // MARK: Broadcasting

    private func tick() {
        ticks += 1
        guard remoteCount + displayCount > 0 else { return }
        pushState(force: false)
        if ticks % 10 == 0 { pushStyle() }
        if ticks % 30 == 0 { pushLibrary() }
    }

    private func pushScript() {
        let event = json(scriptPayload())
        control?.broadcast(event: "script", json: event)
        displayServer?.broadcast(event: "script", json: event)
    }

    private func pushState(force: Bool) {
        let event = json(statePayload())
        guard force || event != lastState else { return }
        lastState = event
        control?.broadcast(event: "state", json: event)
        displayServer?.broadcast(event: "state", json: event)
    }

    private func pushStyle() {
        let event = json(stylePayload())
        guard event != lastStyle else { return }
        lastStyle = event
        control?.broadcast(event: "style", json: event)
        displayServer?.broadcast(event: "style", json: event)
    }

    private func pushLibrary() {
        let event = json(libraryPayload())
        guard event != lastLibrary else { return }
        lastLibrary = event
        control?.broadcast(event: "library", json: event)
    }

    private func json<T: Encodable>(_ value: T) -> String {
        (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func frame<T: Encodable>(_ event: String, _ value: T) -> String {
        "event: \(event)\ndata: \(json(value))\n\n"
    }

    // MARK: Payloads

    func scriptPayload() -> ScriptPayload {
        guard let session else { return ScriptPayload() }
        var tokens: [Int] = []
        tokens.reserveCapacity(session.tokens.count * 2)
        for token in session.tokens.tokens { tokens += [token.range.location, token.range.length] }
        return ScriptPayload(id: session.scriptID.uuidString, title: session.title, text: session.text,
                             tokens: tokens,
                             cues: session.tokens.cueRanges.flatMap { [$0.location, $0.length] })
    }

    func statePayload() -> StatePayload {
        let s = settingsStore.settings
        guard let session else {
            return StatePayload(session: false, mode: s.mode.rawValue, wordsPerMinute: s.wordsPerMinute)
        }
        var payload = StatePayload(session: true, mode: session.mode.rawValue, wordsPerMinute: s.wordsPerMinute)
        payload.scriptID = session.scriptID.uuidString
        switch session.state {
        case .ready: payload.state = "ready"
        case .countingDown(let n): payload.state = "countdown"; payload.countdown = n
        case .playing: payload.state = "playing"
        case .paused: payload.state = "paused"
        case .finished: payload.state = "finished"
        }
        payload.position = (session.readingPosition * 1000).rounded() / 1000
        payload.progress = (session.progress * 1000).rounded() / 1000
        payload.remaining = Int(session.remaining)
        payload.tracking = "\(session.tracking)"
        let highlight = session.currentHighlight
        payload.readUpTo = highlight.readUpTo
        payload.current = highlight.current.map { [$0.lowerBound, $0.upperBound] }
        payload.mirror = s.mirrorHorizontally
        return payload
    }

    func stylePayload() -> StylePayload {
        let s = settingsStore.settings
        return StylePayload(typeface: s.typeface.rawValue, weight: Int(s.weight.value), fontSize: s.fontSize,
                            lineSpacing: s.lineSpacing, alignment: s.alignment.rawValue,
                            margin: s.horizontalMargin, readingLine: s.readingLine,
                            marker: s.showReadingMarker, textColor: s.textColor.cssHex,
                            backgroundColor: s.backgroundColor.cssHex, highlightColor: s.highlightColor.cssHex,
                            highlightMode: s.highlightMode.rawValue, dimReadText: s.dimReadText,
                            display: display)
    }

    func libraryPayload() -> LibraryPayload {
        LibraryPayload(scripts: scriptStore.scripts.map {
            LibraryPayload.Item(id: $0.id.uuidString, title: $0.displayTitle, words: $0.wordCount,
                                isEmpty: $0.isEmpty)
        })
    }
}

// MARK: - Wire format

struct RemoteCommand: Decodable {
    var action: String
    var value: Double?
    var id: String?
    var mode: String?
}

struct HelloPayload: Encodable {
    var role: String
    var app = "Prompter"
    var version = 1
}

struct ScriptPayload: Encodable {
    var id: String?
    var title = ""
    var text = ""
    /// UTF-16 location and length of each spoken word, flattened.
    var tokens: [Int] = []
    /// UTF-16 location and length of each stage direction, flattened.
    var cues: [Int] = []
}

struct StatePayload: Encodable {
    var session: Bool
    var mode: String
    var wordsPerMinute: Double
    var scriptID: String?
    var state = "idle"
    var countdown: Int?
    /// Fractional token at the reading line.
    var position: Double = -1
    var progress: Double = 0
    var remaining = 0
    var tracking = "off"
    var readUpTo = 0
    var current: [Int]?
    var mirror = false
}

struct StylePayload: Encodable {
    var typeface: String
    var weight: Int
    var fontSize: Double
    var lineSpacing: Double
    var alignment: String
    var margin: Double
    var readingLine: Double
    var marker: Bool
    var textColor: String
    var backgroundColor: String
    var highlightColor: String
    var highlightMode: String
    var dimReadText: Bool
    var display: DisplayOptions
}

struct LibraryPayload: Encodable {
    struct Item: Encodable {
        var id: String
        var title: String
        var words: Int
        var isEmpty: Bool
    }
    var scripts: [Item]
}

extension RGBAColor {
    var cssHex: String {
        func byte(_ v: Double) -> Int { Int((v.clamped(to: 0...1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }
}

/// Body of POST /import from the Churchfront portal.
struct ImportPayload: Decodable {
    /// The portal's course id: sending the same course again updates its script.
    var key: String
    var title: String
    var course: String?
    var text: String
}

/// Answer to POST /import: the script, and where an iPad (display) and a phone (control) open it.
struct ImportResult: Encodable {
    var id: String
    var title: String
    var created: Bool
    var control: String?
    var display: String?
}
