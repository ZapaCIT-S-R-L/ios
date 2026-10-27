import Foundation
import LibSignalClient
import ZapaCalls
import ZapaChat

/// Where prekey bundles come from: the account API's key directory (`GET /v1/keys/{accountId}/*`).
protocol PreKeyBundleSource: Sendable {
    func bundles(accountId: String) async throws -> [PreKeyBundle]
}

enum SealerError: Error, Equatable {
    case noBundle(account: String, device: Int)
    case unsupportedType
    case badAddress
    /// This phone isn't registered with the key directory yet: nothing can be sealed or opened.
    case notRegistered
}

/// This phone's libsignal sessions: one actor, so the (not thread-safe) stores are used one call at a time.
/// A missing session starts from the recipient's prekey bundle (PQXDH); identity changes are refused by the store
/// (`isTrustedIdentity`), never trusted silently.
actor LibsignalSessions {
    typealias Store = IdentityKeyStore & KyberPreKeyStore & PreKeyStore & SessionStore & SignedPreKeyStore

    let local: ProtocolAddress
    private let store: Store
    private let bundles: PreKeyBundleSource
    private let context = NullContext()

    init(local: ProtocolAddress, store: Store, bundles: PreKeyBundleSource) throws {
        self.local = local
        self.store = store
        self.bundles = bundles
    }

    func encrypt(_ plaintext: Data, to address: ProtocolAddress) async throws -> CiphertextMessage {
        if try store.loadSession(for: address, context: context)?.hasCurrentState != true {
            let bundle = try await bundles.bundles(accountId: address.name)
                .first { $0.deviceId == address.deviceId }
            guard let bundle else { throw SealerError.noBundle(account: address.name, device: Int(address.deviceId)) }
            try processPreKeyBundle(
                bundle, for: address, ourAddress: local, sessionStore: store, identityStore: store, context: context
            )
        }
        return try signalEncrypt(
            message: plaintext, for: address, localAddress: local, sessionStore: store, identityStore: store,
            context: context
        )
    }

    func decrypt(_ ciphertext: Data, preKey: Bool, from address: ProtocolAddress) throws -> Data {
        if preKey {
            return try signalDecryptPreKey(
                message: PreKeySignalMessage(bytes: ciphertext), from: address, localAddress: local,
                sessionStore: store, identityStore: store, preKeyStore: store, signedPreKeyStore: store,
                kyberPreKeyStore: store, context: context
            )
        }
        return try signalDecrypt(
            message: SignalMessage(bytes: ciphertext), from: address, to: local, sessionStore: store,
            identityStore: store, context: context
        )
    }
}

/// This phone's sessions once it is registered with the key directory (nil until then); set after registration.
final class SessionsBox: @unchecked Sendable {
    private let lock = NSLock()
    private var current: LibsignalSessions?

    init(_ sessions: LibsignalSessions? = nil) {
        current = sessions
    }

    var sessions: LibsignalSessions? {
        get { lock.withLock { current } }
        set { lock.withLock { current = newValue } }
    }
}

/// Chat messages: one libsignal message per recipient device (pairwise; groups fan out up to 31 members, sender
/// keys can come later). Covers every device of every member except this one, as the chat service requires.
struct LibsignalMessageSealer: ReleaseMessageSealer {
    let box: SessionsBox

    init(sessions: LibsignalSessions?) {
        box = SessionsBox(sessions)
    }

    init(box: SessionsBox) {
        self.box = box
    }

    func seal(_ plaintext: Data, for conversation: Conversation, me: String) async throws -> [OutgoingEnvelope] {
        guard let sessions = box.sessions else { throw SealerError.notRegistered }
        let local = sessions.local
        var envelopes: [OutgoingEnvelope] = []
        for member in conversation.members {
            for device in member.devices
                where !(member.accountId == me && UInt32(device.deviceId) == local.deviceId)
            {
                let address = try ProtocolAddress(name: member.accountId, deviceId: UInt32(device.deviceId))
                let message = try await sessions.encrypt(plaintext, to: address)
                envelopes.append(OutgoingEnvelope(
                    recipientAccountId: member.accountId, recipientDeviceId: device.deviceId,
                    recipientRegistrationId: device.registrationId,
                    type: message.messageType == .preKey ? .prekeyMessage : .message, content: message.serialize()
                ))
            }
        }
        return envelopes
    }

    func open(_ envelope: Envelope) async throws -> Data {
        guard let sessions = box.sessions else { throw SealerError.notRegistered }
        guard envelope.type != .senderKeyMessage else { throw SealerError.unsupportedType }
        let address = try ProtocolAddress(name: envelope.senderAccountId, deviceId: UInt32(envelope.senderDeviceId))
        return try await sessions.decrypt(envelope.content, preKey: envelope.type == .prekeyMessage, from: address)
    }
}

/// Call keys over the same sessions. Devices are named `<accountId>.<deviceId>`; the blob is one type byte
/// (prekey or not) and the libsignal message.
struct LibsignalCallKeySealer: ReleaseCallKeySealer {
    let box: SessionsBox

    init(sessions: LibsignalSessions?) {
        box = SessionsBox(sessions)
    }

    init(box: SessionsBox) {
        self.box = box
    }

    static func deviceName(account: String, device: Int) -> String {
        "\(account).\(device)"
    }

    static func address(_ name: String) throws -> ProtocolAddress {
        guard let dot = name.lastIndex(of: "."), let device = UInt32(name[name.index(after: dot)...]) else {
            throw SealerError.badAddress
        }
        return try ProtocolAddress(name: String(name[..<dot]), deviceId: device)
    }

    func seal(_ keyMaterial: Data, toDevice: String) async throws -> Data {
        guard let sessions = box.sessions else { throw SealerError.notRegistered }
        let message = try await sessions.encrypt(keyMaterial, to: Self.address(toDevice))
        return Data([message.messageType == .preKey ? 1 : 0]) + message.serialize()
    }

    func open(_ blob: Data, fromDevice: String) async throws -> Data {
        guard let sessions = box.sessions else { throw SealerError.notRegistered }
        guard let kind = blob.first else { throw SealerError.badAddress }
        return try await sessions.decrypt(Data(blob.dropFirst()), preKey: kind == 1, from: Self.address(fromDevice))
    }
}

/// `GET /v1/keys/{accountId}/*` (draft in the account API): one prekey bundle per device of the account. Fetching
/// consumes the one-time prekeys it returns.
struct HTTPPreKeyBundles: PreKeyBundleSource {
    let baseURL: URL
    let session: URLSession
    let token: @Sendable () async -> String?

    private struct Reply: Decodable {
        struct Key: Decodable {
            var keyId: UInt32
            var publicKey: Data
            var signature: Data?
        }

        struct Device: Decodable {
            var deviceId: UInt32
            var registrationId: UInt32
            var signedPreKey: Key
            var pqPreKey: Key
            var preKey: Key?
        }

        var identityKey: Data
        var devices: [Device]
    }

    func bundles(accountId: String) async throws -> [PreKeyBundle] {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        let account = accountId.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
        var request = URLRequest(url: baseURL.appending(path: "v1/keys/\(account)/*"))
        guard let token = await token() else { throw SealerError.badAddress }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SealerError.noBundle(
            account: accountId,
            device: 0
        ) }
        let reply = try JSONDecoder().decode(Reply.self, from: data)
        let identity = try IdentityKey(bytes: reply.identityKey)
        return try reply.devices.map { device in
            let signed = try PublicKey(device.signedPreKey.publicKey)
            let kyber = try KEMPublicKey(device.pqPreKey.publicKey)
            if let preKey = device.preKey {
                return try PreKeyBundle(
                    registrationId: device.registrationId, deviceId: device.deviceId, prekeyId: preKey.keyId,
                    prekey: PublicKey(preKey.publicKey), signedPrekeyId: device.signedPreKey.keyId,
                    signedPrekey: signed, signedPrekeySignature: device.signedPreKey.signature ?? Data(),
                    identity: identity, kyberPrekeyId: device.pqPreKey.keyId, kyberPrekey: kyber,
                    kyberPrekeySignature: device.pqPreKey.signature ?? Data()
                )
            }
            return try PreKeyBundle(
                registrationId: device.registrationId, deviceId: device.deviceId,
                signedPrekeyId: device.signedPreKey.keyId, signedPrekey: signed,
                signedPrekeySignature: device.signedPreKey.signature ?? Data(), identity: identity,
                kyberPrekeyId: device.pqPreKey.keyId, kyberPrekey: kyber,
                kyberPrekeySignature: device.pqPreKey.signature ?? Data()
            )
        }
    }
}

/// This phone's sessions for an account, once the device is registered with the key directory (else nil and the
/// app keeps refusing to send).
enum SecureSessions {
    static func make(accountId: String, bundles: PreKeyBundleSource) -> LibsignalSessions? {
        guard let account = try? AccountKeys.app(accountId: accountId),
              let data = try? account.files.read("device.json"),
              let device = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["deviceId"] as? Int,
              let identity = try? account.identity.load(),
              let store = try? ZapaKidProtocolStore(identity: identity, files: account.files, peers: account.peers),
              let local = try? ProtocolAddress(name: accountId, deviceId: UInt32(device))
        else { return nil }
        return try? LibsignalSessions(local: local, store: store, bundles: bundles)
    }
}
