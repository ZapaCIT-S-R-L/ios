import SwiftUI
import ZapaCalls
import ZapaKidKit

/// Shows the screen for where the person is: sign-in, or the app's tabs (parent or kid).
struct RootView: View {
    let auth: AuthModel
    let google: GoogleSignInProviding
    let ageCheck: AgeRangeProviding
    let families: FamiliesAPI
    let fingerprint: (String) -> String?
    let makeServices: @MainActor (_ me: String, _ kid: Bool) -> AppServices
    @State private var services: AppServices?

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                ProgressView()
                    .accessibilityLabel(Text("Loading"))
            case .needsAgreement:
                AgreementPlaceholderView { Task { await auth.acceptAgreement() } }
            case .signedOut:
                SignInView(
                    auth: auth, google: google, ageCheck: ageCheck,
                    pairing: KidPairingModel(api: families, auth: auth)
                )
            case let .signedIn(parent):
                MainTabView(
                    role: auth.state.themeRole,
                    services: services(for: parent.id, kid: false),
                    family: FamilyModel(
                        api: families,
                        me: parent.id,
                        token: { auth.parentToken },
                        fingerprint: { fingerprint(parent.id) }
                    ),
                    onSignOut: { Task { await auth.logout() } }
                )
            case let .kid(session):
                MainTabView(
                    role: auth.state.themeRole,
                    services: services(for: session.kid.id, kid: true), family: nil,
                    onSignOut: nil
                )
            case .blockedMinor:
                BlockedMinorView()
            case .ageDeclined:
                AgeDeclinedView { Task { await auth.tryAgain() } }
            }
        }
        .zapaTheme(auth.state.themeRole)
        .task { await auth.start() }
    }

    /// One set of services per signed-in account.
    private func services(for me: String, kid: Bool) -> AppServices {
        if let services, services.me == me {
            return services
        }
        let made = makeServices(me, kid)
        Task { @MainActor in services = made }
        return made
    }
}

extension AuthState {
    /// Kids get the playful look; everything else (parents, sign-in) the calm one.
    var themeRole: ZapaTheme.Role {
        if case .kid = self {
            .kid
        } else {
            .parent
        }
    }
}
