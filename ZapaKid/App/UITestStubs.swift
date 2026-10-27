#if DEBUG
    import Foundation
    import ZapaKidKit

    /// Stubbed backend for the UI tests (Debug builds only; this file is not compiled into Release).
    /// Launch with `-zk-ui-test` and set in the environment:
    ///   ZK_AGREEMENT  accepted | pending          ZK_SESSION  none | signed-in
    ///   ZK_AGE        adult | minor | declined | unavailable
    ///   ZK_SIGNIN     ok | rate-limited (the API answers 429 with Retry-After: 30)
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
            return AppDependencies(
                auth: AuthModel(
                    api: StubAuthAPI(rateLimited: environment["ZK_SIGNIN"] == "rate-limited"),
                    store: InMemorySessionStore(session: session),
                    agreement: agreement
                ),
                google: StubGoogleSignIn(),
                ageCheck: StubAgeRangeCheck(range: age),
                families: StubFamiliesAPI(),
                fingerprint: { String(repeating: "ab", count: 32) }
            )
        }
    }

    /// A family in memory: created empty, kids added, any `zkp_` code pairs as "Ana".
    final class StubFamiliesAPI: FamiliesAPI, @unchecked Sendable {
        private let lock = NSLock()
        private var family = Family(
            id: "f_test", name: nil, parents: [FamilyParent(id: "p_test", displayName: "TEST Parent")], kids: []
        )

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

    /// `ZK_CALL=outgoing|incoming|group|log` with `-zk-ui-test`: the call screens with the demo call engine.
    struct CallsDemoRoot: View {
        let scenario: String
        @State private var controller: CallController?

        var body: some View {
            Group {
                if scenario == "log" {
                    NavigationStack {
                        CallLogView(entries: DemoCalls.log) { _ in }
                    }
                } else if let controller {
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
