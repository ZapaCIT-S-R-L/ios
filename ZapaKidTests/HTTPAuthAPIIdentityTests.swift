import Foundation
import Testing
@testable import ZapaKidKit

/// `PUT /v1/keys/identity` (api PR #74): a replaced kid phone (or a reset) takes over the account's identity.
extension HTTPAuthAPITests {
    var keysJSON: DeviceKeys {
        DeviceKeys(
            registrationId: 7, identityKey: "BQ==",
            signedPreKey: .init(keyId: 1, publicKey: "BQ==", signature: "AA=="),
            pqLastResortPreKey: .init(keyId: 2, publicKey: "CA==", signature: "AA=="),
            preKeys: [], pqPreKeys: []
        )
    }

    @Test func identityChangeIsAPutWithTheNewKeys() async throws {
        let client = api { _, _ in MockReply(200, #"{"deviceId":1}"#) }

        let device = try await client.changeIdentity(keysJSON, token: "zkk_t")

        #expect(device == 1)
        let sent = try #require(MockURLProtocol.requests.first)
        #expect(sent.request.httpMethod == "PUT")
        #expect(sent.request.url?.path == "/v1/keys/identity")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer zkk_t")
        #expect(sent.body?.json?["identityKey"] as? String == "BQ==")
    }

    @Test func aStalePairingNeedsReauthentication() async {
        let client = api { _, _ in MockReply(403, #"{"error":{"code":"reauthentication_required"}}"#) }

        await #expect(throws: AuthAPIError.reauthenticationRequired) {
            _ = try await client.changeIdentity(keysJSON, token: "zkk_t")
        }
    }
}
