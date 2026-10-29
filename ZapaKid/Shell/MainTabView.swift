import Network
import SwiftUI
import ZapaCalls
import ZapaKidKit

/// Chats, Calls and Family (parents manage it, kids see who is in it). A call shows full screen over everything.
/// Parents get the calm look, kids the playful one (`ZapaTheme`).
struct MainTabView: View {
    let role: ZapaTheme.Role
    let services: AppServices
    let family: FamilyModel?
    let onSignOut: (() -> Void)?

    var body: some View {
        tabs.zapaTheme(role)
            .overlay(alignment: .top) {
                if let notice = services.calls.notice {
                    CallNoticeBanner(notice: notice)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .task {
                            try? await Task.sleep(for: .seconds(3))
                            withAnimation { services.calls.clearNotice() }
                        }
                }
            }
            .animation(.default, value: services.calls.notice)
            // iOS refusing a call is never silent, on either phone.
            .alert(refusal.map { Text($0.title) } ?? Text(verbatim: ""), isPresented: Binding(
                get: { services.calls.refused != nil },
                set: {
                    if !$0 {
                        services.calls.clearRefusal()
                    }
                }
            )) {
                Button { services.calls.clearRefusal() } label: { Text("OK") }
            } message: {
                if let refusal {
                    Text(refusal.message)
                }
            }
    }

    private var refusal: CallRefusalAlert? {
        services.calls.refused.map(CallRefusalAlert.init)
    }

    private var tabs: some View {
        TabView {
            NavigationStack {
                ChatListView(services: services)
                    .safeAreaInset(edge: .bottom) {
                        if let setup = services.setup {
                            SetupBanner(setup: setup)
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
        // The call screen closes as soon as the call ends: back to where the call started (Stefan, 2026-10-29).
        .fullScreenCover(isPresented: Binding(get: { services.calls.current != nil }, set: { _ in })) {
            if let controller = services.calls.current {
                CallScreen(controller: controller, coordinator: services.calls)
                    .zapaTheme(role)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                services.setup?.retryNow()
                Task { await services.chat.refresh() }
            }
        }
        .onChange(of: services.calls.current == nil) { _, ended in
            if ended {
                Task { await services.refreshLog() }
            }
        }
        .task {
            // Structured: leaving this view cancels the run and its network watch, so a run from one session never
            // outlives it.
            guard let setup = services.setup else { return }
            let networkWatch = setup.watchNetwork()
            defer { networkWatch.cancel() }
            await setup.run()
        }
        .task {
            await services.loadPeople?(services)
            await services.chat.refresh()
        }
        .task(id: scenePhase == .active) {
            // Stopgap: until the account events stream (api #100) tells the phone about new conversations,
            // poll for them every 20 s while the app is open. Remove this poll when that stream lands.
            while scenePhase == .active, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(20))
                await services.chat.refresh()
            }
        }
    }

    /// Keeps the ended call on screen until the person taps Close.
    @Environment(\.scenePhase) private var scenePhase
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

/// A calm note while this phone can't finish its secure setup, with "Try again"; or, for a kid phone, that a
/// parent must pair it again.
struct SetupBanner: View {
    let setup: DeviceSetup
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        switch setup.state {
        case .retrying:
            banner(Text("Can't finish setting up secure chat on this phone yet. We'll keep trying."), retry: true)
        case .needsPairing:
            banner(Text("Ask a parent to pair this phone again."), retry: false)
        case .waitingForReshare:
            banner(Text("Open ZapaKid on your other phone to share your keys with this one."), retry: false)
        case .stopped:
            banner(
                Text("Secure chat can't be set up on this phone. Install ZapaKid again from the App Store."),
                retry: false
            )
        default:
            EmptyView()
        }
    }

    private func banner(_ message: Text, retry: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "lock.shield")
                .font(.title2)
                .foregroundStyle(theme.accent.color)
                .accessibilityHidden(true)
            message
                .font(.subheadline)
                .foregroundStyle(theme.text.color)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("setup.message")
            if retry {
                Button { setup.retryNow() } label: {
                    Text("Try again")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(theme.onPrimary.color)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(theme.primary.color))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("setup.retry")
            }
        }
        .zapaCard(theme)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

/// After the call screen closed: why a call this phone placed didn't go through (Stefan, 2026-10-29).
private struct CallNoticeBanner: View {
    let notice: CallNotice
    @Environment(\.zapaTheme) private var theme

    var body: some View {
        text
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(theme.onPrimary.color)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(Capsule().fill(theme.primary.color))
            .padding(.top, 8)
            .accessibilityIdentifier("call.notice")
    }

    private var text: Text {
        let names = notice.names.formatted(.list(type: .and))
        return switch notice.reason {
        case .declined: Text("\(names) declined the call")
        case .noAnswer: Text("\(names) didn't answer")
        case .interrupted: Text("The call was interrupted")
        }
    }
}

/// What the user is told when iOS refused a call.
struct CallRefusalAlert: Equatable {
    let title: LocalizedStringResource
    let message: LocalizedStringResource

    init(_ direction: CallDirection) {
        switch direction {
        case .outgoing:
            title = "The call couldn't start"
            message = "Your iPhone didn't allow the call. Check Do Not Disturb and try again."
        case .incoming:
            title = "A call couldn't ring"
            message = "Your iPhone didn't let ZapaKid ring. Close ZapaKid and open it again."
        }
    }
}
