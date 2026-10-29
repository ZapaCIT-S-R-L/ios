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
                    .listRowInsets(theme.cardShadow ? EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16) : EdgeInsets(top: 3, leading: 16, bottom: 3, trailing: 16))
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
        .background(Color.black.ignoresSafeArea().onTapGesture { searching = false })
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
            PersonAvatar(accountId: services.otherMemberId(of: conversation), avatar: services.avatar(of: conversation), size: theme.cardShadow ? 58 : 68)
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
                        PersonAvatar(accountId: services.otherMemberId(of: conversation), avatar: services.avatar(of: conversation), size: 40)
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
            isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
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

/// The end-to-end encryption note, in a small bubble above the tab bar.
struct E2EEBadge: View {
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        Label { Text("End-to-end encrypted") } icon: { Image(systemName: "lock.fill") }
            .font(.caption)
            .foregroundStyle(.gray)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Capsule().fill(Color(white: 0.15)))
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("theme.e2ee")
            .accessibilityValue(Text(verbatim: theme.role.rawValue))
            .padding(.bottom, 4)
    }
}

/// The ZapaKid logo for the top left of a screen.
struct ZapaLogo: View {
    var body: some View {
        Image("ZapaLogo")
            .resizable()
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .contentShape(Rectangle())
            .accessibilityLabel(Text("ZapaKid"))
    }
}

/// The top bar every main screen shares: the logo top left, the title centered, inline.
struct ZapaTopBar: ViewModifier {
    let title: LocalizedStringKey
    var onTitleTap: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .navigationTitle(Text(title))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if #available(iOS 26, *) {
                    ToolbarItem(placement: .topBarLeading) {
                        ZapaLogo()
                    }
                    .sharedBackgroundVisibility(.hidden)
                } else {
                    ToolbarItem(placement: .topBarLeading) {
                        ZapaLogo()
                    }
                }
                ToolbarItem(placement: .principal) {
                    Text(title)
                        .font(.title2.bold())
                        .contentShape(Rectangle())
                        .onTapGesture { onTitleTap?() }
                        .accessibilityHidden(true)
                }
            }
    }
}
