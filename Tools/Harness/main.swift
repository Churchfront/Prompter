import UIKit
import SwiftUI
import TeleprompterCore

// Runtime harness: runs the real app code (stores, controller, text surface,
// SwiftUI screens) inside a Mac Catalyst process, drives it like a reader
// would, and renders iPhone- and iPad-sized screenshots.
// Built and launched by Tools/run-app-harness.sh. Not part of the app target.

@MainActor
final class Harness {
    let window: UIWindow
    let root = UIViewController()
    let out: URL
    var failures = 0

    init(window: UIWindow, out: URL) {
        self.window = window
        self.out = out
        root.view.backgroundColor = .black
        window.rootViewController = root
    }

    func check(_ name: String, _ ok: Bool, _ detail: @autoclosure () -> String = "") {
        if !ok { failures += 1 }
        let d = detail()
        print("\(ok ? "PASS" : "FAIL")  \(name)\(d.isEmpty ? "" : "  (\(d))")")
        fflush(stdout)
    }

    func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }

    func freshDefaults() -> UserDefaults {
        let name = "harness.\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }

    func freshDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("harness-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: Hosting

    func host<V: View>(_ view: V, size: CGSize, compact: Bool) -> UIHostingController<V> {
        root.children.forEach { $0.view.removeFromSuperview(); $0.removeFromParent() }
        let hosting = UIHostingController(rootView: view)
        hosting.view.tintColor = UIColor(Signal.accent)
        hosting.traitOverrides.horizontalSizeClass = compact ? .compact : .regular
        hosting.traitOverrides.verticalSizeClass = size.width > size.height && compact ? .compact : .regular
        hosting.traitOverrides.userInterfaceStyle = .dark
        root.addChild(hosting)
        hosting.view.frame = CGRect(origin: .zero, size: size)
        root.view.addSubview(hosting.view)
        hosting.didMove(toParent: root)
        hosting.view.layoutIfNeeded()
        return hosting
    }

    func resize(_ hosting: UIViewController, to size: CGSize, compact: Bool) {
        hosting.traitOverrides.verticalSizeClass = size.width > size.height && compact ? .compact : .regular
        hosting.view.frame = CGRect(origin: .zero, size: size)
        hosting.view.layoutIfNeeded()
    }

    func snapshot(_ view: UIView, _ name: String) {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
        let url = out.appendingPathComponent("\(name).png")
        try? image.pngData()?.write(to: url)
        print("      saved \(name).png")
    }

    func findSurface(in view: UIView) -> PrompterTextSurface? {
        if let s = view as? PrompterTextSurface { return s }
        for sub in view.subviews { if let s = findSurface(in: sub) { return s } }
        return nil
    }

    // MARK: Run

    func run() async {
        print("\nPersistence")
        persistence()
        settingsPersistence()

        print("\nPrompter runtime (iPhone-sized, timed scroll)")
        await prompterRuntime()

        print("\nEdge cases")
        await edgeCases()

        print("\nScreens")
        await screens()

        print("\nPhone remote and iPad display")
        await remoteLink()

        print("\nOpening from a prompter:// link")
        await openLink()

        print(failures == 0 ? "\nAll harness checks passed." : "\n\(failures) harness check(s) failed.")
    }

    // MARK: Persistence

    func persistence() {
        let dir = freshDirectory()
        let defaults = freshDefaults()
        let store = ScriptStore(directory: dir, defaults: defaults)
        check("Sample script is created on first launch",
              store.scripts.count == 1 && store.scripts.first?.title == "Welcome to Prompter")

        let special = "He is risen! 🙌🏽 “Quotes”, dashes, ellipses… and ünïcode.\n\nSecond paragraph; still here."
        let script = store.create(title: "Easter", body: special)
        store.rename(id: script.id, to: "Easter 9 AM")
        let copy = store.duplicate(id: script.id)
        check("Duplicate creates a separate script", copy != nil && copy?.id != script.id && copy?.body == special)
        store.update(id: script.id, title: "Easter 9 AM", body: special + " Edited.")
        store.updateResumePosition(id: script.id, position: 42)
        if let copy { store.delete(id: copy.id) }

        let reloaded = ScriptStore(directory: dir, defaults: defaults)
        let back = reloaded.script(id: script.id)
        check("Scripts survive a relaunch", reloaded.scripts.count == 2)
        check("Edited text with special characters is saved exactly", back?.body == special + " Edited.")
        check("Rename is saved", back?.title == "Easter 9 AM")
        check("Resume position is saved", back?.lastPosition == 42)
        check("Deleted script stays deleted", copy.map { reloaded.script(id: $0.id) == nil } ?? false)

        if let sample = reloaded.scripts.first(where: { $0.title == "Welcome to Prompter" }) {
            reloaded.delete(id: sample.id)
        }
        let again = ScriptStore(directory: dir, defaults: defaults)
        check("Sample is not re-created after the reader deletes it", again.scripts.count == 1)

        try? Data("not json".utf8).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"))
        let withCorrupt = ScriptStore(directory: dir, defaults: defaults)
        let asideCount = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasSuffix(".unreadable") }.count
        check("An unreadable file is set aside, not deleted, and the rest still load",
              withCorrupt.scripts.count == 1 && asideCount == 1)

        let file = dir.appendingPathComponent("Sunday Welcome.txt")
        var bytes = Data("Good morning, church.\r\nWelcome home. Caf".utf8)
        bytes.append(0xE9) // Windows-1252 é
        try? bytes.write(to: file)
        let imported = try? withCorrupt.importFile(at: file)
        check("Plain text import handles CRLF and Windows encodings",
              imported?.title == "Sunday Welcome" && imported?.body == "Good morning, church.\nWelcome home. Café",
              imported?.body ?? "nil")
    }

    func settingsPersistence() {
        let defaults = freshDefaults()
        let a = SettingsStore(defaults: defaults)
        a.settings.fontSize = 60
        a.settings.mode = .timed
        a.settings.mirrorHorizontally = true
        let b = SettingsStore(defaults: defaults)
        check("Preferences are remembered", b.settings.fontSize == 60 && b.settings.mode == .timed && b.settings.mirrorHorizontally)

        defaults.set(Data(#"{"fontSize": 50, "mode": "unknownMode", "futureSetting": true}"#.utf8), forKey: "readerSettings.v1")
        let c = SettingsStore(defaults: defaults)
        check("Unknown or missing settings fall back to defaults without losing the rest",
              c.settings.fontSize == 50 && c.settings.mode == .voiceFollow && c.settings.countdownSeconds == 3)
    }

    // MARK: Prompter runtime

    func makePrompter(body: String, settings: (inout ReaderSettings) -> Void, size: CGSize, compact: Bool)
        -> (PrompterController, UIHostingController<AnyView>, ScriptStore, SettingsStore, Script) {
        let store = ScriptStore(directory: freshDirectory(), defaults: freshDefaults())
        let settingsStore = SettingsStore(defaults: freshDefaults())
        settings(&settingsStore.settings)
        let script = store.create(title: "Harness script", body: body)
        let controller = PrompterController(script: script, settingsStore: settingsStore, scriptStore: store)
        let hub = RemoteHub(scriptStore: store, settingsStore: settingsStore, defaults: freshDefaults())
        let view = AnyView(PrompterView(controller: controller).environment(settingsStore).environment(store).environment(hub))
        let hosting = host(view, size: size, compact: compact)
        return (controller, hosting, store, settingsStore, script)
    }

    func prompterRuntime() async {
        let body = Array(repeating: SampleScript.text, count: 4).joined(separator: "\n\n")
        let phone = CGSize(width: 393, height: 852)
        let (controller, hosting, store, settingsStore, script) = makePrompter(body: body, settings: {
            $0.mode = .timed
            $0.countdownSeconds = 0
            $0.wordsPerMinute = 150
            $0.autoHideControls = false
        }, size: phone, compact: true)
        await wait(0.6)
        guard let surface = findSurface(in: hosting.view) else {
            check("Prompter text view is created", false)
            return
        }
        check("Word geometry is measured for every word", surface.geometry.readingY.count == controller.tokens.count,
              "\(surface.geometry.readingY.count) of \(controller.tokens.count)")
        check("Script is scrollable", surface.maxOffset > 1000, "max offset \(Int(surface.maxOffset)) pt")

        // Time-based scrolling: steady speed that matches words per minute.
        controller.play()
        check("Play starts immediately with no countdown", controller.state == .playing)
        var samples: [(Double, CGFloat)] = []
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < 3.0 {
            samples.append((CACurrentMediaTime() - start, surface.contentOffset.y))
            await wait(1.0 / 60)
        }
        let backward = zip(samples, samples.dropFirst()).filter { $1.1 < $0.1 - 0.01 }.count
        check("Timed scroll never moves backward", backward == 0, "\(backward) backward steps")
        let a = samples.first { $0.0 >= 1.0 }!, b = samples.last!
        let measured = Double(b.1 - a.1) / (b.0 - a.0)
        let expected = 150.0 / 60.0 * surface.geometry.pointsPerWord
        check("Scroll speed matches the words-per-minute setting", abs(measured - expected) / expected < 0.12,
              String(format: "%.1f pt/s measured, %.1f expected", measured, expected))
        let maxStep = zip(samples, samples.dropFirst()).map { Double($1.1 - $0.1) / max($1.0 - $0.0, 0.001) }.max() ?? 0
        check("No sudden jumps while scrolling", maxStep < expected * 2.5, String(format: "fastest frame %.1f pt/s", maxStep))
        snapshot(hosting.view, "prompter-iphone-timed-playing")

        // Speed change while running eases in.
        let beforeChange = surface.contentOffset.y
        settingsStore.settings.wordsPerMinute = 300
        await wait(1.0 / 30)
        let firstFrame = surface.contentOffset.y - beforeChange
        check("Speed change mid-script eases in without a jump", firstFrame < CGFloat(expected * 0.2),
              String(format: "%.1f pt in first frames", firstFrame))
        settingsStore.settings.wordsPerMinute = 150

        // Font size change while playing keeps the place.
        let p0 = surface.geometry.position(forOffset: Double(surface.contentOffset.y))
        settingsStore.settings.fontSize = 64
        await wait(0.15)
        let p1 = surface.geometry.position(forOffset: Double(surface.contentOffset.y))
        check("Font size change while scrolling keeps the reading position", abs(p1 - p0) < 1.5,
              String(format: "word %.1f before, %.1f after", p0, p1))

        // Pause, then rotate.
        controller.handleTap()
        check("Tap pauses", controller.state == .paused)
        await wait(0.3)
        let pausedOffset = surface.contentOffset.y
        await wait(0.5)
        check("Paused text stays put", abs(surface.contentOffset.y - pausedOffset) < 0.01)
        let r0 = surface.geometry.position(forOffset: Double(surface.contentOffset.y))
        resize(hosting, to: CGSize(width: 852, height: 393), compact: true)
        await wait(0.3)
        let r1 = surface.geometry.position(forOffset: Double(surface.contentOffset.y))
        check("Rotation to landscape keeps the reading position", abs(r1 - r0) < 0.6,
              String(format: "word %.2f before, %.2f after", r0, r1))
        snapshot(hosting.view, "prompter-iphone-landscape-paused")
        resize(hosting, to: phone, compact: true)
        await wait(0.3)
        let r2 = surface.geometry.position(forOffset: Double(surface.contentOffset.y))
        check("Rotation back to portrait keeps the reading position", abs(r2 - r0) < 0.6,
              String(format: "word %.2f", r2))

        controller.handleTap()
        check("Tap resumes without a countdown", controller.state == .playing)
        await wait(0.5)
        controller.pause()

        // Sentence jumps.
        let here = Int(surface.geometry.position(forOffset: Double(surface.contentOffset.y)).rounded())
        let nextStart = controller.tokens.nextSentenceStart(after: here) ?? here
        controller.skipForward()
        await wait(1.5)
        let afterSkip = surface.geometry.position(forOffset: Double(surface.contentOffset.y))
        check("Forward jumps to the next sentence", abs(afterSkip - Double(nextStart)) < 0.6,
              String(format: "at word %.1f, sentence starts at %d", afterSkip, nextStart))
        controller.rewind()
        controller.rewind()
        await wait(1.5)
        let afterRewind = surface.geometry.position(forOffset: Double(surface.contentOffset.y))
        check("Rewind moves back by sentences", afterRewind < afterSkip - 3,
              String(format: "word %.1f", afterRewind))

        // Timed mode: one steady scroll, nothing dimmed or highlighted.
        let token = Int(afterRewind.rounded())
        let storage = surface.textStorage
        check("Timed mode runs this section", controller.mode == .timed, "\(controller.mode)")
        if token > 2 {
            let readColor = storage.attribute(.foregroundColor, at: controller.tokens.tokens[token - 2].range.location,
                                              effectiveRange: nil) as? UIColor
            check("Timed mode does not dim text already read", (readColor?.cgColor.alpha ?? 1) > 0.9)
        }
        let phrase = controller.tokens.phraseRange(containing: token)
        let currentColor = storage.attribute(.foregroundColor, at: controller.tokens.tokens[phrase.upperBound - 1].range.location,
                                             effectiveRange: nil) as? UIColor
        check("Timed mode does not highlight the current phrase", currentColor != settingsStore.settings.highlightColor.uiColor)
        check("Timed mode sends no highlight to remote displays",
              controller.currentHighlight.readUpTo == 0 && controller.currentHighlight.current == nil)
        check("Timed mode reports a steady position", controller.timedPosition != nil)

        // Resume position is saved on pause (further into the script than the first sentences).
        for _ in 0..<4 { controller.skipForward(); await wait(1.2) }
        controller.play()
        await wait(0.3)
        controller.pause()
        let at = Int(surface.geometry.position(forOffset: Double(surface.contentOffset.y)).rounded())
        let saved = store.script(id: script.id)?.lastPosition
        check("Pausing saves the resume position", saved != nil && abs((saved ?? 0) - at) <= 1,
              "saved \(saved.map(String.init) ?? "nil"), at \(at)")

        // Restart.
        controller.restart()
        await wait(1.5)
        check("Restart returns to the top", surface.contentOffset.y < 1 && controller.state == .ready,
              "offset \(surface.contentOffset.y)")

        // Mode switch and the voice-follow controls render (no microphone used here).
        controller.setMode(.voiceFollow)
        check("Mode switch to Voice Follow", controller.mode == .voiceFollow && settingsStore.settings.mode == .voiceFollow)
        settingsStore.settings.fontSize = 44
        await wait(0.3)
        snapshot(hosting.view, "prompter-iphone-voice-ready")

        // Mirroring renders.
        settingsStore.settings.mirrorHorizontally = true
        controller.controlsVisible = false
        await wait(0.3)
        snapshot(hosting.view, "prompter-iphone-mirrored")
        settingsStore.settings.mirrorHorizontally = false

        // Timed scroll reaches the end and stops.
        controller.setMode(.timed)
        controller.skipForward()
        settingsStore.settings.wordsPerMinute = 320
        controller.play()
        let endTarget = surface.maxOffset
        surface.setOffset(endTarget - 20)
        controller.userEndedInteraction(at: endTarget - 20)
        await wait(2.0)
        check("Timed scroll stops at the end", controller.state == .finished, "\(controller.state)")
        controller.close()
    }

    func edgeCases() async {
        let (empty, emptyHost, _, _, _) = makePrompter(body: "   \n\n  ", settings: { $0.countdownSeconds = 0; $0.mode = .timed },
                                                      size: CGSize(width: 393, height: 852), compact: true)
        await wait(0.3)
        empty.play()
        check("Empty script does not start", empty.isEmpty && empty.state == .ready)
        snapshot(emptyHost.view, "prompter-empty-script")
        empty.close()

        let long = Array(repeating: SampleScript.text, count: 60).joined(separator: "\n\n")
        let started = CACurrentMediaTime()
        let (big, bigHost, _, _, _) = makePrompter(body: long, settings: {
            $0.countdownSeconds = 0; $0.mode = .timed; $0.wordsPerMinute = 200; $0.autoHideControls = false
        }, size: CGSize(width: 1024, height: 1366), compact: false)
        await wait(0.1)
        let surface = findSurface(in: bigHost.view)
        let ready = CACurrentMediaTime() - started
        check("Very long script (\(big.tokens.count) words) lays out", (surface?.geometry.readingY.count ?? 0) == big.tokens.count,
              String(format: "ready in %.2f s", ready))
        big.play()
        var frames: [CGFloat] = []
        let t0 = CACurrentMediaTime()
        while CACurrentMediaTime() - t0 < 1.5 {
            frames.append(surface?.contentOffset.y ?? 0)
            await wait(1.0 / 60)
        }
        check("Very long script scrolls forward smoothly",
              zip(frames, frames.dropFirst()).allSatisfy { $1 >= $0 - 0.01 } && (frames.last ?? 0) > (frames.first ?? 0))
        big.close()
    }

    // MARK: Screens

    func screens() async {
        let dir = freshDirectory()
        let defaults = freshDefaults()
        let store = ScriptStore(directory: dir, defaults: defaults)
        store.create(title: "Easter Sunday welcome", body: "Good morning, church. He is risen. Today we celebrate the hope that changes everything.\n\nWe are so glad you are here.")
        store.create(title: "Announcements: October", body: "Three quick things before we go. First, the fall retreat registration closes Friday. Second, we need volunteers for the kids ministry check-in team. Third, join us for the baptism Sunday on the 26th.")
        store.create(title: "Video intro: Serve Team", body: "Every Sunday, more than eighty volunteers make this room work. Here is what that looks like behind the scenes.")
        let settingsStore = SettingsStore(defaults: freshDefaults())
        let screensHub = RemoteHub(scriptStore: store, settingsStore: settingsStore, defaults: freshDefaults())

        let phone = CGSize(width: 393, height: 852)
        let pad = CGSize(width: 1024, height: 1366)

        var h: UIViewController = host(LibraryView().environment(store).environment(settingsStore).environment(screensHub), size: phone, compact: true)
        await wait(0.8)
        snapshot(h.view, "library-iphone")
        h = host(LibraryView().environment(store).environment(settingsStore).environment(screensHub), size: pad, compact: false)
        await wait(0.8)
        snapshot(h.view, "library-ipad")

        if let script = store.scripts.first {
            h = host(NavigationStack { EditorView(scriptID: script.id, onPresent: { _ in }) }
                        .environment(store).environment(settingsStore), size: phone, compact: true)
            await wait(0.8)
            snapshot(h.view, "editor-iphone")
        }

        h = host(NavigationStack { SettingsView(context: .library) }.environment(store).environment(settingsStore),
                 size: phone, compact: true)
        await wait(0.8)
        snapshot(h.view, "settings-iphone")

        h = host(SpeechIssueSheet(issue: .microphoneDenied, onUseTimed: {}, onClose: {}), size: phone, compact: true)
        await wait(0.5)
        snapshot(h.view, "voice-permission-denied")

        // iPad landscape prompter with the countdown showing.
        let (controller, padHost, _, _, _) = makePrompter(body: SampleScript.text, settings: {
            $0.mode = .timed; $0.countdownSeconds = 5; $0.autoHideControls = false
        }, size: CGSize(width: 1366, height: 1024), compact: false)
        await wait(0.6)
        snapshot(padHost.view, "prompter-ipad-landscape-ready")
        controller.play()
        await wait(0.3)
        snapshot(padHost.view, "prompter-ipad-countdown")
        controller.pause()
        controller.close()
    }
}

final class HarnessAppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        SignalFont.register()
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 1366, height: 1366))
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        self.window = window
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["HARNESS_OUT"] ?? NSTemporaryDirectory())
        Task { @MainActor in
            let harness = Harness(window: window, out: out)
            if CommandLine.arguments.contains("--serve") {
                // Manual testing: the library with the remote on 7070 and 7071, until quit.
                await harness.serve()
                return
            }
            await harness.run()
            exit(harness.failures == 0 ? 0 : 1)
        }
        return true
    }
}

UIApplicationMain(CommandLine.argc, CommandLine.unsafeArgv, nil, NSStringFromClass(HarnessAppDelegate.self))
