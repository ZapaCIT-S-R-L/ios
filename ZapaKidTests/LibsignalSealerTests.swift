import Foundation
import LibSignalClient
import Testing
import ZapaCalls
import ZapaChat
@testable import ZapaKid

/// Chat messages and call keys sealed with libsignal sessions (X3DH/PQXDH prekey bundles, then the double ratchet),
/// one envelope per recipient device. Two phones in memory, the key directory faked.
struct LibsignalSealerTests {
    /// A phone: its account, device, libsignal store and the bundle it publishes.
    final class Phone: @unchecked Sendable {
        let account: String
        let device: UInt32
        let identity = IdentityKeyPair.generate()
        let registrationId: UInt32
        let store: InMemorySignalProtocolStore
        let bundle: PreKeyBundle

        init(account: String, device: UInt32, registrationId: UInt32) throws {
            self.account = account
            self.device = device
            self.registrationId = registrationId
            store = InMemorySignalProtocolStore(identity: identity, registrationId: registrationId)
            let preKey = PrivateKey.generate()
            let signedPreKey = PrivateKey.generate()
            let kyber = KEMKeyPair.generate()
            let signedSignature = identity.privateKey.generateSignature(message: signedPreKey.publicKey.serialize())
            let kyberSignature = identity.privateKey.generateSignature(message: kyber.publicKey.serialize())
            try store.storePreKey(
                PreKeyRecord(id: 1, publicKey: preKey.publicKey, privateKey: preKey), id: 1, context: NullContext()
            )
            try store.storeSignedPreKey(
                SignedPreKeyRecord(id: 2, timestamp: 0, privateKey: signedPreKey, signature: signedSignature),
                id: 2, context: NullContext()
            )
            try store.storeKyberPreKey(
                KyberPreKeyRecord(id: 3, timestamp: 0, keyPair: kyber, signature: kyberSignature),
                id: 3, context: NullContext()
            )
            bundle = try PreKeyBundle(
                registrationId: registrationId, deviceId: device, prekeyId: 1, prekey: preKey.publicKey,
                signedPrekeyId: 2, signedPrekey: signedPreKey.publicKey, signedPrekeySignature: signedSignature,
                identity: identity.identityKey, kyberPrekeyId: 3, kyberPrekey: kyber.publicKey,
                kyberPrekeySignature: kyberSignature
            )
        }

        func sessions(directory: FakeKeyDirectory) throws -> LibsignalSessions {
            try LibsignalSessions(
                local: ProtocolAddress(name: account, deviceId: device), store: store, bundles: directory
            )
        }
    }

    struct FakeKeyDirectory: PreKeyBundleSource {
        let phones: [Phone]

        func bundles(accountId: String) async throws -> [PreKeyBundle] {
            phones.filter { $0.account == accountId }.map(\.bundle)
        }
    }

    func conversation(_ phones: [Phone]) -> Conversation {
        Conversation(
            id: "c_1",
            kind: .direct,
            state: .open,
            members: Dictionary(grouping: phones, by: \.account)
                .map { account, devices in
                    ConversationMember(
                        accountId: account, role: .parent, guardian: false,
                        devices: devices.map { DeviceRef(
                            deviceId: Int($0.device),
                            registrationId: Int($0.registrationId)
                        ) }
                    )
                }
        )
    }

    func envelope(_ outgoing: OutgoingEnvelope, from phone: Phone) -> Envelope {
        Envelope(
            id: UUID().uuidString, conversationId: "c_1", messageId: "m", senderAccountId: phone.account,
            senderDeviceId: Int(phone.device), type: outgoing.type, content: outgoing.content, serverTimestamp: 0
        )
    }

    @Test func aMessageOpensOnlyAtTheRecipientAndTheReplyComesBack() async throws {
        let mama = try Phone(account: "acc-m", device: 1, registrationId: 11)
        let ana = try Phone(account: "acc-a", device: 1, registrationId: 22)
        let directory = FakeKeyDirectory(phones: [mama, ana])
        let mamaSealer = try LibsignalMessageSealer(sessions: mama.sessions(directory: directory))
        let anaSealer = try LibsignalMessageSealer(sessions: ana.sessions(directory: directory))
        let chat = conversation([mama, ana])

        let sealed = try await mamaSealer.seal(Data("Salut, Ana!".utf8), for: chat, me: "acc-m")

        #expect(sealed.count == 1)
        let first = try #require(sealed.first)
        #expect(first.type == .prekeyMessage)
        #expect(first.recipientRegistrationId == 22)
        #expect(first.content.range(of: Data("Salut".utf8)) == nil)
        #expect(try await anaSealer.open(envelope(first, from: mama)) == Data("Salut, Ana!".utf8))

        let reply = try #require(try await anaSealer.seal(Data("Pa!".utf8), for: chat, me: "acc-a").first)
        #expect(reply.type == .message, "the session exists now")
        #expect(try await mamaSealer.open(envelope(reply, from: ana)) == Data("Pa!".utf8))
    }

    @Test func myOtherDevicesGetACopyButNotThisOne() async throws {
        let mama1 = try Phone(account: "acc-m", device: 1, registrationId: 11)
        let mama2 = try Phone(account: "acc-m", device: 2, registrationId: 12)
        let ana = try Phone(account: "acc-a", device: 1, registrationId: 22)
        let directory = FakeKeyDirectory(phones: [mama1, mama2, ana])
        let sealer = try LibsignalMessageSealer(sessions: mama1.sessions(directory: directory))

        let sealed = try await sealer.seal(Data("x".utf8), for: conversation([mama1, mama2, ana]), me: "acc-m")

        let targets = Set(sealed.map { "\($0.recipientAccountId).\($0.recipientDeviceId)" })
        #expect(targets == ["acc-m.2", "acc-a.1"])
    }

    @Test func aTamperedEnvelopeDoesNotOpen() async throws {
        let mama = try Phone(account: "acc-m", device: 1, registrationId: 11)
        let ana = try Phone(account: "acc-a", device: 1, registrationId: 22)
        let directory = FakeKeyDirectory(phones: [mama, ana])
        let sealed = try #require(try await LibsignalMessageSealer(sessions: mama.sessions(directory: directory))
            .seal(Data("hi".utf8), for: conversation([mama, ana]), me: "acc-m").first)
        var tampered = sealed
        tampered.content[tampered.content.index(tampered.content.endIndex, offsetBy: -5)] ^= 0x01

        await #expect(throws: (any Error).self) {
            _ = try await LibsignalMessageSealer(sessions: ana.sessions(directory: directory))
                .open(envelope(tampered, from: mama))
        }
    }

    @Test func callKeysAreSealedPerDeviceWithTheSameSessions() async throws {
        let mama = try Phone(account: "acc-m", device: 1, registrationId: 11)
        let ana = try Phone(account: "acc-a", device: 1, registrationId: 22)
        let directory = FakeKeyDirectory(phones: [mama, ana])
        let mamaCalls = try LibsignalCallKeySealer(sessions: mama.sessions(directory: directory))
        let anaCalls = try LibsignalCallKeySealer(sessions: ana.sessions(directory: directory))
        let material = CallKeyMaterial.encode(CallKey.random(epoch: 1), callId: "call-1")

        let blob = try await mamaCalls.seal(material, toDevice: "acc-a.1")

        #expect(blob.range(of: material.dropFirst(9).prefix(16)) == nil)
        #expect(try await anaCalls.open(blob, fromDevice: "acc-m.1") == material)
        #expect(LibsignalCallKeySealer.deviceName(account: "acc-a", device: 3) == "acc-a.3")
        await #expect(throws: (any Error).self) { _ = try await anaCalls.open(blob, fromDevice: "acc-x.1") }
    }
}
