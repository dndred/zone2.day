import AuthenticationServices
import UIKit
import Zone2Kit

/// Sign-in through our OAuth page (passkey) in the system web auth sheet.
@MainActor
final class SignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func run(client: OAuthClient) async throws -> TokenSet {
        let verifier = PKCE.verifier()
        let state = PKCE.verifier()
        let url = client.authorizeURL(state: state, challenge: PKCE.challenge(for: verifier))
        let callback: URL = try await withCheckedThrowingContinuation { cont in
            let session = ASWebAuthenticationSession(url: url, callback: .customScheme("zone2")) { url, error in
                if let url { cont.resume(returning: url) } else { cont.resume(throwing: error ?? AuthError.callback("cancelled")) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
        session = nil
        let code = try client.code(from: callback, expectedState: state)
        return try await client.exchange(code: code, verifier: verifier)
    }

    nonisolated func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        MainActor.assumeIsolated {
            UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.keyWindow }.first ?? ASPresentationAnchor()
        }
    }
}
