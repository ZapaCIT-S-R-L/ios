import SwiftUI
import ZapaCalls
import ZapaChat

/// Pick one person (a 1:1 chat) or several (a group) from the family.
struct NewChatView: View {
    let services: AppServices

    static func message(for failure: ChatModel.StartFailure) -> LocalizedStringKey {
        switch failure {
        case .notAllowed: "You can't start a chat with these people."
        case .network: "Can't reach ZapaKid. Check your connection and try again."
        case .other: "The chat didn't start. Try again."
        }
    }

    let onStart: (Conversation) -> Void
    @State private var chosen: Set<String> = []
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(services.contacts, id: \.accountId) { person in
                Button {
                    if chosen.contains(person.accountId) {
                        chosen.remove(person.accountId)
                    } else {
                        chosen.insert(person.accountId)
                    }
                } label: {
                    HStack(spacing: 12) {
                        PersonAvatar(accountId: person.accountId, avatar: person.avatar, size: 40)
                        Text(verbatim: person.name)
                            .foregroundStyle(Color.primary)
                        Spacer()
                        Image(systemName: chosen.contains(person.accountId) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(Color.accentColor)
                            .accessibilityHidden(true)
                    }
                }
                .accessibilityAddTraits(chosen.contains(person.accountId) ? [.isSelected, .isButton] : .isButton)
                .accessibilityIdentifier("newChat.person.\(person.name)")
            }
            .safeAreaInset(edge: .bottom) {
                if let failure = services.chat.startFailure {
                    Text(Self.message(for: failure))
                        .font(.callout)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding()
                        .accessibilityIdentifier("newChat.error")
                }
            }
            .overlay {
                if services.contacts.isEmpty {
                    ContentUnavailableView {
                        Text("Add your kids in Family first.")
                    }
                }
            }
            .navigationTitle(Text("New chat"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button { dismiss() } label: { Text("Cancel") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button {
                        busy = true
                        Task {
                            if let conversation = await services.chat.start(with: chosen.sorted()) {
                                onStart(conversation)
                            }
                            busy = false
                        }
                    } label: {
                        Text("Start")
                    }
                    .disabled(chosen.isEmpty || busy)
                    .accessibilityIdentifier("newChat.start")
                }
            }
        }
    }
}
