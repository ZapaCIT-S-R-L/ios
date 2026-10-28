import Foundation
import Testing
@testable import ZapaKid

/// Google sign-in for the iOS OAuth client of ro.zapakid.app (authorization code + PKCE, no SDK, no secret).
@MainActor
struct GoogleSignInTests {
    let clientID = "64042746735-lgdmtj9vvd3kiu7g9qc2elu22la6o1id.apps.googleusercontent.com"

    @Test func usesTheIOSClientOfTheApp() {
        #expect(GoogleSignIn.clientID == clientID)
        #expect(GoogleSignIn.isConfigured)
    }

    @Test func redirectIsTheReversedClientIDScheme() {
        #expect(GoogleSignIn.scheme == "com.googleusercontent.apps.64042746735-lgdmtj9vvd3kiu7g9qc2elu22la6o1id")
        #expect(GoogleSignIn.redirect == "\(GoogleSignIn.scheme):/oauth2redirect")
    }

    @Test func authorizationURLCarriesPKCENonceAndState() throws {
        let url = try #require(GoogleSignIn.authorizationURL(nonce: "hashed-nonce", challenge: "pkce", state: "st"))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let query = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components.scheme == "https")
        #expect(components.host == "accounts.google.com")
        #expect(query["client_id"] == clientID)
        #expect(query["redirect_uri"] == GoogleSignIn.redirect)
        #expect(query["response_type"] == "code")
        #expect(query["scope"] == "openid email profile")
        #expect(query["code_challenge"] == "pkce")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["nonce"] == "hashed-nonce", "the ID token carries SHA-256 of the server nonce")
        #expect(query["state"] == "st")
    }

    @Test func callbackCodeNeedsTheSameState() throws {
        let good = try #require(URL(string: "\(GoogleSignIn.scheme):/oauth2redirect?state=st&code=abc"))
        let forged = try #require(URL(string: "\(GoogleSignIn.scheme):/oauth2redirect?state=other&code=abc"))
        let denied = try #require(URL(string: "\(GoogleSignIn.scheme):/oauth2redirect?state=st&error=access_denied"))

        #expect(GoogleSignIn.code(from: good, state: "st") == "abc")
        #expect(GoogleSignIn.code(from: forged, state: "st") == nil, "a callback for another sign-in is ignored")
        #expect(GoogleSignIn.code(from: denied, state: "st") == nil)
    }
}
