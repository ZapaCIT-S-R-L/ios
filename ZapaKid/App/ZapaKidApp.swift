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
            ageCheck: dependencies.ageCheck
        )
    }
}

/// What the screens need. The real ones talk to Apple, Google and the API; UI tests get stubs.
@MainActor
struct AppDependencies {
    let auth: AuthModel
    let google: GoogleSignInProviding
    let ageCheck: AgeRangeProviding

    static func make() -> AppDependencies {
        #if DEBUG
            if ProcessInfo.processInfo.arguments.contains(UITestStubs.launchArgument) {
                return UITestStubs.dependencies(environment: ProcessInfo.processInfo.environment)
            }
        #endif
        return AppDependencies(
            auth: AuthModel(
                api: HTTPAuthAPI.staging,
                store: KeychainSessionStore(),
                agreement: UserDefaultsAgreementStore()
            ),
            google: GoogleSignIn(),
            ageCheck: DeclaredAgeRangeCheck()
        )
    }
}
