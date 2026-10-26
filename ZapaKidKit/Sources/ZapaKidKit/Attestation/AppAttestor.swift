import CryptoKit
import DeviceCheck
import Foundation

/// Apple's App Attest (DCAppAttestService), behind a protocol so tests can use a fake.
public protocol AppAttestService: Sendable {
    var isSupported: Bool { get }
    func generateKey() async throws -> String
    func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data
    func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data
}

/// The real one. The private key never leaves the Secure Enclave; the app only keeps its key ID.
public struct DeviceCheckAppAttestService: AppAttestService {
    public init() {}

    public var isSupported: Bool {
        DCAppAttestService.shared.isSupported
    }

    public func generateKey() async throws -> String {
        try await DCAppAttestService.shared.generateKey()
    }

    public func attestKey(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.attestKey(keyID, clientDataHash: clientDataHash)
    }

    public func generateAssertion(_ keyID: String, clientDataHash: Data) async throws -> Data {
        try await DCAppAttestService.shared.generateAssertion(keyID, clientDataHash: clientDataHash)
    }
}

/// The attestation endpoints (openapi.yaml tag `Draft: App attestation`). They need no session and no attestation.
public protocol AttestationAPI: Sendable {
    func attestationChallenge() async throws -> String
    func registerAppleKey(keyID: String, attestationObject: Data, challenge: String) async throws
}

/// Proves to the API that a request comes from a genuine ZapaKid app on a genuine iPhone.
///
/// The first time: a new App Attest key, a one-time challenge from the API, an attestation over SHA-256(challenge),
/// registered with `POST /v1/attestation/apple`. Then every sign-in carries an assertion over SHA-256 of its exact
/// body in the `ZapaKid-Attestation` header; the API checks the signature and that the counter goes up. All
/// cryptography is Apple's (Secure Enclave key, SHA-256); the app adds none.
public actor AppAttestor {
    private let service: AppAttestService
    private let api: AttestationAPI
    private let keyStore: KeychainItem

    public init(
        service: AppAttestService = DeviceCheckAppAttestService(),
        api: AttestationAPI,
        keyStore: KeychainItem = KeychainItem(service: "ro.zapakid.app.appattest", account: "keyId")
    ) {
        self.service = service
        self.api = api
        self.keyStore = keyStore
    }

    /// The header value for a request with this body, or nil where App Attest isn't supported (the simulator).
    /// Draft format, to be confirmed with the API: `v1 keyId=<key ID> assertion=<base64 assertion>`.
    public func header(for body: Data) async throws -> String? {
        guard service.isSupported else { return nil }
        let keyID = try await registeredKeyID()
        let assertion = try await service.generateAssertion(keyID, clientDataHash: Data(SHA256.hash(data: body)))
        return Self.header(keyID: keyID, assertion: assertion)
    }

    /// After the API refused an assertion (`403 attestation_failed`): forget the key, so the next request attests a
    /// new one (for example after a restore to a new phone, where the old key doesn't work).
    public func reset() {
        try? keyStore.clear()
    }

    static func header(keyID: String, assertion: Data) -> String {
        "v1 keyId=\(keyID) assertion=\(assertion.base64EncodedString())"
    }

    private func registeredKeyID() async throws -> String {
        if let stored = try keyStore.load(), let keyID = String(data: stored, encoding: .utf8) {
            return keyID
        }
        let keyID = try await service.generateKey()
        let challenge = try await api.attestationChallenge()
        let attestation = try await service.attestKey(
            keyID,
            clientDataHash: Data(SHA256.hash(data: Data(challenge.utf8)))
        )
        try await api.registerAppleKey(keyID: keyID, attestationObject: attestation, challenge: challenge)
        try keyStore.save(Data(keyID.utf8))
        return keyID
    }
}
