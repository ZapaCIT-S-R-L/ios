import SwiftUI
import ZapaKidKit

@main
struct ZapaKidApp: App {
    @State private var dependencies = AppDependencies.make()

    var body: some Scene {
        WindowGroup {
            #if DEBUG
                if let call = UITestStubs.callScenario {
                    CallsDemoRoot(scenario: call)
                } else {
                    root
                }
            #else
                root
            #endif
        }
    }

    private var root: some View {
        RootView(
            auth: dependencies.auth,
            google: dependencies.google,
            ageCheck: dependencies.ageCheck,
            families: dependencies.families,
            fingerprint: dependencies.fingerprint,
            makeServices: dependencies.makeServices
        )
    }
}

/// What the screens need. The real ones talk to Apple, Google and the API; UI tests get stubs.
@MainActor
struct AppDependencies {
    let auth: AuthModel
    let google: GoogleSignInProviding
    let ageCheck: AgeRangeProviding
    let families: FamiliesAPI
    /// This phone's identity key fingerprint (hex) for the kid pairing QR, per account.
    let fingerprint: (String) -> String?
    /// The chats and calls of the signed-in account (`me`; `kid` for a kid's phone).
    let makeServices: @MainActor (_ me: String, _ kid: Bool) -> AppServices

    static func make() -> AppDependencies {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(UITestStubs.launchArgument) {
                return UITestStubs.dependencies(environment: ProcessInfo.processInfo.environment)
            }
        #endif
        let auth = AuthModel(
            api: HTTPAuthAPI.staging,
            store: KeychainSessionStore(),
            agreement: UserDefaultsAgreementStore(),
            kidStore: KeychainKidSessionStore()
        )
        return AppDependencies(
            auth: auth,
            google: GoogleSignIn(),
            ageCheck: DeclaredAgeRangeCheck(),
            families: HTTPFamiliesAPI.staging,
            fingerprint: { accountId in
                (try? AccountKeys.app(accountId: accountId)).flatMap { PairingFingerprint.current($0.identity) }
            },
            makeServices: { me, isKid in
                let services = LiveServices.make(me: me, kid: isKid, auth: auth)
                // Names and robots for chats and calls: the parent's family (created on first use) or the kid's.
                services.loadPeople = { services in
                    guard let token = auth.sessionToken else { return }
                    let families = HTTPFamiliesAPI.staging
                    let family = isKid
                        ? try? await families.myFamily(token: token)
                        : try? await families.createFamily(name: nil, token: token)
                    if let family {
                        services.update(from: family)
                    }
                }
                return services
            }
        )
    }
}
