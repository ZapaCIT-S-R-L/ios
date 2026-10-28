import Foundation
import Testing
@testable import ZapaKidKit

/// The device-registration client (openapi.yaml tag "Devices and keys") against the contract fixtures.
@Suite(.serialized)
struct DeviceAPIContractTests {
    let base = URL(string: "https://api.test.invalid")!

    func api(_ name: String) throws -> HTTPAuthAPI {
        let reply = try ContractFixture.load(name).reply
        return HTTPAuthAPI(baseURL: base, session: MockURLProtocol.session { _, _ in reply })
    }

    func api(status: Int, body: String) -> HTTPAuthAPI {
        HTTPAuthAPI(baseURL: base, session: MockURLProtocol.session { _, _ in MockReply(status, body) })
    }

    var sent: (request: URLRequest, body: Data?)? {
        MockURLProtocol.requests.first
    }

    @Test func registerDeviceSendsExactlyTheContractBody() async throws {
        let fixture = try ContractFixture.load("register-device")
        let expected = try #require(fixture.request as? [String: Any])
        let keys = try JSONDecoder().decode(DeviceKeys.self, from: JSONSerialization.data(withJSONObject: expected))

        let deviceId = try await api("register-device").registerDevice(keys, token: "zks_tok")

        #expect(deviceId == 2)
        let request = try #require(sent)
        #expect(request.request.httpMethod == "POST")
        #expect(request.request.url?.path == "/v1/devices")
        #expect(request.request.value(forHTTPHeaderField: "Authorization") == "Bearer zks_tok")
        let body = try #require(request.body)
        #expect(try JSONSerialization.jsonObject(with: body) as? NSDictionary == expected as NSDictionary)
    }

    @Test(arguments: [0, 128])
    func deviceIdOutsideTheContractIsRejected(deviceId: Int) async throws {
        let keys = try JSONDecoder().decode(
            DeviceKeys.self,
            from: JSONSerialization.data(withJSONObject: #require(ContractFixture.load("register-device").request))
        )

        await #expect(throws: AuthAPIError.invalidResponse) {
            try await api(status: 201, body: #"{"deviceId":\#(deviceId)}"#).registerDevice(keys, token: "t")
        }
    }

    @Test(arguments: [
        ("register-device-identity-mismatch", AuthAPIError.identityMismatch),
        ("register-device-too-many", .server(status: 409, code: "too_many_devices")),
        ("register-device-invalid-keys", .server(status: 400, code: "invalid_keys")),
        ("register-device-unauthorized", .unauthorized),
        ("register-device-attestation-failed", .attestationFailed),
        ("register-device-rate-limited", .rateLimited(retryAfter: 60)),
    ])
    func registerDeviceErrors(name: String, expected: AuthAPIError) async throws {
        let keys = try JSONDecoder().decode(
            DeviceKeys.self,
            from: JSONSerialization.data(withJSONObject: #require(ContractFixture.load("register-device").request))
        )

        await #expect(throws: expected) { try await api(name).registerDevice(keys, token: "t") }
    }

    @Test func accountIdentityWhenThereIsOne() async throws {
        let key = try await api("account-identity").accountIdentity(accountId: "6f1c0e2a", token: "zks_tok")

        #expect(try key == (ContractFixture.load("account-identity").bodyJSON?["identityKey"] as? String))
        let request = try #require(sent)
        #expect(request.request.httpMethod == "GET")
        #expect(request.request.url?.path == "/v1/accounts/6f1c0e2a/identity")
        #expect(request.request.value(forHTTPHeaderField: "Authorization") == "Bearer zks_tok")
    }

    @Test func accountIdentityNotFoundMeansNone() async throws {
        let key = try await api("account-identity-none").accountIdentity(accountId: "a", token: "t")

        #expect(key == nil)
    }

    @Test func accountIdIsEscapedInThePath() async throws {
        _ = try await api("account-identity-none").accountIdentity(accountId: "../me", token: "t")

        let url = try #require(sent?.request.url?.absoluteString)
        #expect(url == "https://api.test.invalid/v1/accounts/..%2Fme/identity", "an ID can't change the path")
    }

    @Test func preKeyCount() async throws {
        let count = try await api("prekey-count").preKeyCount(token: "zks_tok")

        #expect(count == PreKeyCount(preKeys: 17, pqPreKeys: 19))
        #expect(sent?.request.url?.path == "/v1/keys/prekeys")
    }

    @Test func preKeyCountBeforeRegistering() async throws {
        await #expect(throws: AuthAPIError.server(status: 409, code: "device_not_registered")) {
            try await api("prekey-count-not-registered").preKeyCount(token: "t")
        }
    }
}

extension ContractFixture {
    var bodyJSON: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }
}
