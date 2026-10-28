import Foundation

/// The public keys this phone publishes (`DeviceKeys` in openapi.yaml, `POST /v1/devices`): only public keys and the
/// identity's signatures over them, base64. The private parts never leave the phone.
public struct DeviceKeys: Codable, Equatable, Sendable {
    public struct PreKey: Codable, Equatable, Sendable {
        public var keyId: UInt32
        public var publicKey: String

        public init(keyId: UInt32, publicKey: String) {
            self.keyId = keyId
            self.publicKey = publicKey
        }
    }

    public struct SignedPreKey: Codable, Equatable, Sendable {
        public var keyId: UInt32
        public var publicKey: String
        public var signature: String

        public init(keyId: UInt32, publicKey: String, signature: String) {
            self.keyId = keyId
            self.publicKey = publicKey
            self.signature = signature
        }
    }

    public var registrationId: UInt32
    public var identityKey: String
    public var signedPreKey: SignedPreKey
    public var pqLastResortPreKey: SignedPreKey
    public var preKeys: [PreKey]
    public var pqPreKeys: [SignedPreKey]

    public init(
        registrationId: UInt32, identityKey: String, signedPreKey: SignedPreKey, pqLastResortPreKey: SignedPreKey,
        preKeys: [PreKey], pqPreKeys: [SignedPreKey]
    ) {
        self.registrationId = registrationId
        self.identityKey = identityKey
        self.signedPreKey = signedPreKey
        self.pqLastResortPreKey = pqLastResortPreKey
        self.preKeys = preKeys
        self.pqPreKeys = pqPreKeys
    }
}

/// How many one-time prekeys the server still has for this phone (top up below 20).
public struct PreKeyCount: Codable, Equatable, Sendable {
    public var preKeys: Int
    public var pqPreKeys: Int

    public init(preKeys: Int, pqPreKeys: Int) {
        self.preKeys = preKeys
        self.pqPreKeys = pqPreKeys
    }
}

/// The key directory (openapi.yaml tag "Devices and keys").
public protocol DeviceAPI: Sendable {
    /// `POST /v1/devices` → the libsignal device ID (1...127).
    func registerDevice(_ keys: DeviceKeys, token: String) async throws -> Int
    /// `GET /v1/accounts/{id}/identity` → the account's identity key (base64), or nil when it has none yet (404).
    func accountIdentity(accountId: String, token: String) async throws -> String?
    /// `GET /v1/keys/prekeys`.
    func preKeyCount(token: String) async throws -> PreKeyCount
    /// `PUT /v1/keys/identity` → this phone's device id (it becomes the account's only device).
    func changeIdentity(_ keys: DeviceKeys, token: String) async throws -> Int
}
