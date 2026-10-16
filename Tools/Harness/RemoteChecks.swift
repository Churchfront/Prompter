import UIKit
import SwiftUI
import TeleprompterCore

// Phone remote and iPad display: runs the real RemoteHub and HTTP server on
// spare ports, presents a real prompter, and drives it over HTTP the way the
// web pages do.

extension Harness {
    struct HTTPResult {
        var status: Int
        var body: String
    }

    func http(_ method: String, _ url: String, json: String? = nil, contentType: String = "application/json") async -> HTTPResult {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = 5
        if let json {
            request.httpBody = Data(json.utf8)
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            return HTTPResult(status: 0, body: "")
        }
        return HTTPResult(status: (response as? HTTPURLResponse)?.statusCode ?? 0,
                          body: String(data: data, encoding: .utf8) ?? "")
    }

    /// Like http, with request headers, and the response headers back.
    func httpHeaders(_ method: String, _ url: String, headers: [String: String], body: String? = nil) async -> (status: Int, body: String, headers: [String: String]) {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = method
        request.timeoutInterval = 5
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        if let body { request.httpBody = Data(body.utf8) }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return (0, "", [:]) }
        var out: [String: String] = [:]
        for (key, value) in http.allHeaderFields { out[String(describing: key).lowercased()] = String(describing: value) }
        return (http.statusCode, String(data: data, encoding: .utf8) ?? "", out)
    }

    func stateJSON(_ base: String) async -> [String: Any] {
        let result = await http("GET", "\(base)/state")
        return (try? JSONSerialization.jsonObject(with: Data(result.body.utf8))) as? [String: Any] ?? [:]
    }

    /// Reads an event stream for a while and returns the event names seen.
    func streamEvents(_ url: String, for seconds: Double) async -> [String] {
        let task = Task { () -> [String] in
            var names: [String] = []
            guard let (bytes, _) = try? await URLSession.shared.bytes(from: URL(string: url)!) else { return names }
            do {
                for try await line in bytes.lines {
                    if line.hasPrefix("event: ") { names.append(String(line.dropFirst(7))) }
                    if Task.isCancelled { break }
                }
            } catch {}
            return names
        }
        let collector = Task { () -> [String] in await task.value }
        await wait(seconds)
        task.cancel()
        return await collector.value
    }

    func remoteLink() async {
        let store = ScriptStore(directory: freshDirectory(), defaults: freshDefaults())
        let settingsStore = SettingsStore(defaults: freshDefaults())
        settingsStore.settings.mode = .timed
        settingsStore.settings.countdownSeconds = 0
        settingsStore.settings.wordsPerMinute = 200
        settingsStore.settings.autoHideControls = false
        let script = store.create(title: "Remote test", body: Array(repeating: SampleScript.text, count: 3).joined(separator: "\n\n"))
        let other = store.create(title: "Second script", body: "A second script for the remote to open.")
        let hub = RemoteHub(scriptStore: store, settingsStore: settingsStore, defaults: freshDefaults())
        hub.setPorts(control: 17070, display: 17071)
        hub.isEnabled = true
        let control = "http://127.0.0.1:17070", display = "http://127.0.0.1:17071"

        for _ in 0..<50 where hub.status != .running { await wait(0.1) }
        check("Both ports open", hub.status == .running, "\(hub.status)")
        check("A network address is found", !hub.addresses.isEmpty, hub.addresses.joined(separator: ", "))

        let remotePage = await http("GET", control + "/")
        let displayPage = await http("GET", display + "/")
        check("Control port serves the phone remote", remotePage.status == 200 && remotePage.body.contains("Prompter Remote"))
        check("Present port serves the display", displayPage.status == 200 && displayPage.body.contains("Prompter Display"))
        let js = await http("GET", display + "/prompter.js")
        let css = await http("GET", control + "/prompter.css")
        let font = await http("GET", display + "/figtree.ttf")
        check("Shared script, styles and font are served", js.status == 200 && css.status == 200 && font.status == 200)
        let traversal = await http("GET", control + "/../Info.plist")
        let unknown = await http("GET", control + "/Info.plist")
        check("Nothing outside the web pages is served", traversal.status == 404 && unknown.status == 404)

        let idle = await stateJSON(control)
        check("With no script open, state says so", idle["session"] as? Bool == false)

        let host = self.host(AnyView(PrompterScreen(script: script)
                                        .environment(store).environment(settingsStore).environment(hub)),
                             size: CGSize(width: 1024, height: 768), compact: false)
        await wait(0.8)
        guard let controller = hub.session else {
            check("Presenting a script attaches it to the remote", false)
            hub.isEnabled = false
            return
        }
        check("Presenting a script attaches it to the remote", true)
        let ready = await stateJSON(display)
        check("Display sees the open script", ready["session"] as? Bool == true && ready["state"] as? String == "ready"
              && ready["scriptID"] as? String == script.id.uuidString)

        let forbidden = await http("POST", display + "/command", json: #"{"action":"toggle"}"#)
        check("Present port refuses commands", forbidden.status == 403 && controller.state == .ready)
        let plain = await http("POST", control + "/command", json: #"{"action":"toggle"}"#, contentType: "text/plain")
        check("Commands without a JSON content type are refused", plain.status == 415 && controller.state == .ready)

        let play = await http("POST", control + "/command", json: #"{"action":"toggle"}"#)
        await wait(0.2)
        check("Play from the phone starts the prompter", play.status == 204 && controller.state == .playing)

        // The display stream: the full picture first, then live positions.
        let names = await streamEvents(display + "/events", for: 1.2)
        let states = names.filter { $0 == "state" }.count
        check("Display stream starts with hello, script, style and state",
              Array(names.prefix(4)) == ["hello", "script", "style", "state"], names.prefix(5).joined(separator: ","))
        check("Display stream sends live positions while playing", states >= 20, "\(states) state events in 1.2 s")
        check("Display stream never sends the library", !names.contains("library"))
        let remoteNames = await streamEvents(control + "/events", for: 0.4)
        check("Remote stream includes the library", remoteNames.contains("library"))

        let moving = await stateJSON(control)
        let position = moving["position"] as? Double ?? -1
        check("Reported position moves forward", position > 1, String(format: "position %.2f", position))

        _ = await http("POST", control + "/command", json: #"{"action":"pause"}"#)
        await wait(0.1)
        check("Pause from the phone", controller.state == .paused)

        _ = await http("POST", control + "/command", json: #"{"action":"seek","value":0.5}"#)
        await wait(1.2)
        let sought = await stateJSON(control)
        let progress = sought["progress"] as? Double ?? 0
        check("Scrubbing jumps to the middle", abs(progress - 0.5) < 0.05, String(format: "progress %.2f", progress))

        let wpm = settingsStore.settings.wordsPerMinute
        _ = await http("POST", control + "/command", json: #"{"action":"speed","value":10}"#)
        check("Speed up from the phone", settingsStore.settings.wordsPerMinute == wpm + 10)

        _ = await http("POST", control + "/command", json: #"{"action":"displayMirror"}"#)
        _ = await http("POST", control + "/command", json: #"{"action":"displayScale","value":0.2}"#)
        check("Display mirror and size change only the display",
              hub.display.mirror && abs(hub.display.scale - 1.2) < 0.001 && !settingsStore.settings.mirrorHorizontally)

        _ = await http("POST", control + "/command", json: #"{"action":"mode","mode":"voiceFollow"}"#)
        check("Mode switch from the phone", controller.mode == .voiceFollow)

        _ = await http("POST", control + "/command", json: "{\"action\":\"open\",\"id\":\"\(other.id.uuidString)\"}")
        check("Picking a script on the phone asks the library to present it", hub.openRequest == other.id)
        let before = hub.closeRequest
        _ = await http("POST", control + "/command", json: #"{"action":"close"}"#)
        check("Close from the phone asks the prompter to close", hub.closeRequest == before + 1)

        // Send to Prompter from the Churchfront portal (POST /import).
        let portal = "https://app.churchfront.com"
        let preflight = await httpHeaders("OPTIONS", control + "/import", headers: [
            "Origin": portal, "Access-Control-Request-Method": "POST",
            "Access-Control-Request-Headers": "content-type", "Access-Control-Request-Private-Network": "true"])
        check("Import preflight approves the portal, including Private Network Access",
              preflight.status == 204 && preflight.headers["access-control-allow-origin"] == portal
                && preflight.headers["access-control-allow-private-network"] == "true",
              "\(preflight.status) \(preflight.headers)")
        let strangerPreflight = await httpHeaders("OPTIONS", control + "/import", headers: ["Origin": "https://example.com"])
        check("Import preflight refuses other websites", strangerPreflight.status == 403)

        let countBefore = store.scripts.count
        let send = #"{"key":"course-1","title":"NET 102 The OSI Model","course":"NET 102","text":"[INTRODUCTION]\r\nIn Networking 101, we covered a lot of ground."}"#
        let sent = await httpHeaders("POST", control + "/import", headers: ["Origin": portal, "Content-Type": "application/json"], body: send)
        let answer = (try? JSONSerialization.jsonObject(with: Data(sent.body.utf8))) as? [String: Any] ?? [:]
        let sentScript = store.script(forSourceKey: "churchfront:course-1")
        check("Import from the portal creates the script and opens it",
              sent.status == 201 && sentScript != nil && hub.openRequest == sentScript?.id
                && sentScript?.body == "[INTRODUCTION]\nIn Networking 101, we covered a lot of ground."
                && sentScript?.source?.isFromNotion == false && store.scripts.count == countBefore + 1,
              "\(sent.status) \(sent.body)")
        check("Import answers with CORS and the display and control addresses",
              sent.headers["access-control-allow-origin"] == portal
                && (answer["display"] as? String)?.hasSuffix(":17071") == true
                && (answer["control"] as? String)?.hasSuffix(":17070") == true,
              "\(answer)")
        let resend = #"{"key":"course-1","title":"NET 102 The OSI Model","text":"Revised script."}"#
        let again = await httpHeaders("POST", control + "/import", headers: ["Origin": portal, "Content-Type": "application/json"], body: resend)
        check("Sending the same course again updates it in place",
              again.status == 200 && store.scripts.count == countBefore + 1
                && store.script(forSourceKey: "churchfront:course-1")?.body == "Revised script.", "\(again.status)")
        let stranger = await httpHeaders("POST", control + "/import", headers: ["Origin": "https://example.com", "Content-Type": "application/json"], body: send)
        check("Import refuses other websites", stranger.status == 403 && store.scripts.count == countBefore + 1)
        if let lan = (answer["control"] as? String) {
            let fromNetwork = await httpHeaders("POST", lan + "/import", headers: ["Origin": portal, "Content-Type": "application/json"], body: send)
            check("Import refuses requests from the network, not this device", fromNetwork.status == 403, "\(fromNetwork.status) via \(lan)")
        }
        let viaDisplay = await httpHeaders("POST", display + "/import", headers: ["Origin": portal, "Content-Type": "application/json"], body: send)
        check("Present port refuses imports", viaDisplay.status == 403)
        let notJSON = await httpHeaders("POST", control + "/import", headers: ["Origin": portal, "Content-Type": "text/plain"], body: send)
        check("Import needs JSON", notJSON.status == 415)

        controller.close()
        hub.detach(controller)
        let after = await stateJSON(display)
        check("Closing the prompter clears the display", after["session"] as? Bool == false)
        _ = host
        hub.isEnabled = false
        await wait(0.2)
        check("Turning the remote off closes the ports", (await http("GET", control + "/")).status == 0)
    }

    /// A prompter:// link (the portal's Send to Teleprompter) turns the ports on.
    func openLink() async {
        let store = ScriptStore(directory: freshDirectory(), defaults: freshDefaults())
        let settingsStore = SettingsStore(defaults: freshDefaults())
        let hub = RemoteHub(scriptStore: store, settingsStore: settingsStore, defaults: freshDefaults())
        hub.setPorts(control: 17170, display: 17171)
        check("Remote starts off", !hub.isEnabled && hub.status == .off)
        check("Other links are not handled", !hub.handleOpenURL(URL(string: "https://app.churchfront.com")!) && !hub.isEnabled)
        check("A prompter:// link is handled", hub.handleOpenURL(URL(string: "prompter://send?from=portal")!))
        for _ in 0..<50 where hub.status != .running { await wait(0.1) }
        let state = await http("GET", "http://127.0.0.1:17170/state")
        check("It turns the phone remote and iPad display on", hub.isEnabled && hub.status == .running && state.status == 200, "\(hub.status)")
        hub.handleOpenURL(URL(string: "PROMPTER://open")!)
        await wait(0.3)
        check("Opening it again while running changes nothing", hub.status == .running)
        hub.isEnabled = false
    }

    /// Runs the library with the remote on its default ports until the process is quit.
    func serve() async {
        let store = ScriptStore(directory: freshDirectory(), defaults: freshDefaults())
        store.create(title: "Easter Sunday welcome", body: "[WALK TO CENTER]\nGood morning, church. He is risen! Today we celebrate the hope that changes everything.\n\nWe are so glad you are here. If this is your first time with us, welcome. Stop by the welcome center after the service, we would love to meet you.\n\n[PAUSE]\nLet's pray together.")
        let settingsStore = SettingsStore(defaults: freshDefaults())
        settingsStore.settings.mode = .timed
        let hub = RemoteHub(scriptStore: store, settingsStore: settingsStore, defaults: freshDefaults())
        // "--serve 18070" serves on 18070 and 18071, beside an installed Prompter on the defaults.
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--serve"), i + 1 < args.count, let port = UInt16(args[i + 1]) {
            hub.setPorts(control: port, display: port + 1)
        }
        hub.isEnabled = true
        _ = host(LibraryView().environment(store).environment(settingsStore).environment(hub),
                 size: CGSize(width: 1024, height: 768), compact: false)
        for _ in 0..<50 where hub.status != .running { await wait(0.1) }
        print("Serving. Remote: \(hub.controlURL ?? "-") Display: \(hub.displayURL ?? "-") Status: \(hub.status)")
        fflush(stdout)
        while true { await wait(3600) }
    }
}
