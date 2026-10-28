import SwiftUI
import ZapaKidKit

/// Shows the screen for where the person is: sign-in, or the app's tabs (parent or kid).
struct RootView: View {
    let auth: AuthModel
    let google: GoogleSignInProviding
    let ageCheck: AgeRangeProviding
    let families: FamiliesAPI
    let fingerprint: () -> String?
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
                    services: services(for: parent.id, kid: false),
                    family: FamilyModel(api: families, token: { auth.parentToken }, fingerprint: fingerprint),
                    greeting: nil,
                    onSignOut: { Task { await auth.logout() } }
                )
            case let .kid(session):
                MainTabView(
                    services: services(for: session.kid.id, kid: true), family: nil,
                    greeting: session.kid.nickname, onSignOut: nil
                )
            case .blockedMinor:
                BlockedMinorView()
            case .ageDeclined:
                AgeDeclinedView { Task { await auth.tryAgain() } }
            }
        }
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
