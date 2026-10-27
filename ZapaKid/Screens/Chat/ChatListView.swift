import SwiftUI
import ZapaCalls
import ZapaChat

/// The conversations: robot, name, last message, unread count.
struct ChatListView: View {
    let services: AppServices

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
        }
    }
}
