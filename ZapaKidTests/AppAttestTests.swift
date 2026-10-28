import CryptoKit
import Foundation
import Testing
@testable import ZapaKidKit

/// A fake `DCAppAttestService`: records what it signs, answers with fixed bytes.
final class FakeAppAttest: AppAttestService, @unchecked Sendable {
    private let lock = NSLock()
    private var supported: Bool
    private var keyCount = 0
    private var failNextAssertion: AppAttestServiceError?
    private(set) var attested: [(keyId: String, hash: Data)] = []
    private(set) var asserted: [(keyId: String, hash: Data)] = []

    init(supported: Bool = true) {
        self.supported = supported
    }

    var isSupported: Bool {
        lock.withLock { supported }
    }

    var generatedKeys: Int {
        lock.withLock { keyCount }
    }

    func failAssertion(with error: AppAttestServiceError) {
        lock.withLock { failNextAssertion = error }
    }

    /// Key ids as `generateKey()` returns them: base64 of a 32-byte SHA-256.
    static func keyId(_ number: Int) -> String {
        Data(repeating: UInt8(0x10 + number), count: 32).base64EncodedString()
    }

    func generateKey() async throws -> String {
        lock.withLock {
            keyCount += 1
            return Self.keyId(keyCount)
        }
    }

    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
        lock.withLock { attested.append((keyId, clientDataHash)) }
        return Data("TEST attestation object".utf8)
    }

    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
        try lock.withLock {
            if let error = failNextAssertion {
                failNextAssertion = nil
                throw error
            }
            asserted.append((keyId, clientDataHash))
        }
        return Data("TEST assertion".utf8)
    }
}

/// A fake key registration API.
actor FakeAppAttestAPI: AppAttestAPI {
    static let challenge = "Ch4llenge-Ch4llenge-Ch4llenge-Ch4llenge-Abc"
    private(set) var challenges = 0
    private(set) var registered: [(keyId: String, object: Data, challenge: String)] = []
    var registerError: AuthAPIError?

    func set(registerError: AuthAPIError?) {
        self.registerError = registerError
    }

    func attestationChallenge() async throws -> String {
        challenges += 1
        // Some time on the network, so concurrent callers really overlap.
        try await Task.sleep(for: .milliseconds(20))
        return Self.challenge
    }

    func registerAppAttestKey(keyId: String, attestationObject: Data, challenge: String) async throws {
        if let registerError {
            throw registerError
        }
        registered.append((keyId, attestationObject, challenge))
    }
}

/// The App Attest header for device registration (issue #54), per `src/app-attest.ts` in zapakid-api.
struct AppAttestTests {
    /// The API's header pattern (`HEADER` in src/app-attest.ts).
    static var headerPattern: Regex<(Substring, Substring, Substring)> {
        /^v1 keyId=([A-Za-z0-9+\/]{43}=) assertion=([A-Za-z0-9+\/]+={0,2})$/
    }

    let service = FakeAppAttest()
    let keys = InMemoryAppAttestKeyStore()
    let api = FakeAppAttestAPI()

    func attestor(skipWhenUnsupported: Bool = false, service: FakeAppAttest? = nil) -> AppAttestor {
        AppAttestor(service: service ?? self.service, keys: keys, api: api, skipWhenUnsupported: skipWhenUnsupported)
    }

    @Test func theFirstHeaderRegistersAKeyAgainstTheServerChallenge() async throws {
        let body = Data(#"{"registrationId":1}"#.utf8)

        let header = try #require(await attestor().header(for: body))

        let match = try #require(header.wholeMatch(of: Self.headerPattern))
        #expect(String(match.1) == FakeAppAttest.keyId(1))
        #expect(String(match.2) == Data("TEST assertion".utf8).base64EncodedString())
        #expect(service.attested.first?.hash == Data(SHA256.hash(data: Data(FakeAppAttestAPI.challenge.utf8))))
        let registered = try #require(await api.registered.first)
        #expect(registered.keyId == FakeAppAttest.keyId(1))
        #expect(registered.challenge == FakeAppAttestAPI.challenge)
        #expect(try keys.load() == FakeAppAttest.keyId(1))
        // The assertion covers SHA-256 of the exact body bytes.
        #expect(service.asserted.first?.hash == Data(SHA256.hash(data: body)))
    }

    @Test func laterHeadersReuseTheKey() async throws {
        let attestor = attestor()
        _ = try await attestor.header(for: Data("a".utf8))
        _ = try await attestor.header(for: Data("b".utf8))

        #expect(service.generatedKeys == 1)
        #expect(await api.challenges == 1)
        #expect(service.asserted.map(\.keyId) == [FakeAppAttest.keyId(1), FakeAppAttest.keyId(1)])
        #expect(service.asserted.last?.hash == Data(SHA256.hash(data: Data("b".utf8))))
    }

    @Test func concurrentCallersShareOneRegistration() async throws {
        let attestor = attestor()
        async let first = attestor.header(for: Data("a".utf8))
        async let second = attestor.header(for: Data("b".utf8))
        _ = try await (first, second)

        #expect(service.generatedKeys == 1)
        #expect(await api.registered.count == 1)
    }

    @Test func aDebugBuildSkipsOnlyWhereAppAttestIsMissing() async throws {
        let simulator = FakeAppAttest(supported: false)

        let header = try await attestor(skipWhenUnsupported: true, service: simulator).header(for: Data())

        #expect(header == nil)
        #expect(await api.challenges == 0)
    }

    @Test func aReleaseBuildNeverSkips() async throws {
        let simulator = FakeAppAttest(supported: false)

        await #expect(throws: AuthAPIError.attestationFailed) {
            _ = try await attestor(skipWhenUnsupported: false, service: simulator).header(for: Data())
        }
        #expect(await api.challenges == 0)
    }

    @Test func aDebugBuildStillAttestsOnARealPhone() async throws {
        let header = try await attestor(skipWhenUnsupported: true).header(for: Data())

        #expect(header != nil)
    }

    @Test func aLostKeyIsReplacedOnce() async throws {
        try keys.save(FakeAppAttest.keyId(9))
        service.failAssertion(with: .invalidKey)

        let header = try #require(await attestor().header(for: Data("a".utf8)))

        #expect(header.contains("keyId=\(FakeAppAttest.keyId(1)) "))
        #expect(try keys.load() == FakeAppAttest.keyId(1))
    }

    @Test func appleBeingUnavailableIsRetryable() async throws {
        try keys.save(FakeAppAttest.keyId(9))
        service.failAssertion(with: .unavailable)

        await #expect(throws: AuthAPIError.providerUnavailable) {
            _ = try await attestor().header(for: Data())
        }
        #expect(try keys.load() == FakeAppAttest.keyId(9))
    }

    @Test func aRefusedKeyIsNotKept() async throws {
        await api.set(registerError: .attestationFailed)

        await #expect(throws: AuthAPIError.attestationFailed) {
            _ = try await attestor().header(for: Data())
        }
        #expect(try keys.load() == nil)
    }

    @Test func discardingTheKeyRegistersANewOne() async throws {
        let attestor = attestor()
        _ = try await attestor.header(for: Data())
        await attestor.discardKey()
        _ = try await attestor.header(for: Data())

        #expect(service.generatedKeys == 2)
        #expect(try keys.load() == FakeAppAttest.keyId(2))
    }
}

/// The fake API's answers in turn; the last one repeats.
final class Answers: @unchecked Sendable {
    private let lock = NSLock()
    private var replies: [MockReply]

    init(_ replies: [MockReply]) {
        self.replies = replies
    }

    func next() -> MockReply {
        lock.withLock { replies.count > 1 ? replies.removeFirst() : replies[0] }
    }
}

/// `POST /v1/devices` and `PUT /v1/keys/identity` carry the header; the key registration follows the contract.
@Suite(.serialized)
struct HTTPAppAttestTests {
    static let host = "attest.test.invalid"
    let base = URL(string: "https://\(host)")!
    let service = FakeAppAttest()
    let keys = InMemoryAppAttestKeyStore()

    var registerFixture: ContractFixture {
        get throws { try ContractFixture.load("register-device") }
    }

    func deviceKeys() throws -> DeviceKeys {
        try JSONDecoder().decode(
            DeviceKeys.self, from: JSONSerialization.data(withJSONObject: #require(registerFixture.request))
        )
    }

    /// An API whose `/v1/devices` answers `devices` (in turn) and whose key registration follows the fixtures.
    func api(skip: Bool = false, devices: [MockReply]) throws -> HTTPAuthAPI {
        let challenge = try ContractFixture.load("attestation-challenge").reply
        let answers = Answers(devices)
        let session = MockURLProtocol.session(host: Self.host) { request, _ in
            switch request.url?.path {
            case "/v1/attestation/challenge": challenge
            case "/v1/attestation/apple": MockReply(204)
            default: answers.next()
            }
        }
        let plain = HTTPAuthAPI(baseURL: base, session: session)
        let attestor = AppAttestor(service: service, keys: keys, api: plain, skipWhenUnsupported: skip)
        return HTTPAuthAPI(baseURL: base, session: session, attestor: attestor)
    }

    var sent: [(request: URLRequest, body: Data?)] {
        MockURLProtocol.requests(host: Self.host)
    }

    func header(of request: URLRequest) -> String? {
        request.value(forHTTPHeaderField: "ZapaKid-Attestation")
    }

    @Test func registerDeviceSendsTheContractHeaderOverTheExactBody() async throws {
        let created = try ContractFixture.load("register-device").reply

        let deviceId = try await api(devices: [created]).registerDevice(deviceKeys(), token: "zks_tok")

        #expect(deviceId == 2)
        #expect(sent.map { $0.request.url?.path } == [
            "/v1/attestation/challenge", "/v1/attestation/apple", "/v1/devices",
        ])
        let register = try #require(sent.last)
        let header = try #require(header(of: register.request))
        #expect(header.wholeMatch(of: AppAttestTests.headerPattern) != nil)
        #expect(try header == registerFixture.requestHeaders["ZapaKid-Attestation"])
        #expect(try service.asserted.first?.hash == Data(SHA256.hash(data: #require(register.body))))
    }

    @Test func keyRegistrationSendsExactlyTheContractBody() async throws {
        let fixture = try ContractFixture.load("attestation-apple")
        let expected = try #require(fixture.request as? [String: Any])

        _ = try await api(devices: [ContractFixture.load("register-device").reply])
            .registerDevice(deviceKeys(), token: "zks_tok")

        let apple = try #require(sent.first { $0.request.url?.path == "/v1/attestation/apple" })
        #expect(apple.request.httpMethod == "POST")
        #expect(apple.request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(apple.body)
        #expect(try JSONSerialization.jsonObject(with: body) as? NSDictionary == expected as NSDictionary)
    }

    @Test func aKidIdentityChangeIsAttestedToo() async throws {
        let client = try api(devices: [MockReply(200, #"{"deviceId":1}"#)])

        _ = try await client.changeIdentity(deviceKeys(), token: "zkk_t")

        let put = try #require(sent.last)
        #expect(put.request.httpMethod == "PUT")
        #expect(put.request.url?.path == "/v1/keys/identity")
        #expect(header(of: put.request)?.wholeMatch(of: AppAttestTests.headerPattern) != nil)
    }

    @Test func aKeyTheAPIForgotIsReplacedOnce() async throws {
        try keys.save(FakeAppAttest.keyId(9))
        let refused = try ContractFixture.load("register-device-attestation-failed").reply
        let created = try ContractFixture.load("register-device").reply

        let deviceId = try await api(devices: [refused, created]).registerDevice(deviceKeys(), token: "t")

        #expect(deviceId == 2)
        let devices = sent.filter { $0.request.url?.path == "/v1/devices" }
        #expect(devices.count == 2)
        #expect(devices.first.flatMap { header(of: $0.request) }?.contains(FakeAppAttest.keyId(9)) == true)
        #expect(devices.last.flatMap { header(of: $0.request) }?.contains(FakeAppAttest.keyId(1)) == true)
        // Both tries upload the same body.
        #expect(devices.first?.body == devices.last?.body)
    }

    @Test func aSecondRefusalIsFinal() async throws {
        let refused = try ContractFixture.load("register-device-attestation-failed").reply

        await #expect(throws: AuthAPIError.attestationFailed) {
            _ = try await api(devices: [refused]).registerDevice(deviceKeys(), token: "t")
        }
        #expect(sent.filter { $0.request.url?.path == "/v1/devices" }.count == 2)
    }

    @Test func theSimulatorInADebugBuildSendsNoHeader() async throws {
        let simulator = FakeAppAttest(supported: false)
        let session = MockURLProtocol.session(host: Self.host) { _, _ in MockReply(201, #"{"deviceId":2}"#) }
        let attestor = AppAttestor(
            service: simulator, keys: keys, api: HTTPAuthAPI(baseURL: base, session: session),
            skipWhenUnsupported: true
        )
        let client = HTTPAuthAPI(baseURL: base, session: session, attestor: attestor)

        let deviceId = try await client.registerDevice(deviceKeys(), token: "t")

        #expect(deviceId == 2)
        #expect(sent.map { $0.request.url?.path } == ["/v1/devices"])
        #expect(sent.first.flatMap { header(of: $0.request) } == nil)
    }

    @Test(arguments: [
        ("attestation-challenge-rate-limited", AuthAPIError.rateLimited(retryAfter: 60)),
    ])
    func challengeErrors(name: String, expected: AuthAPIError) async throws {
        let reply = try ContractFixture.load(name).reply
        let session = MockURLProtocol.session(host: Self.host) { _, _ in reply }

        await #expect(throws: expected) {
            _ = try await HTTPAuthAPI(baseURL: base, session: session).attestationChallenge()
        }
    }

    @Test func aRefusedAttestationIsAttestationFailed() async throws {
        let reply = try ContractFixture.load("attestation-apple-failed").reply
        let session = MockURLProtocol.session(host: Self.host) { _, _ in reply }

        await #expect(throws: AuthAPIError.attestationFailed) {
            try await HTTPAuthAPI(baseURL: base, session: session)
                .registerAppAttestKey(keyId: FakeAppAttest.keyId(1), attestationObject: Data(), challenge: "c")
        }
    }
}
