import CryptoKit
import Foundation
import Security
#if canImport(DeviceCheck)
    import DeviceCheck
#endif

/// Apple App Attest (`DCAppAttestService`) behind a protocol, so tests use a fake. The simulator has none.
public protocol AppAttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data
}

/// What `AppAttestService` fails with, so the attestor can react without knowing DeviceCheck.
public enum AppAttestServiceError: Error, Equatable, Sendable {
    /// No App Attest here (simulator, some Macs).
    case unsupported
    /// The key is gone or unusable (e.g. the Keychain item outlived a reinstall): make a new one.
    case invalidKey
    /// Apple's service or the system failed this time; trying again later can work.
    case unavailable
}

/// Where the App Attest key ID is kept (one per app install, not per account: parents and kids share it).
public protocol AppAttestKeyStore: Sendable {
    func load() throws -> String?
    func save(_ keyId: String) throws
    func clear() throws
}

/// The API's key registration (openapi.yaml tag "App attestation").
public protocol AppAttestAPI: Sendable {
    /// `POST /v1/attestation/challenge` → the challenge (single use, 5 minutes).
    func attestationChallenge() async throws -> String
    /// `POST /v1/attestation/apple` `{keyId, attestationObject, challenge}` → 204.
    func registerAppAttestKey(keyId: String, attestationObject: Data, challenge: String) async throws
}

/// The `ZapaKid-Attestation` header for a request, as `src/app-attest.ts` in zapakid-api expects:
/// 1. once per install: `generateKey()`, `POST /v1/attestation/challenge`, `attestKey(keyId, SHA-256(challenge))`,
///    `POST /v1/attestation/apple`; the key ID is then kept (Keychain);
/// 2. every attested request: `v1 keyId=<base64> assertion=<base64>`, the assertion over SHA-256(exact body bytes).
///
/// Where App Attest isn't available (the simulator), `skipWhenUnsupported` (debug builds only) sends no header: the
/// API then accepts the request only on staging and only for allowlisted test accounts. Release builds never skip.
public actor AppAttestor {
    public static let headerName = "ZapaKid-Attestation"

    private let service: AppAttestService
    private let keys: AppAttestKeyStore
    private let api: AppAttestAPI
    private let skipWhenUnsupported: Bool

    public init(service: AppAttestService, keys: AppAttestKeyStore, api: AppAttestAPI, skipWhenUnsupported: Bool) {
        self.service = service
        self.keys = keys
        self.api = api
        self.skipWhenUnsupported = skipWhenUnsupported
    }

    /// The header for `body`, or nil when this debug build runs where App Attest isn't available.
    /// Throws `AuthAPIError` (`attestationFailed`, `providerUnavailable`, `network`, `rateLimited`, ...).
    public func header(for body: Data) async throws -> String? {
        guard service.isSupported else {
            if skipWhenUnsupported {
                return nil
            }
            throw AuthAPIError.attestationFailed
        }
        let clientDataHash = Data(SHA256.hash(data: body))
        let keyId = try await registeredKey()
        do {
            return try await Self.header(keyId: keyId, assertion: assertion(keyId, clientDataHash))
        } catch AppAttestServiceError.invalidKey {
            // The stored key no longer works on this phone: one new key, then give up.
            try? keys.clear()
            let fresh = try await registeredKey()
            do {
                return try await Self.header(keyId: fresh, assertion: assertion(fresh, clientDataHash))
            } catch AppAttestServiceError.invalidKey {
                throw AuthAPIError.attestationFailed
            }
        }
    }

    /// Forgets the key (the API refused it: unknown, unused for 180 days); the next header registers a new one.
    public func discardKey() {
        try? keys.clear()
    }

    static func header(keyId: String, assertion: Data) -> String {
        "v1 keyId=\(keyId) assertion=\(assertion.base64EncodedString())"
    }

    private func assertion(_ keyId: String, _ clientDataHash: Data) async throws -> Data {
        do {
            return try await service.generateAssertion(keyId, clientDataHash: clientDataHash)
        } catch let error as AppAttestServiceError where error != .invalidKey {
            throw Self.apiError(error)
        }
    }

    /// The stored key, or a new one attested with the API (stored only once the API accepted it). Concurrent
    /// callers share one registration: the actor runs other calls while this one waits for the network.
    private func registeredKey() async throws -> String {
        if let keyId = try keys.load() {
            return keyId
        }
        if let registering {
            return try await registering.value
        }
        let task = Task { try await register() }
        registering = task
        defer { registering = nil }
        return try await task.value
    }

    private var registering: Task<String, Error>?

    private func register() async throws -> String {
        do {
            let keyId = try await service.generateKey()
            let challenge = try await api.attestationChallenge()
            let hash = Data(SHA256.hash(data: Data(challenge.utf8)))
            let object = try await service.attestKey(keyId, clientDataHash: hash)
            try await api.registerAppAttestKey(keyId: keyId, attestationObject: object, challenge: challenge)
            try keys.save(keyId)
            return keyId
        } catch let error as AppAttestServiceError {
            throw Self.apiError(error)
        }
    }

    private static func apiError(_ error: AppAttestServiceError) -> AuthAPIError {
        switch error {
        case .unsupported, .invalidKey: .attestationFailed
        case .unavailable: .providerUnavailable
        }
    }
}

/// The key ID in the Keychain: readable only while unlocked, this device only, never synced or backed up (an App
/// Attest key can't move to another phone anyway).
public struct KeychainAppAttestKeyStore: AppAttestKeyStore {
    public let service: String
    private let account = "app-attest-key"

    public init(service: String = "ro.zapakid.app.app-attest") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    public func load() throws -> String? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainError(status: status) }
        return String(data: data, encoding: .utf8)
    }

    public func save(_ keyId: String) throws {
        try clear()
        var item = baseQuery
        item[kSecValueData as String] = Data(keyId.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

/// A key store in memory, for tests.
public final class InMemoryAppAttestKeyStore: AppAttestKeyStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keyId: String?

    public init(keyId: String? = nil) {
        self.keyId = keyId
    }

    public func load() throws -> String? {
        lock.withLock { keyId }
    }

    public func save(_ keyId: String) throws {
        lock.withLock { self.keyId = keyId }
    }

    public func clear() throws {
        lock.withLock { keyId = nil }
    }
}

#if canImport(DeviceCheck)
    /// The real `DCAppAttestService`, its errors mapped to `AppAttestServiceError`.
    public struct DeviceCheckAppAttest: AppAttestService {
        public init() {}

        public var isSupported: Bool {
            DCAppAttestService.shared.isSupported
        }

        public func generateKey() async throws -> String {
            try await mapped { try await DCAppAttestService.shared.generateKey() }
        }

        public func attestKey(_ keyId: String, clientDataHash: Data) async throws -> Data {
            try await mapped { try await DCAppAttestService.shared.attestKey(keyId, clientDataHash: clientDataHash) }
        }

        public func generateAssertion(_ keyId: String, clientDataHash: Data) async throws -> Data {
            try await mapped {
                try await DCAppAttestService.shared.generateAssertion(keyId, clientDataHash: clientDataHash)
            }
        }

        private func mapped<T>(_ work: () async throws -> T) async throws -> T {
            do {
                return try await work()
            } catch let error as DCError {
                switch error.code {
                case .featureUnsupported: throw AppAttestServiceError.unsupported
                case .invalidKey, .invalidInput: throw AppAttestServiceError.invalidKey
                default: throw AppAttestServiceError.unavailable
                }
            } catch {
                throw AppAttestServiceError.unavailable
            }
        }
    }
#endif
