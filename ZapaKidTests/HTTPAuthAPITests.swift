import Foundation
import Testing
@testable import ZapaKidKit

/// The sign-in client against a mocked API, per the contract in `HTTPAuthAPI` (POST /v1/auth/{apple,google},
/// GET /v1/me, POST /v1/auth/logout).
@Suite(.serialized)
struct HTTPAuthAPITests {
    let base = URL(string: "https://api.test.invalid")!
    let parentJSON = #"{"id":"p_1","name":"TEST Parent","email":"test@example.invalid"}"#

    @Test func appleSignInPostsTokenNonceAndAgeRange() async throws {
        let reply = #"{"token":"tok_1","parent":\#(parentJSON)}"#
        let session = MockURLProtocol.session { _, _ in (200, Data(reply.utf8)) }
        let api = HTTPAuthAPI(baseURL: base, session: session)
        let request = SignInRequest(
            provider: .apple, idToken: "apple-id-token", nonce: "raw-nonce",
            ageRange: AgeRange(lower: 18, upper: nil, declined: false)
        )

        let result = try await api.signIn(request)

        #expect(result == Session(
            token: "tok_1",
            parent: ParentProfile(id: "p_1", name: "TEST Parent", email: "test@example.invalid")
        ))
        let sent = try #require(MockURLProtocol.requests.first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.absoluteString == "https://api.test.invalid/v1/auth/apple")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(sent.body?.json)
        #expect(body["idToken"] as? String == "apple-id-token")
        #expect(body["nonce"] as? String == "raw-nonce")
        let age = try #require(body["ageRange"] as? [String: Any])
        #expect(age["lower"] as? Int == 18)
        #expect(age["upper"] == nil)
        #expect(age["declined"] as? Bool == false)
    }

    @Test func googleSignInUsesTheGooglePath() async throws {
        let reply = #"{"token":"tok_2","parent":\#(parentJSON)}"#
        let session = MockURLProtocol.session { _, _ in (200, Data(reply.utf8)) }
        let api = HTTPAuthAPI(baseURL: base, session: session)

        _ = try await api.signIn(SignInRequest(provider: .google, idToken: "g", nonce: "n", ageRange: nil))

        let sent = try #require(MockURLProtocol.requests.first)
        #expect(sent.request.url?.path == "/v1/auth/google")
        let body = try #require(sent.body?.json)
        #expect(body["ageRange"] is NSNull, "an unknown age is sent as null, so the API decides")
    }

    @Test func minorRejectedByTheAPIIsReported() async throws {
        let reply = #"{"error":{"code":"minor","message":"Parents must be 18 or older."}}"#
        let session = MockURLProtocol.session { _, _ in (403, Data(reply.utf8)) }
        let api = HTTPAuthAPI(baseURL: base, session: session)

        await #expect(throws: AuthAPIError.minor) {
            try await api.signIn(SignInRequest(provider: .apple, idToken: "t", nonce: "n", ageRange: nil))
        }
    }

    @Test func otherErrorsKeepStatusAndCode() async throws {
        let reply = #"{"error":{"code":"invalid_token","message":"x"}}"#
        let session = MockURLProtocol.session { _, _ in (400, Data(reply.utf8)) }
        let api = HTTPAuthAPI(baseURL: base, session: session)

        await #expect(throws: AuthAPIError.server(status: 400, code: "invalid_token")) {
            try await api.signIn(SignInRequest(provider: .apple, idToken: "t", nonce: "n", ageRange: nil))
        }
    }

    @Test func meSendsTheBearerToken() async throws {
        let reply = #"{"parent":\#(parentJSON)}"#
        let session = MockURLProtocol.session { _, _ in (200, Data(reply.utf8)) }
        let api = HTTPAuthAPI(baseURL: base, session: session)

        let parent = try await api.me(token: "tok_1")

        #expect(parent.id == "p_1")
        let sent = try #require(MockURLProtocol.requests.first)
        #expect(sent.request.httpMethod == "GET")
        #expect(sent.request.url?.path == "/v1/me")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_1")
    }

    @Test func expiredSessionIsUnauthorized() async throws {
        let session = MockURLProtocol.session { _, _ in (401, Data(#"{"error":{"code":"unauthorized"}}"#.utf8)) }
        let api = HTTPAuthAPI(baseURL: base, session: session)

        await #expect(throws: AuthAPIError.unauthorized) { try await api.me(token: "old") }
    }

    @Test func logoutPostsWithTheBearerToken() async throws {
        let session = MockURLProtocol.session { _, _ in (204, Data()) }
        let api = HTTPAuthAPI(baseURL: base, session: session)

        try await api.logout(token: "tok_1")

        let sent = try #require(MockURLProtocol.requests.first)
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.url?.path == "/v1/auth/logout")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer tok_1")
    }

    @Test func garbageResponseIsInvalid() async throws {
        let session = MockURLProtocol.session { _, _ in (200, Data("not json".utf8)) }
        let api = HTTPAuthAPI(baseURL: base, session: session)

        await #expect(throws: AuthAPIError.invalidResponse) { try await api.me(token: "t") }
    }

    @Test func networkFailureIsReportedAsNetwork() async throws {
        let session = MockURLProtocol.session { _, _ in throw URLError(.notConnectedToInternet) }
        let api = HTTPAuthAPI(baseURL: base, session: session)

        await #expect(throws: AuthAPIError.network) { try await api.me(token: "t") }
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
