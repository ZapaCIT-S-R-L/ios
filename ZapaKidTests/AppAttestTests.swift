import CryptoKit
import Foundation
import Security
import Testing
@testable import ZapaKidKit

/// A fake DCAppAttestService: records what it was asked to sign.
final class FakeAppAttestService: AppAttestService, @unchecked Sendable {
    private let lock = NSLock()
    private var _isSupported = true
    private var generated = 0
    private var attested: [(keyID: String, clientDataHash: Data)] = []
    private var asserted: [(keyID: String, clientDataHash: Data)] = []

    var isSupported: Bool {
        get { lock.withLock { _isSupported } }
        set { lock.withLock { _isSupported = newValue } }
    }

    var generatedKeys: Int {
        lock.withLock { generated }
    }

    var attestations: [(keyID: String, clientDataHash: Data)] {
        lock.withLock { attested }
    }

    var assertions: [(keyID: String, clientDataHash: Data)] {
        lock.withLock { asserted }
    }

    func generateKey() async throws -> String {
        lock.withLock {
            generated += 1
            return Data("key-\(generated)".utf8).base64EncodedString()
        }
    }

    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { attested.append((keyID, clientDataHash)) }
        return Data("attestation-for-\(keyID)".utf8)
    }

    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { asserted.append((keyID, clientDataHash)) }
        return Data("assertion".utf8)
    }
}

/// App Attest on sign-in (openapi.yaml tag `Draft: App attestation`): the first sign-in registers a key
/// (`POST /v1/attestation/challenge`, `POST /v1/attestation/apple`); every sign-in then carries an assertion over
/// SHA-256 of its body in the `ZapaKid-Attestation` header.
@Suite(.serialized)
struct AppAttestTests {
    let base = URL(string: "https://api.test.invalid")!
    let keyStore = KeychainItem(service: "ro.zapakid.app.tests.attest.\(UUID().uuidString)", account: "keyId")
    let service = FakeAppAttestService()
    let challenge = "Y2hhbGxlbmdl"
    let signedIn = """
    {"session":{"token":"zks_tok","expiresAt":"2026-11-25T18:00:00Z"},\
    "parent":{"id":"p_1","email":null,"displayName":null},"newAccount":false}
    """

    func request() -> SignInRequest {
        SignInRequest(
            provider: .apple, idToken: "jwt", nonce: "nonce", ageRange: .unavailable, displayName: nil
        )
    }

    /// The API with App Attest, answering by path.
    func api(signInStatus: Int = 200, registerStatus: Int = 204) -> HTTPAuthAPI {
        let refused = #"{"error":{"code":"attestation_failed","message":"x"}}"#
        let session = MockURLProtocol.session { [challenge, signedIn] request, _ in
            switch request.url?.path {
            case "/v1/attestation/challenge":
                MockReply(200, #"{"challenge":"\#(challenge)","expiresAt":"2026-10-26T18:05:00Z"}"#)
            case "/v1/attestation/apple":
                MockReply(registerStatus, registerStatus == 204 ? "" : refused)
            case "/v1/auth/apple":
                MockReply(signInStatus, signInStatus == 200 ? signedIn : refused)
            default:
                MockReply(404)
            }
        }
        let attestor = AppAttestor(
            service: service,
            api: HTTPAuthAPI(baseURL: base, session: session),
            keyStore: keyStore
        )
        return HTTPAuthAPI(baseURL: base, session: session, attestor: attestor)
    }

    func paths() -> [String] {
        MockURLProtocol.requests.compactMap(\.request.url?.path)
    }

    func signInRequest() -> (request: URLRequest, body: Data?)? {
        MockURLProtocol.requests.first { $0.request.url?.path == "/v1/auth/apple" }
    }

    @Test func firstSignInRegistersAKeyThenSendsAnAssertion() async throws {
        defer { try? keyStore.clear() }
        let client = api()

        _ = try await client.signIn(request())

        #expect(paths() == ["/v1/attestation/challenge", "/v1/attestation/apple", "/v1/auth/apple"])
        let keyID = try #require(service.attestations.first?.keyID)
        #expect(service.attestations.first?.clientDataHash == Data(SHA256.hash(data: Data(challenge.utf8))))
        let register = try #require(MockURLProtocol.requests[1].body?.json)
        #expect(register["keyId"] as? String == keyID)
        #expect(register["attestationObject"] as? String == Data("attestation-for-\(keyID)".utf8).base64EncodedString())
        #expect(register["challenge"] as? String == challenge)
        #expect(try keyStore.load() == Data(keyID.utf8), "the key ID is kept for later sign-ins")

        let sent = try #require(signInRequest())
        let body = try #require(sent.body)
        #expect(service.assertions.last?.clientDataHash == Data(SHA256.hash(data: body)), "signs this exact body")
        let header = try #require(sent.request.value(forHTTPHeaderField: "ZapaKid-Attestation"))
        #expect(header == AppAttestor.header(keyID: keyID, assertion: Data("assertion".utf8)))
    }

    @Test func laterSignInsReuseTheRegisteredKey() async throws {
        defer { try? keyStore.clear() }
        let client = api()
        _ = try await client.signIn(request())

        _ = try await client.signIn(request())

        #expect(service.generatedKeys == 1)
        #expect(service.attestations.count == 1)
        #expect(paths() == ["/v1/attestation/challenge", "/v1/attestation/apple", "/v1/auth/apple", "/v1/auth/apple"])
        #expect(service.assertions.count == 2)
    }

    @Test func unsupportedDeviceSignsInWithoutTheHeader() async throws {
        service.isSupported = false
        let client = api()

        _ = try await client.signIn(request())

        #expect(paths() == ["/v1/auth/apple"], "simulator: the API decides (staging only)")
        #expect(signInRequest()?.request.value(forHTTPHeaderField: "ZapaKid-Attestation") == nil)
    }

    @Test func refusedRegistrationFailsTheSignInAndKeepsNoKey() async throws {
        let client = api(registerStatus: 403)

        await #expect(throws: AuthAPIError.attestationFailed) { try await client.signIn(request()) }

        #expect(!paths().contains("/v1/auth/apple"), "nothing is sent without attestation")
        #expect(try keyStore.load() == nil)
    }

    @Test func refusedAssertionForgetsTheKeySoTheNextSignInAttestsAgain() async throws {
        defer { try? keyStore.clear() }
        _ = try await api().signIn(request())
        #expect(try keyStore.load() != nil)

        await #expect(throws: AuthAPIError.attestationFailed) {
            try await api(signInStatus: 403).signIn(request())
        }

        #expect(try keyStore.load() == nil)
    }

    @Test func onlySignInCarriesTheHeader() async throws {
        defer { try? keyStore.clear() }
        let session = MockURLProtocol.session { _, _ in MockReply(204) }
        let attestor = AppAttestor(
            service: service,
            api: HTTPAuthAPI(baseURL: base, session: session),
            keyStore: keyStore
        )
        let client = HTTPAuthAPI(baseURL: base, session: session, attestor: attestor)

        try await client.logout(token: "zks_tok")

        #expect(MockURLProtocol.requests.first?.request.value(forHTTPHeaderField: "ZapaKid-Attestation") == nil)
        #expect(service.generatedKeys == 0)
    }

    @Test func headerIsVersionedKeyIdAndAssertion() {
        let header = AppAttestor.header(keyID: "a+b/c=", assertion: Data([0xFB, 0xFF]))
        #expect(header == "v1 keyId=a+b/c= assertion=+/8=")
    }

    @Test func keyIDIsKeptThisDeviceOnlyWhenUnlocked() throws {
        defer { try? keyStore.clear() }
        try keyStore.save(Data("key".utf8))

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keyStore.service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
        ]
        var result: CFTypeRef?
        #expect(SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess)
        let item = try #require(result as? [String: Any])
        #expect(item[kSecAttrAccessible as String] as? String == kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        #expect((item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue != true)
    }
}
