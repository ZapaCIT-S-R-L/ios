import Foundation
import ZapaKidKit

/// Keeps this phone's VoIP push target on the server, so a call can ring it while the app is closed.
/// The token can arrive before the phone is registered (or the reverse); whichever comes last sends it.
@MainActor
final class PushTargetSync {
    private let api: DevicePushAPI
    private let sessionToken: () -> String?
    private let deviceId: () -> Int?
    /// What PushKit last said: a target, or nil once it invalidated the token. Unknown until it reports either.
    private var wanted: Known = .unknown
    /// What the server has. Unknown at launch: it may still hold the token from the previous launch.
    private var synced: Known = .unknown
    /// A request is on its way; that sync sends the newest target when it returns, so updates never overlap.
    private var syncing = false

    enum Known: Equatable {
        case unknown
        case known(PushTarget?)
    }

    init(api: DevicePushAPI, token: @escaping () -> String?, deviceId: @escaping () -> Int?) {
        self.api = api
        sessionToken = token
        self.deviceId = deviceId
    }

    /// PushKit gave a new token (hex-encoded), or invalidated the old one (nil).
    func voipTokenChanged(_ hex: String?) async {
        wanted = .known(hex.map { PushTarget(provider: .apns, token: $0) })
        await sync()
    }

    /// The phone was registered (or re-registered), so it has a device ID to send the target for.
    func deviceRegistered() async {
        await sync()
    }

    /// Sends what PushKit last said until the server has it. One request at a time: a change that arrives while a
    /// request is out is sent after it, so the server always ends with the newest target and `synced` is only ever
    /// set to the target that request carried.
    private func sync() async {
        guard !syncing else { return }
        syncing = true
        defer { syncing = false }
        while case let .known(target) = wanted, synced != wanted, let token = sessionToken(),
              let deviceId = deviceId()
        {
            do {
                try await api.setDevicePush(deviceId: deviceId, target: target, token: token)
                synced = .known(target)
            } catch {
                // A newer target arrived while this request was out: send it now rather than wait for a callback.
                if wanted != .known(target) {
                    continue
                }
                return // Left unsynced: the next token change or registration tries again.
            }
        }
    }

    /// PushKit's token bytes as the server expects them.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
