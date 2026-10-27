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
    private(set) var callLog: [CallLogEntry] = []
    private let log: CallLogStore
    /// The peers of the call being placed (the controller factory reads them).
    var placing: [CallPeer] = []

    /// Parents start conversations; kids answer in the ones their parents made.
    let canStartChats: Bool
    /// Fills in names and robots from the family (account API).
    var loadPeople: (@MainActor (AppServices) async -> Void)?

    init(
        me: String, canStartChats: Bool = true, chat: ChatModel, people: [Person], log: CallLogStore,
        system: CallSystem,
        makeController: @escaping @MainActor (AppServices) -> CallController
    ) {
        self.me = me
        self.canStartChats = canStartChats
        self.chat = chat
        self.people = Dictionary(people.map { ($0.accountId, $0) }) { first, _ in first }
        self.log = log
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
        let names = others.map { people[$0.accountId]?.name ?? "…" }
        return names.isEmpty ? "…" : names.joined(separator: ", ")
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

    func refreshLog() async {
        callLog = await log.entries()
    }
}
