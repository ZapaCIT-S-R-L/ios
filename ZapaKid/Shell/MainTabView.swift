import SwiftUI
import ZapaCalls
import ZapaKidKit

/// Chats, Calls and Family (parents manage it, kids see who is in it). A call shows full screen over everything.
/// Parents get the calm look, kids the playful one (`ZapaTheme`).
struct MainTabView: View {
    let role: ZapaTheme.Role
    let services: AppServices
    let family: FamilyModel?
    /// A kid's nickname, greeted above the chats.
    let greeting: String?
    let onSignOut: (() -> Void)?

    var body: some View {
        tabs.zapaTheme(role)
    }

    private var tabs: some View {
        TabView {
            NavigationStack {
                ChatListView(services: services)
                    .safeAreaInset(edge: .top) {
                        if let greeting {
                            HStack {
                                (Text("Hello,") + Text(verbatim: " \(greeting)!"))
                                    .font(.title2.bold())
                                    .accessibilityIdentifier("kid.hello")
                                Sparkles()
                                Spacer()
                            }
                            .padding(.horizontal, 16)
                        }
                    }
            }
            .tabItem { Label("Chats", systemImage: "bubble.left.and.bubble.right.fill") }

            NavigationStack {
                CallLogView(entries: services.callLog) { entry in
                    guard let conversation = services.chat.conversations.first(where: { $0.id == entry.conversationId })
                    else { return }
                    Task { await services.call(conversation) }
                }
                .task { await services.refreshLog() }
            }
            .tabItem { Label("Calls", systemImage: "phone.fill") }

            if let family {
                NavigationStack {
                    FamilyView(model: family)
                        .onChange(of: family.family) { _, loaded in
                            if let loaded {
                                services.update(from: loaded)
                            }
                        }
                        .toolbar {
                            if let onSignOut {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button(role: .destructive, action: onSignOut) { Text("Sign out") }
                                        .accessibilityIdentifier("home.signOut")
                                }
                            }
                        }
                }
                .tabItem { Label("Family", systemImage: "person.3.fill") }
            } else {
                NavigationStack {
                    KidFamilyView(services: services)
                }
                .tabItem { Label("Family", systemImage: "person.3.fill") }
            }
        }
        .modifier(ThemedBars(role: role))
        .fullScreenCover(isPresented: Binding(
            get: { services.calls.current != nil || shownCall != nil },
            set: {
                if !$0 {
                    shownCall = nil
                }
            }
        )) {
            if let controller = services.calls.current ?? shownCall {
                CallScreen(controller: controller) {
                    shownCall = nil
                    Task { await services.refreshLog() }
                }
                .zapaTheme(role)
            }
        }
        .onChange(of: services.calls.current == nil) { _, ended in
            if !ended {
                shownCall = services.calls.current
            }
        }
        .task {
            await services.prepare?()
            await services.loadPeople?(services)
            await services.chat.loadConversations()
            services.chat.connectAll()
        }
    }

    /// Keeps the ended call on screen until the person taps Close.
    @State private var shownCall: CallController?
}

/// Tab and navigation bars in the theme's colors.
private struct ThemedBars: ViewModifier {
    let role: ZapaTheme.Role
    @Environment(\.zapaTheme) private var theme

    func body(content: Content) -> some View {
        content
            .toolbarBackground(theme.surface.color, for: .tabBar)
            .toolbarBackground(.visible, for: .tabBar)
    }
}

/// A kid's family: everyone they can chat with and call, as big cards. Parents manage the family on their phones.
struct KidFamilyView: View {
    let services: AppServices
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: theme.spacing) {
                HStack {
                    Text("My family")
                        .font(.title.bold())
                        .foregroundStyle(theme.onPrimary.color)
                    Sparkles()
                    Spacer()
                }
                .zapaCard(theme, tint: theme.primary)
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 150), spacing: theme.spacing)],
                    spacing: theme.spacing
                ) {
                    ForEach(
                        Array(services.people.values.sorted { $0.name < $1.name }.enumerated()),
                        id: \.element.accountId
                    ) { index, person in
                        VStack(spacing: 8) {
                            RobotAvatarView(avatar: person.avatar, size: 72)
                            Text(verbatim: person.name)
                                .font(.headline)
                                .foregroundStyle(theme.text.color)
                            (person.role == .parent ? Text("Parent") : Text("Kid"))
                                .font(.subheadline)
                                .foregroundStyle(theme.secondaryText.color)
                        }
                        .frame(maxWidth: .infinity)
                        .zapaCard(theme, tint: theme.cardTints[index % theme.cardTints.count])
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            .padding(theme.spacing)
        }
        .background(theme.background.color.ignoresSafeArea())
        .navigationTitle(Text("Family"))
        .accessibilityIdentifier("family.screen")
    }
}
