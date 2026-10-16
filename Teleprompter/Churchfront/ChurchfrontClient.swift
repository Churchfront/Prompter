import AuthenticationServices
import CryptoKit
import Foundation
import Security
import UIKit

/// A script in the Churchfront portal (Curriculum Studio or Content Studio).
struct PortalScript: Identifiable, Hashable, Decodable {
    let key: String
    let title: String
    let course: String
    let source: String
    let phase: String
    let updatedAt: Date?
    let words: Int

    var id: String { key }
    var isReadyToFilm: Bool { phase == "ready_to_film" }

    /// The portal's workflow column, as the portal names it.
    var phaseLabel: String {
        switch phase {
        case "ready_to_film": "Ready to film"
        case "pre_production": "Pre-production"
        case "post_production": "Post-production"
        case "scheduled": "Scheduled"
        case "published": "Published"
        default: phase.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    enum CodingKeys: String, CodingKey { case key, title, course, source, phase, updatedAt = "updated_at", words }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        title = try c.decode(String.self, forKey: .title)
        course = (try? c.decode(String.self, forKey: .course)) ?? ""
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
        phase = (try? c.decode(String.self, forKey: .phase)) ?? ""
        words = (try? c.decode(Int.self, forKey: .words)) ?? 0
        updatedAt = (try? c.decode(String.self, forKey: .updatedAt)).flatMap(ChurchfrontClient.parseDate)
    }
}

struct PortalScriptText: Decodable {
    let key: String
    let title: String
    let course: String
    let text: String
}

enum ChurchfrontError: LocalizedError, Equatable {
    case notSignedIn
    case cancelled
    case notStaff
    case notFound
    case network(String)
    case server(Int, String)
    case signIn(String)

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to Churchfront first."
        case .cancelled: "Sign-in was cancelled."
        case .notStaff: "Portal scripts are for Churchfront staff. This account is not a staff account."
        case .notFound: "That script is no longer in the portal."
        case .network(let detail): "Churchfront could not be reached (\(detail)). Check the internet connection and try again."
        case .server(let code, let message): "The portal returned an error (\(code)): \(message)"
        case .signIn(let detail): "Sign-in did not finish: \(detail)"
        }
    }
}

/// Signs in to the Churchfront portal and downloads scripts. Sign-in uses the
/// portal's OAuth server (the one the Churchfront connector uses): discovery
/// from the portal, dynamic client registration once per device, then the
/// authorization code flow with PKCE in a system sign-in sheet. Tokens live in
/// the Keychain and refresh on their own. Read only: nothing is ever sent back.
@MainActor
final class ChurchfrontClient: NSObject {
    static let shared = ChurchfrontClient()

    /// The portal. A test build can point elsewhere with the launch argument
    /// `-churchfrontPortalURL https://…` (read through UserDefaults).
    static var portal: URL {
        if let text = UserDefaults.standard.string(forKey: "churchfrontPortalURL"),
           let url = URL(string: text), url.scheme == "https" || url.host == "localhost" {
            return url
        }
        return URL(string: "https://app.churchfront.com")!
    }

    static let callbackScheme = "prompter"
    static var redirectURI: String { portal.appendingPathComponent("api/prompter/callback").absoluteString }

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        return URLSession(configuration: config)
    }()
    private var authSession: ASWebAuthenticationSession?

    static var isSignedIn: Bool { ChurchfrontTokenStore.load()?.portal == portal.absoluteString }

    static func signOut() { ChurchfrontTokenStore.delete() }

    // MARK: Sign in

    func signIn() async throws {
        let server = try await authorizationServer()
        let clientID = try await registeredClient(server)
        let verifier = Self.randomString(48)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        let state = Self.randomString(24)

        var components = URLComponents(url: server.authorization, resolvingAgainstBaseURL: false)!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "state", value: state)
        ]
        guard let authorizeURL = components.url else { throw ChurchfrontError.signIn("bad sign-in address") }

        let callback = try await presentSignIn(authorizeURL)
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        if let error = value("error") {
            throw error == "access_denied" ? ChurchfrontError.cancelled : ChurchfrontError.signIn(value("error_description") ?? error)
        }
        guard value("state") == state, let code = value("code") else { throw ChurchfrontError.signIn("the portal's answer did not match") }

        let tokens = try await tokenRequest(server.token, [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier
        ])
        try ChurchfrontTokenStore.save(ChurchfrontTokens(
            portal: Self.portal.absoluteString, tokenEndpoint: server.token.absoluteString, clientID: clientID,
            accessToken: tokens.accessToken, refreshToken: tokens.refreshToken,
            expiresAt: Date.now.addingTimeInterval(tokens.expiresIn ?? 3600)))
        // Confirm the account is staff now rather than on the first download.
        _ = try await scripts()
    }

    private func presentSignIn(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let auth = ASWebAuthenticationSession(url: url, callbackURLScheme: Self.callbackScheme) { callback, error in
                if let callback { continuation.resume(returning: callback); return }
                if let error = error as? ASWebAuthenticationSessionError, error.code == .canceledLogin {
                    continuation.resume(throwing: ChurchfrontError.cancelled)
                } else {
                    continuation.resume(throwing: ChurchfrontError.signIn(error?.localizedDescription ?? "no answer"))
                }
            }
            auth.presentationContextProvider = self
            authSession = auth
            if !auth.start() { continuation.resume(throwing: ChurchfrontError.signIn("the sign-in sheet could not open")) }
        }
    }

    // MARK: Scripts

    func scripts() async throws -> [PortalScript] {
        let data = try await get("api/prompter/scripts")
        struct List: Decodable { let scripts: [PortalScript] }
        do { return try JSONDecoder().decode(List.self, from: data).scripts } catch {
            throw ChurchfrontError.server(200, "the script list could not be read")
        }
    }

    func script(key: String) async throws -> PortalScriptText {
        var components = URLComponents()
        components.path = "api/prompter/script"
        components.queryItems = [URLQueryItem(name: "key", value: key)]
        let data = try await get(components.string ?? "")
        do { return try JSONDecoder().decode(PortalScriptText.self, from: data) } catch {
            throw ChurchfrontError.server(200, "the script could not be read")
        }
    }

    private func get(_ path: String, retried: Bool = false) async throws -> Data {
        guard let url = URL(string: path, relativeTo: Self.portal) else { throw ChurchfrontError.network("bad address") }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(try await accessToken())", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, status) = try await send(request)
        switch status {
        case 200..<300: return data
        case 401:
            // The token may have been revoked or expired early: refresh once, then ask to sign in.
            if !retried, (try? await refresh()) != nil { return try await get(path, retried: true) }
            Self.signOut()
            throw ChurchfrontError.notSignedIn
        case 403: throw ChurchfrontError.notStaff
        case 404: throw ChurchfrontError.notFound
        default: throw ChurchfrontError.server(status, Self.message(in: data))
        }
    }

    private func accessToken() async throws -> String {
        guard let tokens = ChurchfrontTokenStore.load(), tokens.portal == Self.portal.absoluteString else {
            throw ChurchfrontError.notSignedIn
        }
        if tokens.expiresAt.timeIntervalSinceNow > 60 { return tokens.accessToken }
        return try await refresh()
    }

    @discardableResult
    private func refresh() async throws -> String {
        guard let tokens = ChurchfrontTokenStore.load(), let refreshToken = tokens.refreshToken,
              let endpoint = URL(string: tokens.tokenEndpoint) else { throw ChurchfrontError.notSignedIn }
        let fresh: TokenResponse
        do {
            fresh = try await tokenRequest(endpoint, ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": tokens.clientID])
        } catch ChurchfrontError.signIn {
            Self.signOut()
            throw ChurchfrontError.notSignedIn
        }
        var updated = tokens
        updated.accessToken = fresh.accessToken
        updated.refreshToken = fresh.refreshToken ?? refreshToken
        updated.expiresAt = Date.now.addingTimeInterval(fresh.expiresIn ?? 3600)
        try ChurchfrontTokenStore.save(updated)
        return fresh.accessToken
    }

    // MARK: OAuth plumbing

    private struct Server { let authorization: URL; let token: URL; let registration: URL? }

    private struct TokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let expiresIn: Double?
        enum CodingKeys: String, CodingKey { case accessToken = "access_token", refreshToken = "refresh_token", expiresIn = "expires_in" }
    }

    /// The portal names its authorization server (RFC 9728), which publishes its endpoints (RFC 8414).
    private func authorizationServer() async throws -> Server {
        let resource = try await json(Self.portal.appendingPathComponent(".well-known/oauth-protected-resource"))
        guard let issuerText = (resource["authorization_servers"] as? [String])?.first,
              let issuer = URL(string: issuerText) else { throw ChurchfrontError.signIn("the portal did not name its sign-in server") }
        // RFC 8414 puts the well-known segment before the issuer's path; some servers serve it after.
        var candidates: [URL] = []
        if var c = URLComponents(url: issuer, resolvingAgainstBaseURL: false) {
            let path = c.path.hasSuffix("/") ? String(c.path.dropLast()) : c.path
            c.path = "/.well-known/oauth-authorization-server" + path
            if let url = c.url { candidates.append(url) }
        }
        candidates.append(issuer.appendingPathComponent(".well-known/oauth-authorization-server"))
        for url in candidates {
            guard let meta = try? await json(url),
                  let auth = (meta["authorization_endpoint"] as? String).flatMap(URL.init(string:)),
                  let token = (meta["token_endpoint"] as? String).flatMap(URL.init(string:)) else { continue }
            return Server(authorization: auth, token: token,
                          registration: (meta["registration_endpoint"] as? String).flatMap(URL.init(string:)))
        }
        throw ChurchfrontError.signIn("the sign-in server's details could not be read")
    }

    /// One client registration per device and portal, kept for later sign-ins.
    private func registeredClient(_ server: Server) async throws -> String {
        let key = "churchfrontClientID.\(Self.portal.absoluteString)"
        if let saved = UserDefaults.standard.string(forKey: key) { return saved }
        guard let endpoint = server.registration else { throw ChurchfrontError.signIn("the portal does not accept new apps") }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "client_name": "CuePrompter",
            "redirect_uris": [Self.redirectURI],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none"
        ])
        let (data, status) = try await send(request)
        guard (200..<300).contains(status),
              let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let clientID = body["client_id"] as? String else {
            throw ChurchfrontError.signIn("CuePrompter could not register with the portal (\(status) \(Self.message(in: data)))")
        }
        UserDefaults.standard.set(clientID, forKey: key)
        return clientID
    }

    private func tokenRequest(_ endpoint: URL, _ form: [String: String]) async throws -> TokenResponse {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        var components = URLComponents()
        components.queryItems = form.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = Data((components.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
        let (data, status) = try await send(request)
        guard (200..<300).contains(status), let tokens = try? JSONDecoder().decode(TokenResponse.self, from: data) else {
            throw ChurchfrontError.signIn("\(status) \(Self.message(in: data))")
        }
        return tokens
    }

    private func json(_ url: URL) async throws -> [String: Any] {
        let (data, status) = try await send(URLRequest(url: url))
        guard (200..<300).contains(status), let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChurchfrontError.server(status, Self.message(in: data))
        }
        return body
    }

    private func send(_ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await session.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch {
            throw ChurchfrontError.network(error.localizedDescription)
        }
    }

    private static func message(in data: Data) -> String {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let text = (body?["error_description"] ?? body?["error"] ?? body?["msg"] ?? body?["message"]) as? String
        return text ?? String(decoding: data.prefix(200), as: UTF8.self)
    }

    private static func randomString(_ bytes: Int) -> String {
        var buffer = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &buffer)
        return Data(buffer).base64URL
    }

    nonisolated static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

extension ChurchfrontClient: ASWebAuthenticationPresentationContextProviding {
    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            let active = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
            return active?.keyWindow ?? active?.windows.first ?? ASPresentationAnchor()
        }
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

struct ChurchfrontTokens: Codable {
    var portal: String
    var tokenEndpoint: String
    var clientID: String
    var accessToken: String
    var refreshToken: String?
    var expiresAt: Date
}

/// Keeps the Churchfront sign-in in the Keychain (never in files or UserDefaults).
enum ChurchfrontTokenStore {
    private static let service = "com.churchfront.prompter.portal"
    private static let account = "oauth"

    static func save(_ tokens: ChurchfrontTokens) throws {
        delete()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: try JSONEncoder().encode(tokens)
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw ChurchfrontError.signIn("the sign-in could not be saved (\(status))") }
    }

    static func load() -> ChurchfrontTokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return try? JSONDecoder().decode(ChurchfrontTokens.self, from: data)
    }

    static func delete() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

/// Saves portal scripts into the library under the same keys Send to Teleprompter uses.
@MainActor
enum ChurchfrontImporter {
    static func sourceKey(_ portalKey: String) -> String { "churchfront:\(portalKey)" }

    @discardableResult
    static func download(_ key: String, into store: ScriptStore) async throws -> (script: Script, created: Bool) {
        let portal = try await ChurchfrontClient.shared.script(key: key)
        let source = ScriptSource(key: sourceKey(portal.key), notionPageID: "", courseName: portal.course,
                                  lessonTitle: portal.title, importedAt: .now, origin: "churchfront")
        return store.upsertImported(title: portal.title, body: ScriptStore.normalizeLineEndings(portal.text), source: source)
    }

    /// The portal key behind a script that came from the portal (sent from the Mac or downloaded).
    static func portalKey(of script: Script) -> String? {
        guard let source = script.source, source.origin == "churchfront", source.key.hasPrefix("churchfront:") else { return nil }
        return String(source.key.dropFirst("churchfront:".count))
    }
}
