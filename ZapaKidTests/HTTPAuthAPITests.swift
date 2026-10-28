import Foundation
import Testing
@testable import ZapaKidKit

/// The sign-in client against a mocked API, per `openapi.yaml` in ZapaCIT-S-R-L/zapakid-api (tags Sign-in and Account):
/// POST /v1/auth/nonce, POST /v1/auth/apple, POST /v1/auth/google, GET /v1/me, POST /v1/auth/logout.
@Suite(.serialized)
struct HTTPAuthAPITests {
    let base = URL(string: "https://api.test.invalid")!
    let nonce = "n0nce-n0nce-n0nce-n0nce-n0nce-n0nce-n0nce12" // 43 base64url characters
    let parentJSON = """
    {"id":"6f1c0e2a-0000-4000-8000-000000000001","email":"test@example.invalid","displayName":"TEST Parent",\
    "ageRange":{"category":"adult","source":"apple_declared_age_range","lowerBound":18,"upperBound":null,\
    "platformStatus":"sharing","checkedAt":"2026-10-26T18:00:00Z"},"createdAt":"2026-10-26T18:00:00.123Z"}
    """
    var signedInJSON: String {
        #"{"session":{"token":"zks_tok","expiresAt":"2026-11-25T18:00:00Z"},"parent":\#(parentJSON),"newAccount":true}"#
    }

    var parent: ParentProfile {
        ParentProfile(
            id: "6f1c0e2a-0000-4000-8000-000000000001",
            email: "test@example.invalid",
            displayName: "TEST Parent"
        )
    }

    func api(_ handler: @escaping MockURLProtocol.Handler) -> HTTPAuthAPI {
        HTTPAuthAPI(baseURL: base, session: MockURLProtocol.session(handler))
    }

    func appleRequest(age: AgeRange = .shared(lower: 18, upper: nil, platformStatus: "sharing")) -> SignInRequest {
        SignInRequest(provider: .apple, idToken: "apple-jwt", nonce: nonce, ageRange: age, displayName: "TEST Parent")
    }

    // MARK: Nonce

    @Test func nonceIsFetchedWithoutASession() async throws {
        let reply = #"{"nonce":"\#(nonce)","expiresAt":"2026-10-26T18:10:00Z"}"#
        let client = api { _, _ in MockReply(200, reply) }

        let grant = try await client.signInNonce()

        #expect(grant.nonce == nonce)
        #expect(grant.expiresAt == ISO8601DateFormatter().date(from: "2026-10-26T18:10:00Z"))
        let sent = try #require(MockURLProtocol.requests.first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.absoluteString == "https://api.test.invalid/v1/auth/nonce")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    // MARK: Sign in

    @Test func appleSignInSendsExactlyTheContractFields() async throws {
        let client = api { [signedInJSON] _, _ in MockReply(200, signedInJSON) }

        let session = try await client.signIn(appleRequest())

        #expect(session.token == "zks_tok")
        #expect(session.expiresAt == ISO8601DateFormatter().date(from: "2026-11-25T18:00:00Z"))
        #expect(session.parent == parent)
        let sent = try #require(MockURLProtocol.requests.first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.absoluteString == "https://api.test.invalid/v1/auth/apple")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(sent.body?.json)
        #expect(Set(body.keys) == ["nonce", "identityToken", "ageRange", "displayName"])
        #expect(body["nonce"] as? String == nonce, "the raw nonce; the provider got its SHA-256")
        #expect(body["identityToken"] as? String == "apple-jwt")
        #expect(body["displayName"] as? String == "TEST Parent")
        let age = try #require(body["ageRange"] as? [String: Any])
        #expect(Set(age.keys) == ["availability", "source", "lowerBound", "upperBound", "platformStatus"])
        #expect(age["availability"] as? String == "shared")
        #expect(age["source"] as? String == "apple_declared_age_range")
        #expect(age["lowerBound"] as? Int == 18)
        #expect(age["upperBound"] is NSNull, "open-ended bounds are sent as null, they are required")
        #expect(age["platformStatus"] as? String == "sharing")
    }

    @Test func googleSignInUsesIdTokenAndNoDisplayName() async throws {
        let client = api { [signedInJSON] _, _ in MockReply(200, signedInJSON) }
        let request = SignInRequest(
            provider: .google, idToken: "google-jwt", nonce: nonce, ageRange: .unavailable, displayName: "ignored"
        )

        _ = try await client.signIn(request)

        let sent = try #require(MockURLProtocol.requests.first)
        #expect(sent.request.url?.path == "/v1/auth/google")
        let body = try #require(sent.body?.json)
        #expect(Set(body.keys) == ["nonce", "idToken", "ageRange"])
        #expect(body["idToken"] as? String == "google-jwt")
        let age = try #require(body["ageRange"] as? [String: Any])
        #expect(age["availability"] as? String == "unavailable")
        #expect(age["source"] as? String == "apple_declared_age_range", "on iOS the age always comes from Apple")
        #expect(age["lowerBound"] is NSNull)
        #expect(age["upperBound"] is NSNull)
        #expect(age["platformStatus"] == nil)
    }

    @Test(arguments: [
        (403, "minor_not_allowed", AuthAPIError.minorNotAllowed),
        (403, "age_declined", AuthAPIError.ageDeclined),
        (401, "invalid_nonce", AuthAPIError.invalidNonce),
        (401, "invalid_token", AuthAPIError.invalidToken),
        (503, "provider_unavailable", AuthAPIError.providerUnavailable),
        (403, "attestation_failed", AuthAPIError.attestationFailed),
        (400, "invalid_request", AuthAPIError.server(status: 400, code: "invalid_request")),
    ])
    func signInErrorsMapToTheirCode(status: Int, code: String, expected: AuthAPIError) async throws {
        let client = api { _, _ in MockReply(status, #"{"error":{"code":"\#(code)","message":"x"}}"#) }

        await #expect(throws: expected) { try await client.signIn(appleRequest()) }
    }

    @Test func rateLimitKeepsRetryAfter() async throws {
        let client = api { _, _ in
            MockReply(429, #"{"error":{"code":"rate_limited","message":"x"}}"#, headers: ["Retry-After": "30"])
        }

        await #expect(throws: AuthAPIError.rateLimited(retryAfter: 30)) { try await client.signIn(appleRequest()) }
    }

    @Test func rateLimitWithoutRetryAfter() async throws {
        let client = api { _, _ in MockReply(429, #"{"error":{"code":"rate_limited","message":"x"}}"#) }

        await #expect(throws: AuthAPIError.rateLimited(retryAfter: nil)) { try await client.signInNonce() }
    }

    // MARK: Account

    @Test func meReturnsTheParentWithTheBearerToken() async throws {
        let client = api { [parentJSON] _, _ in MockReply(200, parentJSON) }

        let result = try await client.me(token: "zks_tok")

        #expect(result == parent)
        let sent = try #require(MockURLProtocol.requests.first)
        #expect(sent.request.httpMethod == "GET")
        #expect(sent.request.url?.path == "/v1/me")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer zks_tok")
    }

    @Test func expiredSessionIsUnauthorized() async throws {
        let client = api { _, _ in MockReply(401, #"{"error":{"code":"unauthorized","message":"x"}}"#) }

        await #expect(throws: AuthAPIError.unauthorized) { try await client.me(token: "old") }
    }

    @Test func logoutPostsWithTheBearerToken() async throws {
        let client = api { _, _ in MockReply(204) }

        try await client.logout(token: "zks_tok")

        let sent = try #require(MockURLProtocol.requests.first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.path == "/v1/auth/logout")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer zks_tok")
    }

    // MARK: Transport

    @Test func garbageResponseIsInvalid() async throws {
        let client = api { _, _ in MockReply(200, "not json") }

        await #expect(throws: AuthAPIError.invalidResponse) { try await client.me(token: "t") }
    }

    @Test func networkFailureIsReportedAsNetwork() async throws {
        let client = api { _, _ in throw URLError(.notConnectedToInternet) }

        await #expect(throws: AuthAPIError.network) { try await client.me(token: "t") }
    }

    @Test func defaultSessionRequiresTLS13AndKeepsNoCookiesOrCache() {
        let config = HTTPAuthAPI.secureConfiguration()
        #expect(config.tlsMinimumSupportedProtocolVersion == .TLSv13)
        #expect(config.httpCookieStorage == nil)
        #expect(config.urlCache == nil)
        #expect(config.httpShouldSetCookies == false)
    }

    @Test func defaultClientTalksToStaging() {
        #expect(HTTPAuthAPI.staging.baseURL.absoluteString == "https://api-staging.zapakid.ro")
    }
}
