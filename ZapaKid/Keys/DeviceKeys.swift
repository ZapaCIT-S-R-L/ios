import Foundation
import LibSignalClient
import ZapaKidKit

/// Makes a fresh set of keys with libsignal, stores the private records, and returns what to publish:
/// a signed EC prekey, a signed Kyber last-resort prekey, and `oneTimeCount` one-time EC and Kyber prekeys.
struct DeviceKeyGenerator {
    let store: ZapaKidProtocolStore
    var now: () -> Date = { Date() }

    /// The API takes at most 100 of each per upload.
    static let maxOneTime = 100

    func generate(oneTimeCount: Int = DeviceKeyGenerator.maxOneTime) throws -> DeviceKeys {
        precondition((1 ... Self.maxOneTime).contains(oneTimeCount))
        let context = NullContext()
        let identity = try store.identityKeyPair(context: context)
        let timestamp = UInt64(now().timeIntervalSince1970 * 1000)
        var ids = KeyIDs()

        let signedId = ids.next()
        let signedKey = PrivateKey.generate()
        let signedSignature = identity.privateKey.generateSignature(message: signedKey.publicKey.serialize())
        try store.storeSignedPreKey(
            SignedPreKeyRecord(id: signedId, timestamp: timestamp, privateKey: signedKey, signature: signedSignature),
            id: signedId, context: context
        )

        let lastResort = try kyberPreKey(id: ids.next(), timestamp: timestamp, identity: identity, context: context)
        try store.markKyberPreKeyLastResort(id: lastResort.keyId)

        var preKeys: [DeviceKeys.PreKey] = []
        var pqPreKeys: [DeviceKeys.SignedPreKey] = []
        for _ in 0 ..< oneTimeCount {
            let id = ids.next()
            let key = PrivateKey.generate()
            try store.storePreKey(PreKeyRecord(id: id, privateKey: key), id: id, context: context)
            preKeys.append(.init(keyId: id, publicKey: key.publicKey.serialize().base64EncodedString()))
            try pqPreKeys.append(kyberPreKey(
                id: ids.next(),
                timestamp: timestamp,
                identity: identity,
                context: context
            ))
        }

        return try DeviceKeys(
            registrationId: store.localRegistrationId(context: context),
            identityKey: identity.identityKey.serialize().base64EncodedString(),
            signedPreKey: .init(
                keyId: signedId,
                publicKey: signedKey.publicKey.serialize().base64EncodedString(),
                signature: signedSignature.base64EncodedString()
            ),
            pqLastResortPreKey: lastResort,
            preKeys: preKeys,
            pqPreKeys: pqPreKeys
        )
    }

    private func kyberPreKey(
        id: UInt32, timestamp: UInt64, identity: IdentityKeyPair, context: StoreContext
    ) throws -> DeviceKeys.SignedPreKey {
        let pair = KEMKeyPair.generate()
        let publicKey = pair.publicKey.serialize()
        let signature = identity.privateKey.generateSignature(message: publicKey)
        try store.storeKyberPreKey(
            KyberPreKeyRecord(id: id, timestamp: timestamp, keyPair: pair, signature: signature), id: id,
            context: context
        )
        return .init(keyId: id, publicKey: publicKey.base64EncodedString(), signature: signature.base64EncodedString())
    }
}

/// 24-bit key IDs (libsignal's range), from a random start so a new set doesn't reuse an old set's IDs.
private struct KeyIDs {
    private static let limit: UInt32 = 0xFFFFFF
    private var current: UInt32

    init() {
        var random = SystemRandomNumberGenerator()
        current = UInt32.random(in: 1 ... Self.limit, using: &random)
    }

    mutating func next() -> UInt32 {
        current = current >= Self.limit ? 1 : current + 1
        return current
    }
}
