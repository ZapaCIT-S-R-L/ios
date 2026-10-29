import SwiftUI
import ZapaCalls
import ZapaChat

/// The conversations: robot, name, last message, unread count.
struct ChatListView: View {
    let services: AppServices
    @State private var choosing = false
    @State private var opened: Conversation?
    @State private var query = ""
    @FocusState private var searching: Bool
    /// The Archived row shows only after the list is pulled down.
    @State private var archivedRevealed = false
    /// Archived chats stay on this phone only; they leave the main list until unarchived or deleted.
    @AppStorage(ArchivedChats.key) private var archivedRaw = ""
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        let archived = ArchivedChats.decode(archivedRaw)
        // A chat whose other person was deleted has nobody left to talk to: it sits in Archived.
        let active = services.chat.conversations.filter {
            !archived.contains($0.id) && !services.isDeadChat($0)
        }
        let archivedCount = services.chat.conversations.count - active.count
        let archivedShown = archivedCount > 0 && archivedRevealed
        let matches = services.contacts.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query)
        }
        List {
            if query.isEmpty {
                Section {
                    if archivedShown {
                        NavigationLink {
                            ArchivedChatsView(services: services)
                        } label: {
                            Label("Archived (\(archivedCount))", systemImage: "archivebox")
                                .foregroundStyle(.white)
                        }
                        .accessibilityIdentifier("chats.archived")
                        .listRowSeparator(.hidden, edges: .top)
                    }
                    ForEach(Array(active.enumerated()), id: \.element.id) { index, conversation in
                        NavigationLink {
                            ChatView(services: services, conversation: conversation)
                        } label: {
                            row(conversation)
                        }
                        .accessibilityIdentifier("chats.row.\(services.name(of: conversation))")
                        // The system lines are off; the lines between chats are drawn in each row's background.
                        .listRowSeparator(.hidden)
                        .listRowInsets(theme
                            .cardShadow ? EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16) : EdgeInsets(
                                top: 3,
                                leading: 16,
                                bottom: 3,
                                trailing: 16
                            ))
                        .listRowBackground(rowBackground(index, isLast: index == active.count - 1))
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                archivedRaw = ArchivedChats.encode(archived.union([conversation.id]))
                            } label: {
                                Label("Archive", systemImage: "archivebox")
                            }
                            .tint(.indigo)
                            .accessibilityIdentifier("chats.archive")
                        }
                    }
                }
            } else {
                Section {
                    ForEach(matches, id: \.accountId) { person in
                        Button { openChat(with: person) } label: {
                            HStack(spacing: 12) {
                                PersonAvatar(accountId: person.accountId, avatar: person.avatar, size: 50)
                                Text(verbatim: person.name)
                                    .font(.title3.bold())
                                    .foregroundStyle(theme.cardShadow ? theme.text.color : .white)
                            }
                        }
                        .accessibilityIdentifier("search.person.\(person.name)")
                    }
                } footer: {
                    if matches.isEmpty {
                        Text("No one in your family matches.")
                            .foregroundStyle(.gray)
                    }
                }
            }
        }
        .listStyle(.plain)
        // The section edge draws a line in plain lists; this list has no section headers.
        .listSectionSeparator(.hidden)
        .modifier(RevealOnPull(revealed: $archivedRevealed))
        // Above the list, not a row in it, so no separator line can sit between it and the chats.
        .safeAreaInset(edge: .top, spacing: 0) {
            searchField
        }
        .scrollContentBackground(.hidden)
        .scrollDismissesKeyboard(.immediately)
        // Empty space under the list hides the keyboard too; the rows still open their chats.
        .background(
            Color.black.ignoresSafeArea()
                .onTapGesture { searching = false }
                .accessibilityAddTraits(.isButton)
        )
        .overlay {
            if services.chat.conversations.isEmpty {
                ContentUnavailableView {
                    Text("No chats yet")
                } description: {
                    Text("Chats with your family show up here.")
                }
            }
        }
        .refreshable { await services.chat.loadConversations() }
        // A conversation a family member just started shows up without a manual refresh.
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await services.chat.loadConversations()
            }
        }
        .modifier(ZapaTopBar(title: "Chats", onTitleTap: { searching = false }))
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

    /// The search field, as the first row so the logo in the nav bar never covers it.
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.gray)
                .accessibilityHidden(true)
            TextField(text: $query, prompt: Text("Search people").foregroundStyle(.gray)) {}
                .foregroundStyle(.white)
                .focused($searching)
                .accessibilityIdentifier("chats.search")
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.gray)
                        .accessibilityLabel(Text("Clear search"))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(white: 0.15)))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(Color.black)
    }

    /// Opens the 1:1 chat with a person (found or started), from the search results.
    private func openChat(with person: Person) {
        Task {
            guard let conversation = await services.chat.start(with: [person.accountId]) else { return }
            services.chat.connect(conversation.id)
            opened = conversation
        }
    }

    /// Parents: plain rows with thin lines. Kids: a chunky tinted card per conversation.
    @ViewBuilder private func rowBackground(_ index: Int, isLast: Bool) -> some View {
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
            Color.black.overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle().fill(Color(white: 0.2)).frame(height: 0.5)
                }
            }
        }
    }

    private func row(_ conversation: Conversation) -> some View {
        HStack(alignment: .top, spacing: 12) {
            PersonAvatar(
                accountId: services.otherMemberId(of: conversation),
                avatar: services.avatar(of: conversation),
                size: theme.cardShadow ? 58 : 68
            )
            .background(Circle().fill(theme.secondary.color.opacity(0.25)))
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: services.name(of: conversation))
                    .font(.title3.bold())
                    .foregroundStyle(theme.cardShadow ? theme.text.color : .white)
                if let last = services.chat.messages[conversation.id]?.last {
                    ChatPreview(content: last.content)
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                        .lineLimit(2)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 6) {
                if let sent = services.chat.messages[conversation.id]?.last?.content.sentAt {
                    Group {
                        if Calendar.current.isDateInToday(sent) {
                            Text(sent, style: .time)
                        } else {
                            Text(sent, format: .dateTime.day().month(.abbreviated))
                        }
                    }
                    .font(services.chat.unread[conversation.id] == nil ? .subheadline : .subheadline.bold())
                    .foregroundStyle(.gray)
                    .accessibilityIdentifier("chats.time")
                }
                if let unread = services.chat.unread[conversation.id] {
                    Text(verbatim: "\(unread)")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(theme.accent.color))
                        .accessibilityLabel(Text("Unread messages: \(unread)"))
                }
            }
        }
        .padding(.vertical, theme.cardShadow ? 18 : 4)
        .padding(.horizontal, theme.cardShadow ? 16 : 0)
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
        case .video: Label { Text("Video") } icon: { Image(systemName: "play.rectangle.fill") }
        case .document: Label { Text("Document") } icon: { Image(systemName: "doc.fill") }
        case .contact: Label { Text("Contact") } icon: { Image(systemName: "person.crop.circle.fill") }
        case .location: Label { Text("Location") } icon: { Image(systemName: "mappin.and.ellipse") }
        }
    }
}

/// Sets `revealed` while the list is pulled down past its top, and clears it once scrolled back down.
private struct RevealOnPull: ViewModifier {
    @Binding var revealed: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18, *) {
            content.onScrollGeometryChange(for: CGFloat.self) { geometry in
                geometry.contentOffset.y + geometry.contentInsets.top
            } action: { _, offset in
                if offset < -60 {
                    revealed = true
                } else if offset > 0 {
                    revealed = false
                }
            }
        } else {
            content.onAppear { revealed = true }
        }
    }
}
