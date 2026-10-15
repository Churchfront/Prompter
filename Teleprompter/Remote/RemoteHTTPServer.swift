import Foundation
import Network

/// What a port is for. The control port serves the phone remote and accepts
/// commands. The display port serves the read-only prompter page for an iPad
/// (or any screen) and never accepts commands.
enum RemoteRole: String, Sendable {
    case control
    case display
}

struct RemoteRequest: Sendable {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var body: Data
}

struct RemoteResponse: Sendable {
    var status: Int = 200
    var contentType = "text/plain; charset=utf-8"
    var body = Data()
    /// Keeps the connection open as a Server-Sent Events stream, starting with these events.
    var streamEvents: [String]?

    static func text(_ string: String, status: Int = 200) -> RemoteResponse {
        RemoteResponse(status: status, body: Data(string.utf8))
    }

    static func json(_ data: Data, status: Int = 200) -> RemoteResponse {
        RemoteResponse(status: status, contentType: "application/json; charset=utf-8", body: data)
    }

    static func stream(_ initial: [String]) -> RemoteResponse {
        RemoteResponse(contentType: "text/event-stream", streamEvents: initial)
    }

    static let notFound = text("Not found", status: 404)
}

/// A small HTTP/1.1 server on one port, built on Network.framework.
///
/// Plain requests are answered and closed. `GET /events` stays open as a
/// Server-Sent Events stream that `broadcast` writes to. Commands arrive as
/// `POST` requests. SSE plus POST needs no WebSocket framing and works in
/// every browser, including Safari on iPad.
final class RemoteHTTPServer: @unchecked Sendable {
    enum Status: Equatable, Sendable {
        case starting
        case running
        case failed(String)
        case stopped
    }

    let role: RemoteRole
    let port: UInt16

    /// Answers a request. Runs on the main actor.
    var handler: (@MainActor (RemoteRequest) -> RemoteResponse)?
    /// Reports listener status and stream client count changes. Runs on the main actor.
    var onStatus: (@MainActor (Status, Int) -> Void)?

    private let queue: DispatchQueue
    private var listener: NWListener?
    private var streams: [ObjectIdentifier: NWConnection] = [:]
    private var heartbeat: DispatchSourceTimer?
    private var status: Status = .stopped

    private static let maxRequestBytes = 1 << 20

    init(role: RemoteRole, port: UInt16) {
        self.role = role
        self.port = port
        queue = DispatchQueue(label: "com.churchfront.prompter.remote.\(role.rawValue)")
    }

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            guard let nwPort = NWEndpoint.Port(rawValue: port) else {
                report(.failed("Port \(port) is not valid."))
                return
            }
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            do {
                let listener = try NWListener(using: parameters, on: nwPort)
                listener.stateUpdateHandler = { [weak self] state in self?.listenerChanged(state) }
                listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
                self.listener = listener
                report(.starting)
                listener.start(queue: queue)
                startHeartbeat()
            } catch {
                report(.failed("Port \(port) could not open: \(error.localizedDescription)"))
            }
        }
    }

    func stop() {
        queue.async { [self] in
            heartbeat?.cancel()
            heartbeat = nil
            for connection in streams.values { connection.cancel() }
            streams.removeAll()
            listener?.cancel()
            listener = nil
            report(.stopped)
        }
    }

    /// Sends one event to every open stream.
    func broadcast(event: String, json: String) {
        let frame = Data("event: \(event)\ndata: \(json)\n\n".utf8)
        queue.async { [self] in
            for connection in streams.values { send(frame, on: connection) }
        }
    }

    // MARK: Listener

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            report(.running)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            if case .posix(let code) = error, code == .EADDRINUSE {
                report(.failed("Port \(port) is already in use by another app."))
            } else {
                report(.failed("Port \(port) stopped: \(error.localizedDescription)"))
            }
        case .cancelled:
            break
        default:
            break
        }
    }

    private func report(_ newStatus: Status) {
        status = newStatus
        let count = streams.count
        let callback = onStatus
        Task { @MainActor in callback?(newStatus, count) }
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 15, repeating: 15)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let ping = Data(": ping\n\n".utf8)
            for connection in self.streams.values { self.send(ping, on: connection) }
        }
        timer.resume()
        heartbeat = timer
    }

    // MARK: Connections

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            switch state {
            case .failed, .cancelled:
                self.dropStream(connection)
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if error != nil || buffer.count > Self.maxRequestBytes {
                connection.cancel()
                return
            }
            if let request = Self.parse(buffer) {
                self.dispatch(request, on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func dispatch(_ request: RemoteRequest, on connection: NWConnection) {
        let handler = handler
        Task { @MainActor [weak self] in
            let response = handler?(request) ?? .notFound
            self?.queue.async { self?.respond(response, on: connection) }
        }
    }

    private func respond(_ response: RemoteResponse, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        head += "Content-Type: \(response.contentType)\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "X-Content-Type-Options: nosniff\r\n"
        if let events = response.streamEvents {
            head += "Connection: keep-alive\r\n\r\n"
            var data = Data(head.utf8)
            data.append(Data("retry: 1000\n\n".utf8))
            for event in events { data.append(Data(event.utf8)) }
            streams[ObjectIdentifier(connection)] = connection
            send(data, on: connection)
            report(status)
        } else {
            head += "Content-Length: \(response.body.count)\r\nConnection: close\r\n\r\n"
            var data = Data(head.utf8)
            data.append(response.body)
            connection.send(content: data, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func send(_ data: Data, on connection: NWConnection) {
        connection.send(content: data, completion: .contentProcessed { [weak self, weak connection] error in
            guard error != nil, let self, let connection else { return }
            connection.cancel()
            self.dropStream(connection)
        })
    }

    private func dropStream(_ connection: NWConnection) {
        if streams.removeValue(forKey: ObjectIdentifier(connection)) != nil {
            report(status)
        }
    }

    // MARK: Parsing

    /// A complete request from the buffer, or nil if more bytes are needed.
    static func parse(_ buffer: Data) -> RemoteRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headEnd = buffer.range(of: separator) else { return nil }
        guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
            return RemoteRequest(method: "BAD", path: "/", query: [:], headers: [:], body: Data())
        }
        var lines = head.components(separatedBy: "\r\n")
        let requestLine = lines.removeFirst().split(separator: " ")
        guard requestLine.count >= 2 else {
            return RemoteRequest(method: "BAD", path: "/", query: [:], headers: [:], body: Data())
        }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyStart = headEnd.upperBound
        guard buffer.distance(from: bodyStart, to: buffer.endIndex) >= length else { return nil }
        let body = Data(buffer[bodyStart..<buffer.index(bodyStart, offsetBy: length)])

        let target = String(requestLine[1])
        let components = URLComponents(string: target)
        var query: [String: String] = [:]
        for item in components?.queryItems ?? [] { query[item.name] = item.value ?? "" }
        return RemoteRequest(method: String(requestLine[0]).uppercased(),
                             path: components?.path.isEmpty == false ? components!.path : "/",
                             query: query, headers: headers, body: body)
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 400: "Bad Request"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 415: "Unsupported Media Type"
        default: "Status"
        }
    }
}

/// IPv4 addresses other devices on the network can reach this one at, Wi-Fi and Ethernet first.
enum LocalNetwork {
    static func addresses() -> [String] {
        var results: [(name: String, address: String)] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = pointer {
            defer { pointer = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = String(cString: host)
            guard !address.hasPrefix("169.254.") else { continue }
            results.append((String(cString: entry.pointee.ifa_name), address))
        }
        // en0/en1 are Wi-Fi and Ethernet on Apple devices; bridges and VPNs go last.
        return results
            .sorted { a, b in
                let ra = a.name.hasPrefix("en") ? 0 : 1, rb = b.name.hasPrefix("en") ? 0 : 1
                return ra != rb ? ra < rb : a.name < b.name
            }
            .map(\.address)
            .reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }
}
