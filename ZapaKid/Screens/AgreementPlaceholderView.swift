import SwiftUI

/// First launch: the parent accepts the parental agreement before signing in.
/// TODO: placeholder only. The reviewed legal text (Romanian master, English translation) replaces the body text, and
/// the accepted version goes to the API as the consent record. No legal text is written here.
struct AgreementPlaceholderView: View {
    let onAccept: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Parental agreement")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("The parental agreement will appear here.")
                    .font(.body)
                Text("Placeholder: the final text is being reviewed.")
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
                Button(action: onAccept) {
                    Text("I agree")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("agreement.accept")
                .accessibilityHint(Text("Accepts the parental agreement and continues to sign-in"))
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("agreement.screen")
    }
}
