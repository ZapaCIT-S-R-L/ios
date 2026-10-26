import SwiftUI
import ZapaKidKit

/// The signed-in parent. Chats, family and kids come in the next slices.
struct HomeView: View {
    let parent: ParentProfile
    let onSignOut: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Signed in as")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(parent.displayName ?? parent.email ?? String(localized: "Parent"))
                        .font(.title2.bold())
                        .accessibilityIdentifier("home.parentName")
                    Text("Your family chats will appear here.")
                        .font(.footnote.italic())
                        .foregroundStyle(.secondary)
                    Button(role: .destructive, action: onSignOut) {
                        Text("Sign out")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("home.signOut")
                    .accessibilityHint(Text("Signs out on this phone"))
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(Text("ZapaKid"))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("home.screen")
    }
}
