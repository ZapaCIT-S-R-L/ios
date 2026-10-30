import Foundation
import Testing
@testable import ZapaKidKit

/// `PUT /v1/devices/{deviceId}/push` (openapi.yaml, "Devices and keys"): where this phone's wake-ups go.
@Suite(.serialized)
struct DevicePushAPITests {
    let base = URL(string: "https://api.test.invalid")!

    func api() -> HTTPAuthAPI {
        HTTPAuthAPI(baseURL: base, session: MockURLProtocol.session { _, _ in MockReply(204) })
    }

    @Test func setsTheTargetWithItsProviderAndToken() async throws {
        try await api().setDevicePush(deviceId: 2, target: PushTarget(provider: .apns, token: "ab12"), token: "zks_tok")

        let sent = try #require(MockURLProtocol.requests.first)
        #expect(sent.request.httpMethod == "PUT")
        #expect(sent.request.url?.path == "/v1/devices/2/push")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer zks_tok")
        let body = try #require(sent.body)
        #expect(
            try JSONSerialization.jsonObject(with: body) as? NSDictionary
                == ["provider": "apns", "token": "ab12"] as NSDictionary
        )
    }

    @Test func clearingSendsBothFieldsAsNull() async throws {
        try await api().setDevicePush(deviceId: 1, target: nil, token: "zks_tok")

        let body = try #require(MockURLProtocol.requests.first?.body)
        #expect(
            try JSONSerialization.jsonObject(with: body) as? NSDictionary
                == ["provider": NSNull(), "token": NSNull()] as NSDictionary
        )
    }
}
