import Foundation

/// The one last.fm call Top Tracks needs: `user.getTopTracks`.
///
/// Read-only and unauthenticated beyond an API key — last.fm's user data is public unless the
/// profile is private, so there is no OAuth, no session key, and nothing to store in the
/// Keychain. The key is injected from `Secrets.xcconfig` the same way the Spotify Client ID
/// is (`LASTFM_API_KEY` → Info.plist `LastFMAPIKey`).
///
/// Deliberately not routed through `SpotifyWebAPI`'s request plumbing: different host, no
/// bearer token, and one request per period per day — nothing the 429 gate needs to govern.
@MainActor
final class LastFMClient {

    static let placeholderKey = "your_lastfm_api_key_here"
    private static let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    enum LastFMError: LocalizedError {
        case missingAPIKey
        case http(Int)

        var errorDescription: String? {
            switch self {
            case .missingAPIKey: return "No last.fm API key configured (see Secrets.xcconfig)."
            case .http(let code): return "last.fm request failed (HTTP \(code))."
            }
        }
    }

    private let apiKey: String

    init(apiKey: String? = nil) {
        self.apiKey = apiKey
            ?? (Bundle.main.object(forInfoDictionaryKey: "LastFMAPIKey") as? String)
            ?? ""
    }

    /// False until the developer has filled in a real key. An unexpanded `$(LASTFM_API_KEY)`
    /// means the xcconfig line is missing altogether.
    var hasAPIKey: Bool {
        !apiKey.isEmpty && apiKey != Self.placeholderKey && !apiKey.hasPrefix("$(")
    }

    /// The user's most played tracks for one period, most played first.
    func topTracks(user: String, period: TopTracksPeriod, limit: Int) async throws -> [LastFMTopTrack] {
        guard hasAPIKey else { throw LastFMError.missingAPIKey }
        var comps = URLComponents(url: Self.endpoint, resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            .init(name: "method", value: "user.gettoptracks"),
            .init(name: "user", value: user),
            .init(name: "period", value: period.lastFMPeriod),
            .init(name: "limit", value: String(limit)),
            .init(name: "api_key", value: apiKey),
            .init(name: "format", value: "json"),
        ]
        var req = URLRequest(url: comps.url!)
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "dev"
        req.setValue("SpotifyMenuBar/\(version)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)

        // last.fm sends its error envelope with a 4xx status; read the envelope first so the
        // user sees "unknown user" rather than "HTTP 400".
        if let (code, message) = TopTracksLogic.lastFMError(data) {
            DebugLog.log("last.fm user.getTopTracks(\(period.rawValue)) -> error \(code): \(message)")
            throw LastFMParseError.api(code: code, message: message)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            DebugLog.log("last.fm user.getTopTracks(\(period.rawValue)) -> HTTP \(http.statusCode)")
            throw LastFMError.http(http.statusCode)
        }
        return try TopTracksLogic.parseTopTracks(data)
    }
}
