#if DEBUG
    import Foundation
    import ZapaCalls
    import ZapaChat
    import ZapaKidKit

    /// Stubbed backend for the UI tests (Debug builds only; this file is not compiled into Release).
    /// Launch with `-zk-ui-test` and set in the environment:
    ///   ZK_AGREEMENT  accepted | pending          ZK_SESSION  none | signed-in
    ///   ZK_AGE        adult | minor | declined | unavailable
    ///   ZK_SIGNIN     ok | rate-limited (the API answers 429 with Retry-After: 30)
    ///   ZK_KID        none | paired (this is a kid's phone, paired as "Ana")
    /// Chats: one conversation with Ana, who answers every message; calls use the demo call engine.
    /// Nothing is stored: a new in-memory session and agreement on every launch, and no network.
    @MainActor
    enum UITestStubs {
        static let launchArgument = "-zk-ui-test"
        static let parent = ParentProfile(id: "p_test", email: nil, displayName: "TEST Parent")

        /// `ZK_CALL` (outgoing, incoming, group, log): show the call screens with the demo call engine.
        static var callScenario: String? {
            let info = ProcessInfo.processInfo
            guard info.arguments.contains(launchArgument) else { return nil }
            return info.environment["ZK_CALL"]
        }

        static func dependencies(environment: [String: String]) -> AppDependencies {
            let agreement = InMemoryAgreementStore(
                acceptedVersion: environment["ZK_AGREEMENT"] == "pending" ? nil : ParentalAgreement.currentVersion
            )
            let session = environment["ZK_SESSION"] == "signed-in"
                ? Session(token: "stub", expiresAt: .distantFuture, parent: parent) : nil
            let age: AgeRange = switch environment["ZK_AGE"] {
            case "minor": .shared(lower: nil, upper: 17, platformStatus: "sharing")
            case "declined": .declined(platformStatus: "declinedSharing")
            case "unavailable": .unavailable
            default: .shared(lower: 18, upper: nil, platformStatus: "sharing")
            }
            let kid = environment["ZK_KID"] == "paired" ? KidSession(
                token: "zkk_stub", expiresAt: .distantFuture, kid: Kid(id: "k1", nickname: "Ana", avatar: "robot-4"),
                familyId: "f_test", familyName: nil
            ) : nil
            return AppDependencies(
                auth: AuthModel(
                    api: StubAuthAPI(rateLimited: environment["ZK_SIGNIN"] == "rate-limited"),
                    store: InMemorySessionStore(session: session),
                    agreement: agreement,
                    kidStore: InMemoryKidSessionStore(session: kid)
                ),
                google: StubGoogleSignIn(),
                ageCheck: StubAgeRangeCheck(range: age),
                families: StubFamiliesAPI(demo: environment["ZK_DEMO_FAMILY"] == "1"),
                connections: ConnectionsModel(api: HTTPConnectionsAPI.staging, token: { nil }),
                fingerprint: { _ in String(repeating: "ab", count: 32) },
                makeServices: { me, isKid in
                    let services = stubServices(
                        me: me, kid: isKid, ring: environment["ZK_RING"] == "1",
                        demo: environment["ZK_DEMO_FAMILY"] == "1"
                    )
                    services.setup = stubSetup(environment["ZK_SETUP"])
                    return services
                }
            )
        }

        /// `ZK_SETUP`: fail (network errors forever) or pair-again (a kid phone a parent must pair again).
        static func stubSetup(_ mode: String?) -> DeviceSetup? {
            let result: DeviceSetupResult
            switch mode {
            case "fail": result = .failed(.network)
            case "pair-again": result = .needsPairing
            default: return nil
            }
            return DeviceSetup(register: { result }, onSignedOut: {})
        }

        static func stubServices(me: String, kid: Bool, ring: Bool, demo: Bool = false) -> AppServices {
            let other = kid
                ? Person(accountId: "p_test", name: "Mama", avatar: "robot-2", role: .parent)
                : Person(accountId: "k1", name: "Ana", avatar: "robot-4", role: .kid)
            let myself = kid
                ? Person(accountId: me, name: "Ana", avatar: "robot-4", role: .kid)
                : Person(accountId: me, name: "TEST Parent", avatar: "robot-2", role: .parent)
            let api = StubChatAPI(me: me, other: other.accountId, ring: ring)
            return AppServices(
                me: me, chat: ChatModel(
                    me: me,
                    api: api,
                    sealer: PassthroughSealer(),
                    store: InMemoryChatStore()
                ),
                people: [other, myself] + (demo ? [
                    Person(accountId: "p_tata", name: "Tata", avatar: "robot-6", role: .parent),
                    Person(accountId: "k2", name: "Ion", avatar: "robot-9", role: .kid),
                ] : []), log: InMemoryCallLog(), system: InAppCallSystem()
            ) { services in
                DemoCalls.controller(peers: services.placing)
            }
        }
    }

    /// A family in memory: created empty, kids added, any `zkp_` code pairs as "Ana".
    final class StubFamiliesAPI: FamiliesAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var family: Family

        /// `demo`: a filled family for screenshots (ZK_DEMO_FAMILY=1).
        init(demo: Bool = false) {
            family = Family(
                id: "f_test", name: nil,
                parents: [FamilyParent(id: "p_test", displayName: "TEST Parent")]
                    + (demo ? [FamilyParent(id: "p_tata", displayName: "Tata")] : []),
                kids: demo ? [
                    Kid(id: "k1", nickname: "Ana", avatar: "robot-4", grade: 2),
                    Kid(id: "k2", nickname: "Ion", avatar: "robot-9", grade: -1),
                ] : []
            )
        }

        func createFamily(name _: String?, token _: String) async throws -> Family {
            lock.withLock { family }
        }

        func myFamily(token _: String) async throws -> Family? {
            lock.withLock { family }
        }

        func inviteParent(familyId _: String, token _: String) async throws -> CodeGrant {
            CodeGrant(code: "zki_" + String(repeating: "I", count: 43), expiresAt: Date().addingTimeInterval(259_200))
        }

        func join(code _: String, token _: String) async throws -> Family {
            lock.withLock { family }
        }

        func addKid(
            familyId _: String, nickname: String, avatar: String, grade: Int?, token _: String
        ) async throws -> Kid {
            lock.withLock {
                let kid = Kid(id: "k\(family.kids.count + 1)", nickname: nickname, avatar: avatar, grade: grade)
                family.kids.append(kid)
                return kid
            }
        }

        func updateKid(
            familyId _: String, kidId: String, nickname: String, avatar: String, token _: String
        ) async throws -> Kid {
            lock.withLock {
                let kid = Kid(id: kidId, nickname: nickname, avatar: avatar, grade: nil)
                family.kids = family.kids.map { $0.id == kidId ? kid : $0 }
                return kid
            }
        }

        func removeKid(familyId _: String, kidId: String, token _: String) async throws {
            lock.withLock { family.kids.removeAll { $0.id == kidId } }
        }

        func setDisplayName(_ name: String, token _: String) async throws -> FamilyParent {
            lock.withLock {
                let parent = FamilyParent(id: "p_test", displayName: name)
                family.parents = family.parents.map { $0.id == parent.id ? parent : $0 }
                return parent
            }
        }

        func createPairing(familyId _: String, kidId: String, token _: String) async throws -> PairingGrant {
            let kid = lock.withLock { family.kids.first { $0.id == kidId } } ?? Kid(
                id: kidId,
                nickname: "",
                avatar: "robot-1"
            )
            return PairingGrant(
                code: "zkp_" + String(repeating: "P", count: 43), expiresAt: Date().addingTimeInterval(300), kid: kid
            )
        }

        func redeemPairing(code _: String) async throws -> KidSession {
            KidSession(
                token: "zkk_stub", expiresAt: .distantFuture, kid: Kid(id: "k1", nickname: "Ana", avatar: "robot-4"),
                familyId: "f_test", familyName: nil
            )
        }
    }

    /// "Encrypts" by not encrypting: UI tests only, never compiled into Release.
    struct PassthroughSealer: MessageSealer {
        func seal(_ plaintext: Data, for conversation: Conversation, me: String) async throws -> [OutgoingEnvelope] {
            conversation.members.filter { $0.accountId != me }.flatMap { member in
                member.devices.map {
                    OutgoingEnvelope(
                        recipientAccountId: member.accountId, recipientDeviceId: $0.deviceId,
                        recipientRegistrationId: $0.registrationId, type: .message, content: plaintext
                    )
                }
            }
        }

        func open(_ envelope: Envelope) async throws -> Data {
            envelope.content
        }
    }

    /// One conversation with the other person, who answers "Hi! 👋" to every message over the stream.
    final class StubChatAPI: ChatAPI, @unchecked Sendable {
        let me: String
        let other: String
        /// ZK_RING=1: the other person calls (a sealed call message) 3 seconds after the stream opens.
        let ring: Bool
        private let lock = NSLock()
        private var continuation: AsyncThrowingStream<StreamFrame, Error>.Continuation?

        init(me: String, other: String, ring: Bool = false) {
            self.me = me
            self.other = other
            self.ring = ring
        }

        private var conversation: Conversation {
            Conversation(id: "c_ana", kind: .direct, state: .open, members: [
                ConversationMember(
                    accountId: me,
                    role: .parent,
                    guardian: false,
                    devices: [DeviceRef(deviceId: 1, registrationId: 1)]
                ),
                ConversationMember(
                    accountId: other,
                    role: .kid,
                    guardian: false,
                    devices: [DeviceRef(deviceId: 1, registrationId: 2)]
                ),
            ])
        }

        func conversations() async throws -> [Conversation] {
            [conversation]
        }

        func conversation(id _: String) async throws -> Conversation {
            conversation
        }

        func createConversation(members _: [String]) async throws -> Conversation {
            conversation
        }

        func leave(conversationId _: String) async throws {}

        func send(conversationId: String, messageId _: String, envelopes _: [OutgoingEnvelope]) async throws -> Date {
            let reply = ChatContent(id: UUID().uuidString, sentAt: Date(), body: .text("Hi! 👋"))
            let envelope = try Envelope(
                id: UUID().uuidString, conversationId: conversationId, messageId: reply.id, senderAccountId: other,
                senderDeviceId: 1, type: .message, content: reply.encoded(), serverTimestamp: 0
            )
            let continuation = lock.withLock { self.continuation }
            Task {
                try? await Task.sleep(for: .milliseconds(800))
                continuation?.yield(.envelope(envelope))
            }
            return Date()
        }

        func fetch(conversationId _: String) async throws -> EnvelopePage {
            EnvelopePage(envelopes: [], more: false)
        }

        func ack(conversationId _: String, envelopeIds _: [String]) async throws {}

        func upload(conversationId _: String, ciphertext _: Data) async throws -> String {
            "a_stub"
        }

        func download(attachmentId _: String) async throws -> Data {
            Data()
        }

        func openStream(conversationId _: String) async throws -> ChatStreamConnection {
            let (stream, continuation) = AsyncThrowingStream<StreamFrame, Error>.makeStream()
            lock.withLock { self.continuation = continuation }
            if ring {
                let call = ChatContent(id: UUID().uuidString, sentAt: Date(), body: .call(callId: "demo-call"))
                let envelope = try Envelope(
                    id: UUID().uuidString, conversationId: "c_ana", messageId: call.id, senderAccountId: other,
                    senderDeviceId: 1, type: .message, content: call.encoded(), serverTimestamp: 0
                )
                Task {
                    try? await Task.sleep(for: .seconds(3))
                    continuation.yield(.envelope(envelope))
                }
            }
            return StubStream(stream: stream)
        }
    }

    struct StubStream: ChatStreamConnection {
        let stream: AsyncThrowingStream<StreamFrame, Error>

        func frames() -> AsyncThrowingStream<StreamFrame, Error> {
            stream
        }

        func ack(_: [String]) async throws {}
        func close() {}
    }

    struct StubAuthAPI: AuthAPI {
        let rateLimited: Bool

        func signInNonce() async throws -> SignInNonceGrant {
            SignInNonceGrant(nonce: "stub-nonce", expiresAt: Date().addingTimeInterval(600))
        }

        func signIn(_: SignInRequest) async throws -> Session {
            if rateLimited {
                throw AuthAPIError.rateLimited(retryAfter: 30)
            }
            return await Session(token: "stub", expiresAt: .distantFuture, parent: UITestStubs.parent)
        }

        func me(token _: String) async throws -> ParentProfile {
            await UITestStubs.parent
        }

        func logout(token _: String) async throws {}
    }

    struct StubGoogleSignIn: GoogleSignInProviding {
        func idToken(nonce _: String) async throws -> String {
            "stub-google-id-token"
        }
    }

    struct StubAgeRangeCheck: AgeRangeProviding {
        let range: AgeRange
        func ageRange() async -> AgeRange {
            range
        }
    }
#endif

#if DEBUG
    import SwiftUI
    import ZapaCalls

    /// `ZK_CALL=outgoing|incoming|group` with `-zk-ui-test`: the call screens with the demo call engine.
    struct CallsDemoRoot: View {
        let scenario: String
        @State private var controller: CallController?

        var body: some View {
            ZStack {
                Color.clear
                if let controller {
                    CallScreen(controller: controller)
                }
            }
            .task {
                guard scenario != "log", controller == nil else { return }
                switch scenario {
                case "incoming":
                    let call = DemoCalls.controller(peers: [DemoCalls.mama])
                    call.reportIncoming(callId: "demo-call", caller: DemoCalls.mama)
                    controller = call
                case "group":
                    let call = DemoCalls.controller(peers: [DemoCalls.mama, DemoCalls.tata, DemoCalls.ana])
                    controller = call
                    await call.startCall(
                        conversationId: "conv-family",
                        peers: [DemoCalls.mama, DemoCalls.tata, DemoCalls.ana]
                    )
                default:
                    let call = DemoCalls.controller(peers: [DemoCalls.mama])
                    controller = call
                    await call.startCall(conversationId: "conv-mama", peers: [DemoCalls.mama])
                }
            }
        }
    }
#endif
