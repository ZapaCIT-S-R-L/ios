import Foundation
import Observation
import ZapaCalls
import ZapaChat
import ZapaKidKit

/// Someone the app can show: a name and a robot, from the family (and later connected families).
struct Person: Equatable {
    let accountId: String
    let name: String
    let avatar: String
    let role: ParticipantRole
}

/// The signed-in app's services: chats, calls and the people in them.
@MainActor
@Observable
final class AppServices {
    let me: String
    let chat: ChatModel
    let calls: CallCoordinator
    private(set) var people: [String: Person]
    /// The peers of the call being placed (the controller factory reads them).
    var placing: [CallPeer] = []

    /// Who may start conversations: parents and kids (Stefan, 2026-10-28); the chat service enforces the family rules.
    let canStartChats: Bool
    /// Gets this phone ready to seal (registers it with the key directory, retrying calmly).
    var setup: DeviceSetup?
    /// Fills in names and robots from the family (account API).
    var loadPeople: (@MainActor (AppServices) async -> Void)?
    // Receives VoIP pushes, so a call rings even when the app isn't running. Kept here: PushKit holds it weakly.
    #if canImport(PushKit)
        var voipPushes: VoIPPushes?
    #endif

    init(
        me: String, canStartChats: Bool = true, chat: ChatModel, people: [Person], log: CallLogStore,
        system: CallSystem,
        makeController: @escaping @MainActor (AppServices) -> CallController
    ) {
        self.me = me
        self.canStartChats = canStartChats
        self.chat = chat
        self.people = Dictionary(people.map { ($0.accountId, $0) }) { first, _ in first }
        weak var services: AppServices?
        calls = CallCoordinator(
            system: system, log: log,
            lookup: { account in services?.peer(account) },
            makeController: {
                // swiftlint:disable:next force_unwrapping
                makeController(services!)
            }
        )
        services = self
        // Until VoIP pushes are set up, calls ring through a sealed message in the chat.
        chat.onIncomingCall = { [weak self] callId, _, caller in
            guard let self else { return }
            placing = peer(caller).map { [$0] } ?? []
            Task { await self.calls.handle(IncomingCallPush(callId: callId, callerAccountId: caller)) }
        }
    }

    /// Everyone this account can chat with (not itself).
    /// Set when a parent taps a kid's name in a chat: Settings opens that kid's edit screen.
    var pendingKidEdit: String?
    /// True on a parent's phone, where Settings edits kids.
    var isParentPhone = false

    var contacts: [Person] {
        people.values.filter { $0.accountId != me }.sorted { $0.name < $1.name }
    }

    /// Names and robots from the family (parents and kids).
    func update(from family: Family) {
        for parent in family.parents where people[parent.id] == nil || parent.id != me {
            people[parent.id] = Person(
                accountId: parent.id, name: parent.displayName ?? "…", avatar: "robot-2", role: .parent
            )
        }
        for kid in family.kids {
            people[kid.id] = Person(accountId: kid.id, name: kid.nickname, avatar: kid.avatar, role: .kid)
        }
    }

    func peer(_ accountId: String) -> CallPeer? {
        people[accountId].map {
            CallPeer(accountId: $0.accountId, deviceId: "", displayName: $0.name, avatar: $0.avatar, role: $0.role)
        }
    }

    func name(of conversation: Conversation) -> String {
        let others = conversation.members.filter { $0.accountId != me && !$0.guardian }
        let names = others.map { member -> String in
            if let name = people[member.accountId]?.name {
                KnownNames.remember(member.accountId, name)
                return name
            }
            // Gone from the family: the last name it had, marked as deleted.
            return KnownNames.name(member.accountId).map { "\($0) (Deleted)" } ?? "…"
        }
        return names.isEmpty ? "…" : names.joined(separator: ", ")
    }

    /// A chat with nobody else left in it (the other person was deleted or left): it goes to Archived.
    func isDeadChat(_ conversation: Conversation) -> Bool {
        !conversation.members.contains { $0.accountId != me && !$0.guardian }
    }

    /// The other member of a 1:1 chat (nil for a group or when unknown).
    func otherMemberId(of conversation: Conversation) -> String? {
        conversation.members.first { $0.accountId != me }?.accountId
    }

    func avatar(of conversation: Conversation) -> String {
        conversation.members.first { $0.accountId != me }.flatMap { people[$0.accountId]?.avatar } ?? "robot-1"
    }

    func call(_ conversation: Conversation) async {
        let peers = conversation.members.filter { $0.accountId != me }.compactMap { peer($0.accountId) }
        placing = peers
        await calls.startCall(conversationId: conversation.id, peers: peers)
        if let callId = calls.current?.callId {
            await chat.announceCall(callId, in: conversation.id)
        }
    }
}

extension CallResult {
    /// The chat's record of a call that ended here. Calls that failed or were cancelled leave no record.
    init?(_ entry: CallLogEntry) {
        let kind: Kind
        switch entry.outcome {
        case .answered: kind = .answered
        case .declined: kind = .declined
        case .missed, .noAnswer: kind = .unanswered
        case .cancelled, .failed: return nil
        }
        self.init(kind: kind, seconds: Int(entry.duration.rounded(.down)), incoming: entry.direction == .incoming)
    }
}

/// The last name each person had, so a chat with a deleted person can still say who it was.
enum KnownNames {
    private static let key = "chats.knownNames"

    static func remember(_ accountId: String, _ name: String) {
        var names = stored()
        guard names[accountId] != name else { return }
        names[accountId] = name
        if let data = try? JSONEncoder().encode(names) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func name(_ accountId: String) -> String? {
        stored()[accountId]
    }

    private static func stored() -> [String: String] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
    }
}
