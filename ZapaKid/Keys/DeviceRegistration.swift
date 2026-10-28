import Foundation
import LibSignalClient
import ZapaKidKit

/// What registering this phone ended with. The home screen shows it (next PR).
enum DeviceSetupResult: Equatable {
    case ready(deviceId: Int)
    /// The account has an identity this phone doesn't have yet; another family phone must re-share it.
    case waitingForReshare
    /// The session is gone: sign in again.
    case signedOut
    case failed(Reason)

    enum Reason: Equatable {
        case network
        /// The key directory knows another identity for this account; nothing was uploaded.
        case identityMismatch
        case rateLimited
        case attestationFailed
        case server
    }
}

/// Registers this phone with the key directory (`POST /v1/devices`), as the Android app does:
/// 1. ask the directory whether the account already has an identity;
/// 2. use the synced identity, or wait for a re-share (and upload nothing);
/// 3. make this phone's keys once and keep the public payload until the upload succeeds, so a retry sends the same
///    keys (the server then answers with the same device ID);
/// 4. keep the device ID; after that, no more network work.
@MainActor
final class DeviceRegistration {
    private let api: DeviceAPI
    private let identity: LocalIdentityStore
    private let files: ProtectedFileStore
    private let reshare: IdentityReshare
    private let oneTimeCount: Int

    private static let deviceFile = "device.json"
    private static let pendingFile = "pending-device-keys.json"

    private struct Registered: Codable {
        var deviceId: Int
    }

    init(
        api: DeviceAPI, identity: LocalIdentityStore, files: ProtectedFileStore, reshare: IdentityReshare,
        oneTimeCount: Int = DeviceKeyGenerator.maxOneTime
    ) {
        self.api = api
        self.identity = identity
        self.files = files
        self.reshare = reshare
        self.oneTimeCount = oneTimeCount
    }

    func run(session: Session) async -> DeviceSetupResult {
        do {
            if let data = try files.read(Self.deviceFile) {
                return try .ready(deviceId: JSONDecoder().decode(Registered.self, from: data).deviceId)
            }
            let directoryKey = try await api.accountIdentity(accountId: session.parent.id, token: session.token)
            guard case let .ready(local) = try identity.resolve(
                accountHasIdentity: directoryKey != nil, reshare: reshare
            ) else {
                return .waitingForReshare
            }
            let ourKey = local.keyPair.identityKey.serialize().base64EncodedString()
            if let directoryKey, directoryKey != ourKey {
                return .failed(.identityMismatch)
            }
            let keys = try pendingKeys(for: local)
            let deviceId = try await api.registerDevice(keys, token: session.token)
            try files.write(JSONEncoder().encode(Registered(deviceId: deviceId)), to: Self.deviceFile)
            try files.delete(Self.pendingFile)
            return .ready(deviceId: deviceId)
        } catch let error as AuthAPIError {
            return Self.result(for: error)
        } catch {
            return .failed(.server)
        }
    }

    /// The keys from an earlier failed upload, or new ones (private records stored, public payload kept).
    private func pendingKeys(for local: LocalIdentity) throws -> DeviceKeys {
        if let data = try files.read(Self.pendingFile),
           let keys = try? JSONDecoder().decode(DeviceKeys.self, from: data),
           keys.identityKey == local.keyPair.identityKey.serialize().base64EncodedString()
        {
            return keys
        }
        let store = try ZapaKidProtocolStore(identity: local, files: files)
        let keys = try DeviceKeyGenerator(store: store).generate(oneTimeCount: oneTimeCount)
        try files.write(JSONEncoder().encode(keys), to: Self.pendingFile)
        return keys
    }

    private static func result(for error: AuthAPIError) -> DeviceSetupResult {
        switch error {
        case .unauthorized: .signedOut
        case .identityMismatch: .failed(.identityMismatch)
        case .rateLimited: .failed(.rateLimited)
        case .attestationFailed: .failed(.attestationFailed)
        case .network: .failed(.network)
        default: .failed(.server)
        }
    }
}
