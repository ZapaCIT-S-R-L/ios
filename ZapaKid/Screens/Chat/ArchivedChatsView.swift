import SwiftUI
import ZapaCalls
import ZapaChat

/// The archived chats: unarchive them, or delete one (its history goes; the others keep the chat).
struct ArchivedChatsView: View {
    let services: AppServices
    @AppStorage(ArchivedChats.key) private var archivedRaw = ""
    @State private var confirming: Conversation?
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        let archived = ArchivedChats.decode(archivedRaw)
        let chats = services.chat.conversations.filter { archived.contains($0.id) || services.isDeadChat($0) }
        List {
            ForEach(chats, id: \.id) { conversation in
                NavigationLink {
                    ChatView(services: services, conversation: conversation)
                } label: {
                    Label {
                        Text(verbatim: services.name(of: conversation))
                    } icon: {
                        PersonAvatar(
                            accountId: services.otherMemberId(of: conversation),
                            avatar: services.avatar(of: conversation),
                            size: 40
                        )
                    }
                    .foregroundStyle(theme.text.color)
                }
                .accessibilityIdentifier("archived.row.\(services.name(of: conversation))")
                // In a trailing swipe the first button sits at the far right, so Unarchive comes first.
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button {
                        archivedRaw = ArchivedChats.encode(archived.subtracting([conversation.id]))
                    } label: {
                        Label("Unarchive", systemImage: "tray.and.arrow.up")
                    }
                    .tint(.indigo)
                    .accessibilityIdentifier("archived.unarchive")
                    Button {
                        confirming = conversation
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .tint(.red)
                    .accessibilityIdentifier("archived.delete")
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if chats.isEmpty {
                ContentUnavailableView {
                    Text("No archived chats")
                } description: {
                    Text("Swipe a chat to archive it.")
                }
            }
        }
        .navigationTitle(Text("Archived"))
        .confirmationDialog(
            "Delete this chat?",
            isPresented: Binding(get: { confirming != nil }, set: {
                if !$0 {
                    confirming = nil
                }
            }),
            titleVisibility: .visible,
            presenting: confirming
        ) { conversation in
            Button("Delete chat and history", role: .destructive) {
                let id = conversation.id
                archivedRaw = ArchivedChats.encode(archived.subtracting([id]))
                Task { await services.chat.leave(id) }
            }
        } message: { _ in
            Text("You lose the history on this phone. The others keep the chat.")
        }
    }

    private var archived: Set<String> {
        ArchivedChats.decode(archivedRaw)
    }
}

/// The archived chat ids, kept per phone in `AppStorage` as a comma-separated string.
enum ArchivedChats {
    static let key = "chats.archivedIds"

    static func decode(_ raw: String) -> Set<String> {
        Set(raw.split(separator: ",").map(String.init))
    }

    static func encode(_ ids: Set<String>) -> String {
        ids.sorted().joined(separator: ",")
    }
}
