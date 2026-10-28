import SwiftUI
import ZapaCalls
import ZapaChat

/// The conversations: robot, name, last message, unread count.
struct ChatListView: View {
    let services: AppServices
    @State private var choosing = false
    @State private var opened: Conversation?
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        List {
            Section {
                ForEach(Array(services.chat.conversations.enumerated()), id: \.element.id) { index, conversation in
                    NavigationLink {
                        ChatView(services: services, conversation: conversation)
                    } label: {
                        row(conversation)
                    }
                    .accessibilityIdentifier("chats.row.\(services.name(of: conversation))")
                    .listRowSeparator(theme.cardShadow ? .hidden : .visible)
                    .listRowSeparatorTint(theme.separator.color)
                    .listRowBackground(rowBackground(index))
                }
            } header: {
                Label { Text("End-to-end encrypted") } icon: { Image(systemName: "lock.fill") }
                    .font(.footnote)
                    .foregroundStyle(theme.secondaryText.color)
                    .frame(maxWidth: .infinity)
                    .textCase(nil)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("theme.e2ee")
                    .accessibilityValue(Text(verbatim: theme.role.rawValue))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(theme.background.color.ignoresSafeArea())
        .overlay {
            if services.chat.conversations.isEmpty {
                ContentUnavailableView {
                    Text("No chats yet")
                } description: {
                    Text("Chats with your family show up here.")
                }
            }
        }
        .navigationTitle(Text("Chats"))
        .refreshable { await services.chat.loadConversations() }
        .toolbar {
            if services.canStartChats {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { choosing = true } label: { Image(systemName: "square.and.pencil") }
                        .accessibilityLabel(Text("New chat"))
                        .accessibilityIdentifier("chats.new")
                }
            }
        }
        .sheet(isPresented: $choosing) {
            NewChatView(services: services) { conversation in
                choosing = false
                services.chat.connect(conversation.id)
                opened = conversation
            }
            .zapaTheme(theme.role)
        }
        .navigationDestination(isPresented: Binding(get: { opened != nil }, set: {
            if !$0 {
                opened = nil
            }
        })) {
            if let opened {
                ChatView(services: services, conversation: opened)
            }
        }
    }

    /// Parents: plain rows with thin lines. Kids: a chunky tinted card per conversation.
    @ViewBuilder private func rowBackground(_ index: Int) -> some View {
        if theme.cardShadow {
            RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                .fill(theme.cardTints[index % theme.cardTints.count].color)
                .overlay(
                    RoundedRectangle(cornerRadius: theme.cardRadius, style: .continuous)
                        .strokeBorder(theme.separator.color, lineWidth: 2)
                )
                .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
        } else {
            theme.background.color
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        HStack(spacing: 12) {
            RobotAvatarView(avatar: services.avatar(of: conversation), size: theme.cardShadow ? 58 : 50)
                .background(Circle().fill(theme.secondary.color.opacity(0.25)))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: services.name(of: conversation))
                    .font(theme.cardShadow ? .title3.bold() : .headline)
                    .foregroundStyle(theme.text.color)
                if let last = services.chat.messages[conversation.id]?.last {
                    ChatPreview(content: last.content)
                        .font(.subheadline)
                        .foregroundStyle(theme.secondaryText.color)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let unread = services.chat.unread[conversation.id] {
                Text(verbatim: "\(unread)")
                    .font(.caption.bold())
                    .foregroundStyle(theme.onDanger.color)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(theme.danger.color))
                    .accessibilityLabel(Text("Unread messages: \(unread)"))
            }
        }
        .padding(.vertical, theme.cardShadow ? 18 : 10)
        .padding(.horizontal, theme.cardShadow ? 16 : 0)
        .frame(minHeight: theme.minTapTarget)
    }
}

/// One line about a message, for the list.
struct ChatPreview: View {
    let content: ChatContent

    var body: some View {
        switch content.body {
        case let .text(text): Text(verbatim: text)
        case .image: Label { Text("Photo") } icon: { Image(systemName: "photo") }
        case .voice: Label { Text("Voice message") } icon: { Image(systemName: "waveform") }
        case .call: Label { Text("Call") } icon: { Image(systemName: "phone.fill") }
        }
    }
}

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
                        RobotAvatarView(avatar: person.avatar, size: 40)
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
