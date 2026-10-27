import SwiftUI
import ZapaCalls
import ZapaKidKit

/// Chats, Calls and (for parents) Family. A call shows full screen over everything.
struct MainTabView: View {
    let services: AppServices
    let family: FamilyModel?
    /// A kid's nickname, greeted above the chats.
    let greeting: String?
    let onSignOut: (() -> Void)?

    var body: some View {
        TabView {
            NavigationStack {
                ChatListView(services: services)
                    .safeAreaInset(edge: .top) {
                        if let greeting {
                            (Text("Hello,") + Text(verbatim: " \(greeting)!"))
                                .font(.title2.bold())
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16)
                                .accessibilityIdentifier("kid.hello")
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
            }
        }
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
            }
        }
        .onChange(of: services.calls.current == nil) { _, ended in
            if !ended {
                shownCall = services.calls.current
            }
        }
        .task {
            await services.loadPeople?(services)
            await services.chat.loadConversations()
            services.chat.connectAll()
        }
    }

    /// Keeps the ended call on screen until the person taps Close.
    @State private var shownCall: CallController?
}
