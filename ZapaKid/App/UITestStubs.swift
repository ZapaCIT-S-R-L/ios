#if DEBUG
    import Foundation
    import ZapaKidKit

    /// Stubbed backend for the UI tests (Debug builds only; this file is not compiled into Release).
    /// Launch with `-zk-ui-test` and set in the environment:
    ///   ZK_AGREEMENT  accepted | pending        ZK_SESSION  none | signed-in        ZK_AGE  adult | minor | unknown
    /// Nothing is stored: a new in-memory session and agreement on every launch, and no network.
    @MainActor
    enum UITestStubs {
        static let launchArgument = "-zk-ui-test"
        static let parent = ParentProfile(id: "p_test", name: "TEST Parent", email: nil)

        static func dependencies(environment: [String: String]) -> AppDependencies {
            let agreement = InMemoryAgreementStore(
                acceptedVersion: environment["ZK_AGREEMENT"] == "pending" ? nil : ParentalAgreement.currentVersion
            )
            let session = environment["ZK_SESSION"] == "signed-in" ? Session(token: "stub", parent: parent) : nil
            let age: AgeRange? = switch environment["ZK_AGE"] {
            case "minor": AgeRange(lower: nil, upper: 17, declined: false)
            case "unknown": nil
            default: AgeRange(lower: 18, upper: nil, declined: false)
            }
            return AppDependencies(
                auth: AuthModel(
                    api: StubAuthAPI(),
                    store: InMemorySessionStore(session: session),
                    agreement: agreement
                ),
                google: StubGoogleSignIn(),
                ageCheck: StubAgeRangeCheck(range: age)
            )
        }
    }

    struct StubAuthAPI: AuthAPI {
        func signIn(_: SignInRequest) async throws -> Session {
            await Session(token: "stub", parent: UITestStubs.parent)
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
        let range: AgeRange?
        func ageRange() async -> AgeRange? {
            range
        }
    }
#endif
