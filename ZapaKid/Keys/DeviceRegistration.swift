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
    /// A kid phone whose account has another identity, and the pairing is over 10 minutes old: a parent must pair
    /// it again.
    case needsPairing
    /// The session that started this is no longer the signed-in one (signed out, another account signed in): stop,
    /// and leave the current session alone.
    case superseded
    case failed(Reason)

    enum Reason: Equatable {
        /// Retried: no connection.
        case network
        /// Retried: too many requests.
        case rateLimited
        /// Retried: a 5xx, the sign-in provider being down, or a local error (e.g. the Keychain while locked).
        case server
        /// Not retried: not a genuine app on a genuine device (reinstall from the App Store).
        case attestationFailed
        /// Not retried: a 4xx or an answer outside the contract; trying again sends the same request.
        case rejected

        /// Whether trying again later can succeed without anyone doing anything.
        var isRetryable: Bool {
            switch self {
            case .network, .rateLimited, .server: true
            case .attestationFailed, .rejected: false
            }
        }
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
    /// The keys of one account (by account ID); see `AccountKeys`.
    private let keyspace: (String) throws -> AccountKeys
    private let reshare: IdentityReshare
    private let oneTimeCount: Int

    private static let deviceFile = "device.json"
    private static let pendingFile = "pending-device-keys.json"

    private struct Registered: Codable {
        var deviceId: Int
    }

    /// The device ID this account's phone was registered under, if it has been (see `run` and `runKid`).
    static func registeredDeviceId(in account: AccountKeys) -> Int? {
        guard let data = try? account.files.read(deviceFile) else { return nil }
        return (try? JSONDecoder().decode(Registered.self, from: data))?.deviceId
    }

    init(
        api: DeviceAPI,
        keyspace: @escaping (String) throws -> AccountKeys = { try AccountKeys.app(accountId: $0) },
        reshare: IdentityReshare,
        oneTimeCount: Int = DeviceKeyGenerator.maxOneTime
    ) {
        self.api = api
        self.keyspace = keyspace
        self.reshare = reshare
        self.oneTimeCount = oneTimeCount
    }

    func run(session: Session) async -> DeviceSetupResult {
        do {
            // Only this account's keys, never another account's on the same phone.
            let account = try keyspace(session.parent.id)
            let files = account.files
            if let data = try files.read(Self.deviceFile) {
                return try .ready(deviceId: JSONDecoder().decode(Registered.self, from: data).deviceId)
            }
            let directoryKey = try await api.accountIdentity(accountId: session.parent.id, token: session.token)
            guard case let .ready(local) = try account.identity.resolve(
                accountHasIdentity: directoryKey != nil, reshare: reshare
            ) else {
                return .waitingForReshare
            }
            let ourKey = local.keyPair.identityKey.serialize().base64EncodedString()
            if let directoryKey, directoryKey != ourKey {
                return .waitingForReshare
            }
            let keys = try pendingKeys(for: local, account: account)
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

    /// A kid's phone (kid session `zkk_…`, account = the kid's id): its own identity on this phone only. When the
    /// account already has another identity (a replaced phone), it takes over with `PUT /v1/keys/identity`, which
    /// the API allows within 10 minutes of pairing; later, a parent must pair the phone again.
    func runKid(accountId: String, token: String, pairedAt: Date?, now: Date = Date()) async -> DeviceSetupResult {
        let fresh = pairedAt.map { now.timeIntervalSince($0) < Self.identityChangeWindow } ?? false
        do {
            let account = try keyspace(accountId)
            let files = account.files
            if let data = try files.read(Self.deviceFile) {
                return try .ready(deviceId: JSONDecoder().decode(Registered.self, from: data).deviceId)
            }
            let local = try account.identity.load() ?? account.identity.createNew()
            let ourKey = local.keyPair.identityKey.serialize().base64EncodedString()
            let directoryKey = try await api.accountIdentity(accountId: accountId, token: token)
            let keys = try pendingKeys(for: local, account: account)
            let deviceId: Int
            if let directoryKey, directoryKey != ourKey {
                guard fresh else { return .needsPairing }
                deviceId = try await api.changeIdentity(keys, token: token)
            } else {
                do {
                    deviceId = try await api.registerDevice(keys, token: token)
                } catch AuthAPIError.identityMismatch {
                    guard fresh else { return .needsPairing }
                    deviceId = try await api.changeIdentity(keys, token: token)
                }
            }
            try files.write(JSONEncoder().encode(Registered(deviceId: deviceId)), to: Self.deviceFile)
            try files.delete(Self.pendingFile)
            return .ready(deviceId: deviceId)
        } catch AuthAPIError.reauthenticationRequired {
            return .needsPairing
        } catch AuthAPIError.identityMismatch {
            // A kid's identity lives on this phone only; nobody can re-share it.
            return .needsPairing
        } catch let error as AuthAPIError {
            return Self.result(for: error)
        } catch {
            return .failed(.server)
        }
    }

    /// `PUT /v1/keys/identity` needs a session under 10 minutes old (a kid: a fresh pairing).
    static let identityChangeWindow: TimeInterval = 10 * 60

    /// The keys from an earlier failed upload, or new ones (private records stored, public payload kept).
    private func pendingKeys(for local: LocalIdentity, account: AccountKeys) throws -> DeviceKeys {
        let files = account.files
        if let data = try files.read(Self.pendingFile),
           let keys = try? JSONDecoder().decode(DeviceKeys.self, from: data),
           keys.identityKey == local.keyPair.identityKey.serialize().base64EncodedString()
        {
            return keys
        }
        let store = try ZapaKidProtocolStore(identity: local, files: files, peers: account.peers)
        let keys = try DeviceKeyGenerator(store: store).generate(oneTimeCount: oneTimeCount)
        try files.write(JSONEncoder().encode(keys), to: Self.pendingFile)
        return keys
    }

    private static func result(for error: AuthAPIError) -> DeviceSetupResult {
        switch error {
        case .unauthorized: .signedOut
        case .identityMismatch: .waitingForReshare
        case .rateLimited: .failed(.rateLimited)
        case .attestationFailed: .failed(.attestationFailed)
        case .network: .failed(.network)
        case .providerUnavailable: .failed(.server)
        case let .server(status, _) where status >= 500: .failed(.server)
        default: .failed(.rejected)
        }
    }
}
