import SwiftUI
import ZapaKidKit

/// Shows the screen for where the parent is in the sign-in flow.
struct RootView: View {
    let auth: AuthModel
    let google: GoogleSignInProviding
    let ageCheck: AgeRangeProviding

    var body: some View {
        Group {
            switch auth.state {
            case .loading:
                ProgressView()
                    .accessibilityLabel(Text("Loading"))
            case .needsAgreement:
                AgreementPlaceholderView { Task { await auth.acceptAgreement() } }
            case .signedOut:
                SignInView(auth: auth, google: google, ageCheck: ageCheck)
            case let .signedIn(parent):
                HomeView(parent: parent) { Task { await auth.logout() } }
            case .blockedMinor:
                BlockedMinorView()
            case .ageDeclined:
                AgeDeclinedView { Task { await auth.tryAgain() } }
            }
        }
        .task { await auth.start() }
    }
}
