import Foundation
import ZapaKidKit

/// Keeps this phone's VoIP push target on the server, so a call can ring it while the app is closed.
/// The token can arrive before the phone is registered (or the reverse); whichever comes last sends it.
@MainActor
final class PushTargetSync {
    private let api: DevicePushAPI
    private let sessionToken: () -> String?
    private let deviceId: () -> Int?
    /// The target PushKit last gave us (nil: none, or invalidated).
    private var wanted: PushTarget?
    /// The target the server has (nil: none).
    private var synced: PushTarget?

    init(api: DevicePushAPI, token: @escaping () -> String?, deviceId: @escaping () -> Int?) {
        self.api = api
        sessionToken = token
        self.deviceId = deviceId
    }

    /// PushKit gave a new token (hex-encoded), or invalidated the old one (nil).
    func voipTokenChanged(_ hex: String?) async {
        wanted = hex.map { PushTarget(provider: .apns, token: $0) }
        await sync()
    }

    /// The phone was registered (or re-registered), so it has a device ID to send the target for.
    func deviceRegistered() async {
        await sync()
    }

    private func sync() async {
        guard let token = sessionToken(), let deviceId = deviceId(), wanted != synced else { return }
        do {
            try await api.setDevicePush(deviceId: deviceId, target: wanted, token: token)
            synced = wanted
        } catch {
            // Left unsynced: the next token change or registration tries again.
        }
    }

    /// PushKit's token bytes as the server expects them.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
