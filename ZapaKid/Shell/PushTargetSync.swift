import Foundation
import ZapaKidKit

/// Keeps one of this phone's push targets on the server: the VoIP token (a call rings the phone while the app is
/// closed) or the APNs alert token (a chat message shows a notification). The token can arrive before the phone is
/// registered (or the reverse); whichever comes last sends it.
@MainActor
final class PushTargetSync {
    /// Which target this sync keeps. The two never share a value: each has its own endpoint and its own state.
    enum Channel: Equatable {
        case voip
        case alert
    }

    private let api: DevicePushAPI
    private let channel: Channel
    private let sessionToken: () -> String?
    private let deviceId: () -> Int?
    /// What PushKit last said: a target, or nil once it invalidated the token. Unknown until it reports either.
    private var wanted: Known = .unknown
    /// What the server has. Unknown at launch: it may still hold the token from the previous launch.
    private var synced: Known = .unknown
    /// A request is on its way; that sync sends the newest target when it returns, so updates never overlap.
    private var syncing = false
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    /// Set once the account signed out: this sync is finished.
    private var signedOut = false
    private var signOutCredentials: (token: String, deviceId: Int)?

    enum Known: Equatable {
        case unknown
        case known(PushTarget?)
    }

    init(
        api: DevicePushAPI, channel: Channel = .voip, token: @escaping () -> String?, deviceId: @escaping () -> Int?
    ) {
        self.api = api
        self.channel = channel
        sessionToken = token
        self.deviceId = deviceId
    }

    /// The token changed (hex-encoded), or was invalidated (nil). PushKit's token for `.voip`, APNs's for `.alert`.
    func tokenChanged(_ hex: String?) async {
        guard !signedOut else { return }
        wanted = .known(hex.map { PushTarget(provider: .apns, token: $0) })
        await sync()
    }

    /// Stops callbacks immediately, then clears after any outstanding update while credentials still work.
    /// A failed clear never prevents local sign-out. The next account gets its own sync.
    func signOut() async {
        guard !signedOut else { return }
        signedOut = true
        if let token = sessionToken(), let deviceId = deviceId() {
            signOutCredentials = (token, deviceId)
        }
        wanted = .known(nil)
        if syncing {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
        await sync()
    }

    /// The phone was registered (or re-registered), so it has a device ID to send the target for.
    func deviceRegistered() async {
        guard !signedOut else { return }
        await sync()
    }

    /// Sends what PushKit last said until the server has it. One request at a time: a change that arrives while a
    /// request is out is sent after it, so the server always ends with the newest target and `synced` is only ever
    /// set to the target that request carried.
    private func sync() async {
        guard !syncing else { return }
        syncing = true
        defer {
            syncing = false
            let waiters = idleWaiters
            idleWaiters.removeAll()
            for waiter in waiters {
                waiter.resume()
            }
        }
        while case let .known(target) = wanted, synced != wanted {
            let credentials: (token: String, deviceId: Int)? = if signedOut {
                signOutCredentials
            } else if let token = sessionToken(), let deviceId = deviceId() {
                (token, deviceId)
            } else {
                nil
            }
            guard let (token, deviceId) = credentials else { return }
            do {
                switch channel {
                case .voip:
                    try await api.setDevicePush(deviceId: deviceId, target: target, token: token)
                case .alert:
                    try await api.setDeviceAlertPush(deviceId: deviceId, target: target, token: token)
                }
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

    /// The token's bytes as the server expects them.
    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
