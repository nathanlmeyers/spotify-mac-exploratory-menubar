import Foundation
import CryptoKit

/// PKCE (Proof Key for Code Exchange) helpers for the OAuth Authorization Code flow.
enum PKCE {
    /// A high-entropy code verifier (base64url, ~86 chars — within the 43..128 spec range).
    static func makeVerifier() -> String {
        randomBase64URL(byteCount: 64)
    }

    /// S256 challenge = base64url(SHA256(verifier)).
    static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return Data(digest).base64URLEncodedString()
    }

    /// Opaque anti-CSRF state value.
    static func randomState() -> String {
        randomBase64URL(byteCount: 16)
    }

    private static func randomBase64URL(byteCount: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        _ = SecRandomCopyBytes(kSecRandomDefault, byteCount, &bytes)
        return Data(bytes).base64URLEncodedString()
    }
}

extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
