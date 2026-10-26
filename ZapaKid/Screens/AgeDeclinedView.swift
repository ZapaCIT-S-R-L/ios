import SwiftUI

/// Shown when the person chose not to share their age range. Parents must be 18+, so ZapaKid needs it; they can
/// sign in again and share it.
struct AgeDeclinedView: View {
    let onTryAgain: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "person.badge.shield.checkmark")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Share your age range to continue")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Only adults can sign in as parents. Your phone shares only whether you are 18 or older.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                Button(action: onTryAgain) {
                    Text("Try again")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("declined.tryAgain")
                .accessibilityHint(Text("Goes back to sign-in, where you can share your age range"))
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("declined.screen")
    }
}
