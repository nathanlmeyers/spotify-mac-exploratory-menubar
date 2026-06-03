import Foundation
import AppKit

struct TokenBundle: Codable {
    var accessToken: String
    var refreshToken: String
    var expiresAt: Date
    /// Treat as expired 60s early to avoid edge-of-expiry failures.
    var isExpired: Bool { Date() >= expiresAt.addingTimeInterval(-60) }
}

/// Owns the OAuth 2.0 Authorization Code + PKCE flow and token lifecycle.
/// Tokens are persisted in the Keychain; access tokens are refreshed silently.
@MainActor
final class SpotifyAuth: ObservableObject {
    static let redirectURI = "spotifymenubar://callback"
    static let scopes = [
        "playlist-read-private",
        "playlist-read-collaborative",
        "playlist-modify-public",
        "playlist-modify-private",
        "user-read-playback-state",
        "user-read-currently-playing",
    ].joined(separator: " ")

    @Published private(set) var isAuthorized = false
    @Published private(set) var lastError: String?

    private let clientID: String
    private let keychainAccount = "spotify-oauth"
    private var tokens: TokenBundle? { didSet { isAuthorized = (tokens != nil) } }
    private var pendingVerifier: String?
    private var pendingState: String?

    enum AuthError: LocalizedError {
        case missingClientID, badResponse(Int), stateMismatch, notAuthorized
        var errorDescription: String? {
            switch self {
            case .missingClientID: return "No Spotify Client ID configured (see Secrets.xcconfig)."
            case .badResponse(let code): return "Spotify auth request failed (HTTP \(code))."
            case .stateMismatch: return "Login response did not match the request (possible CSRF)."
            case .notAuthorized: return "Not logged in to Spotify."
            }
        }
    }

    init() {
        clientID = (Bundle.main.object(forInfoDictionaryKey: "SpotifyClientID") as? String) ?? ""
        if let data = KeychainStore.load(account: keychainAccount),
           let stored = try? JSONDecoder().decode(TokenBundle.self, from: data) {
            tokens = stored
            isAuthorized = true
        }
    }

    /// False if the developer hasn't filled in their Client ID yet.
    var hasClientID: Bool {
        !clientID.isEmpty &&
        !clientID.hasPrefix("REPLACE") &&
        clientID != "your_client_id_here"
    }

    func beginLogin() {
        guard hasClientID else { lastError = AuthError.missingClientID.errorDescription; return }
        let verifier = PKCE.makeVerifier()
        let state = PKCE.randomState()
        pendingVerifier = verifier
        pendingState = state

        var comps = URLComponents(string: "https://accounts.spotify.com/authorize")!
        comps.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: PKCE.challenge(for: verifier)),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
        ]
        if let url = comps.url { NSWorkspace.shared.open(url) }
    }

    /// Invoked by the app delegate when `spotifymenubar://callback?...` arrives.
    func handleCallback(_ url: URL) async {
        guard let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
        let items = comps.queryItems ?? []
        if let err = items.first(where: { $0.name == "error" })?.value {
            lastError = "Spotify login canceled: \(err)"
            return
        }
        guard let code = items.first(where: { $0.name == "code" })?.value else { return }
        guard items.first(where: { $0.name == "state" })?.value == pendingState,
              let verifier = pendingVerifier else {
            lastError = AuthError.stateMismatch.errorDescription
            return
        }
        do {
            try await exchangeCode(code, verifier: verifier)
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
        pendingVerifier = nil
        pendingState = nil
    }

    /// Returns a valid access token, refreshing if necessary.
    func validAccessToken() async throws -> String {
        guard var current = tokens else { throw AuthError.notAuthorized }
        if current.isExpired {
            current = try await refresh(current)
            persist(current)
        }
        return current.accessToken
    }

    func logout() {
        tokens = nil
        KeychainStore.delete(account: keychainAccount)
    }

    // MARK: - Token requests

    private func exchangeCode(_ code: String, verifier: String) async throws {
        let bundle = try await tokenRequest([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": Self.redirectURI,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
        persist(bundle)
    }

    private func refresh(_ existing: TokenBundle) async throws -> TokenBundle {
        var refreshed = try await tokenRequest([
            "grant_type": "refresh_token",
            "refresh_token": existing.refreshToken,
            "client_id": clientID,
        ])
        // Spotify often omits a new refresh token — keep the existing one.
        if refreshed.refreshToken.isEmpty { refreshed.refreshToken = existing.refreshToken }
        return refreshed
    }

    private func tokenRequest(_ body: [String: String]) async throws -> TokenBundle {
        var req = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(body)

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw AuthError.badResponse(code)
        }

        struct TokenResponse: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
            let scope: String?
        }
        let r = try JSONDecoder().decode(TokenResponse.self, from: data)
        DebugLog.log("token granted scopes: \(r.scope ?? "<none>")")
        return TokenBundle(
            accessToken: r.access_token,
            refreshToken: r.refresh_token ?? "",
            expiresAt: Date().addingTimeInterval(r.expires_in)
        )
    }

    private func persist(_ bundle: TokenBundle) {
        tokens = bundle
        if let data = try? JSONEncoder().encode(bundle) {
            KeychainStore.save(data, account: keychainAccount)
        }
    }

    static func formEncode(_ body: [String: String]) -> Data {
        body.map { key, value in
            let v = value.addingPercentEncoding(withAllowedCharacters: .spotifyFormAllowed) ?? value
            return "\(key)=\(v)"
        }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
    }
}

extension CharacterSet {
    /// urlQueryAllowed minus the sub-delimiters that must be escaped in form bodies.
    static let spotifyFormAllowed: CharacterSet = {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "+&=?/ ")
        return cs
    }()
}
