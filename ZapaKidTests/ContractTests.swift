import Foundation
import Testing
@testable import ZapaKidKit

/// A fixture from contract/fixtures: one request the app builds and/or one response the API sends.
/// test/contract.test.js checks each against the API's openapi.yaml at the pinned commit (contract/api.json).
struct ContractFixture {
    let operation: String
    let request: Any?
    let status: Int
    let body: Data
    let headers: [String: String]

    final class Anchor {}

    static func load(_ name: String) throws -> ContractFixture {
        let url = try #require(
            Bundle(for: Anchor.self).url(forResource: name, withExtension: "json", subdirectory: "fixtures"),
            "contract/fixtures/\(name).json is in the test bundle"
        )
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let response = try #require(json["response"] as? [String: Any])
        let body = response["body"].flatMap { $0 is NSNull ? nil : $0 }
        return try ContractFixture(
            operation: #require(json["operation"] as? String),
            request: json["request"].flatMap { $0 is NSNull ? nil : $0 },
            status: #require(response["status"] as? Int),
            body: body.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data(),
            headers: response["headers"] as? [String: String] ?? [:]
        )
    }

    var reply: MockReply {
        MockReply(status, String(data: body, encoding: .utf8) ?? "", headers: headers)
    }

    var method: String {
        String(operation.split(separator: " ")[0])
    }

    var path: String {
        String(operation.split(separator: " ")[1])
    }
}

/// The app builds exactly the contract's requests and understands exactly its responses (the same fixtures the
/// contract test validates against openapi.yaml).
@Suite(.serialized)
struct ContractTests {
    let base = URL(string: "https://api.test.invalid")!

    func api(answering fixture: ContractFixture) -> HTTPAuthAPI {
        HTTPAuthAPI(baseURL: base, session: MockURLProtocol.session { _, _ in fixture.reply })
    }

    func sentJSON() throws -> NSDictionary {
        let body = try #require(MockURLProtocol.requests.first?.body)
        return try #require(JSONSerialization.jsonObject(with: body) as? NSDictionary)
    }

    func expectOperation(_ fixture: ContractFixture) throws {
        let sent = try #require(MockURLProtocol.requests.first?.request)
        #expect(sent.httpMethod == fixture.method)
        #expect(sent.url?.path == fixture.path)
    }

    /// The fixture's age range as the app's type.
    func ageRange(_ json: [String: Any]) throws -> AgeRange {
        let availability = try #require(json["availability"] as? String)
        let lower = json["lowerBound"] as? Int
        let upper = json["upperBound"] as? Int
        let status = json["platformStatus"] as? String
        switch availability {
        case "shared": return .shared(lower: lower, upper: upper, platformStatus: status)
        case "declined": return .declined(platformStatus: status)
        default: return .unavailable
        }
    }

    @Test func nonce() async throws {
        let fixture = try ContractFixture.load("nonce")

        let grant = try await api(answering: fixture).signInNonce()

        try expectOperation(fixture)
        #expect(grant.nonce.count == 43)
    }

    @Test(arguments: [("sign-in-apple", SignInProvider.apple), ("sign-in-google", .google)])
    func signInRequestIsExactlyTheContractOne(name: String, provider: SignInProvider) async throws {
        let fixture = try ContractFixture.load(name)
        let expected = try #require(fixture.request as? [String: Any])
        let request = try SignInRequest(
            provider: provider,
            idToken: #require((expected["identityToken"] ?? expected["idToken"]) as? String),
            nonce: #require(expected["nonce"] as? String),
            ageRange: ageRange(#require(expected["ageRange"] as? [String: Any])),
            displayName: expected["displayName"] as? String
        )

        let session = try await api(answering: fixture).signIn(request)

        try expectOperation(fixture)
        #expect(try sentJSON() == expected as NSDictionary)
        #expect(session.token.hasPrefix("zks_"))
        #expect(session.parent.displayName == "TEST Parent")
    }

    @Test(arguments: [
        ("sign-in-minor", AuthAPIError.minorNotAllowed),
        ("sign-in-age-declined", .ageDeclined),
        ("sign-in-attestation-failed", .attestationFailed),
        ("sign-in-invalid-nonce", .invalidNonce),
        ("sign-in-invalid-token", .invalidToken),
        ("sign-in-rate-limited", .rateLimited(retryAfter: 60)),
        ("sign-in-provider-unavailable", .providerUnavailable),
        ("sign-in-invalid-request", .server(status: 400, code: "invalid_request")),
    ])
    func signInErrors(name: String, expected: AuthAPIError) async throws {
        let fixture = try ContractFixture.load(name)
        let request = SignInRequest(
            provider: .apple, idToken: "TEST", nonce: "n", ageRange: .unavailable, displayName: nil
        )

        await #expect(throws: expected) { try await api(answering: fixture).signIn(request) }
    }

    @Test func nonceRateLimit() async throws {
        let fixture = try ContractFixture.load("nonce-rate-limited")

        await #expect(throws: AuthAPIError.rateLimited(retryAfter: 60)) {
            try await api(answering: fixture).signInNonce()
        }
    }

    @Test func me() async throws {
        let fixture = try ContractFixture.load("me")

        let parent = try await api(answering: fixture).me(token: "zks_tok")

        try expectOperation(fixture)
        #expect(parent.id == "6f1c0e2a-0000-4000-8000-000000000001")
        #expect(parent.email == "test@example.invalid")
    }

    @Test func meUnauthorized() async throws {
        let fixture = try ContractFixture.load("me-unauthorized")

        await #expect(throws: AuthAPIError.unauthorized) { try await api(answering: fixture).me(token: "old") }
    }

    @Test func logout() async throws {
        let fixture = try ContractFixture.load("logout")

        try await api(answering: fixture).logout(token: "zks_tok")

        try expectOperation(fixture)
    }
}
