import SwiftUI
import ZapaKidKit

/// Shows the screen for where the parent is in the sign-in flow.
struct RootView: View {
    let auth: AuthModel
    let google: GoogleSignInProviding
    let ageCheck: AgeRangeProviding
    let families: FamiliesAPI
    let fingerprint: () -> String?

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
                HomeView(
                    parent: parent,
                    family: FamilyModel(api: families, token: { auth.parentToken }, fingerprint: fingerprint)
                ) { Task { await auth.logout() } }
            case let .kid(session):
                KidHomeView(session: session)
            case .blockedMinor:
                BlockedMinorView()
            case .ageDeclined:
                AgeDeclinedView { Task { await auth.tryAgain() } }
            }
        }
        .task { await auth.start() }
    }
}
