import SwiftUI
import ZapaCalls
import ZapaChat

/// The conversations: robot, name, last message, unread count.
struct ChatListView: View {
    let services: AppServices
    @State private var choosing = false
    @State private var opened: Conversation?

    var body: some View {
        List(services.chat.conversations) { conversation in
            NavigationLink {
                ChatView(services: services, conversation: conversation)
            } label: {
                row(conversation)
            }
            .accessibilityIdentifier("chats.row.\(services.name(of: conversation))")
        }
        .listStyle(.plain)
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

    private func row(_ conversation: Conversation) -> some View {
        HStack(spacing: 12) {
            RobotAvatarView(avatar: services.avatar(of: conversation), size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: services.name(of: conversation))
                    .font(.headline)
                if let last = services.chat.messages[conversation.id]?.last {
                    ChatPreview(content: last.content)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let unread = services.chat.unread[conversation.id] {
                Text(verbatim: "\(unread)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.accentColor))
                    .accessibilityLabel(Text("Unread messages: \(unread)"))
            }
        }
        .padding(.vertical, 4)
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
