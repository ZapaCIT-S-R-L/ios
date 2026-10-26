import SwiftUI

/// Shown when the person signing in is under 18. Kids don't need an account: a parent adds their phone.
struct BlockedMinorView: View {
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "person.2.fill")
                    .font(.largeTitle)
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("Only parents can sign in")
                    .font(.title.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("You need to be 18 or older to sign in. Ask your parent to add your phone to the family.")
                    .font(.body)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("blocked.screen")
    }
}
